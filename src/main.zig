const std = @import("std");
const unit = @import("unit.zig");
const max_len = 512;
const Error = error{SigActionFailure};
usingnamespace @import("packets.zig");
const Client = @import("client.zig").Client;

var units: std.ArrayList(*unit.Unit) = undefined;
var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = std.Thread.Mutex{};
var pipefds: [2]std.os.fd_t = undefined;

// write is signal safe
fn _sigchld(_: i32) callconv(.C) void {
    _ = std.os.write(pipefds[1], ".") catch unreachable; // probably error handling isn't signal safe anyways this should work
    // todo migrate to send so we can use MSG_NOSIGNAL 
}

fn sigchld() void {
    std.debug.print("Sigchld\n", .{});
    while (true) {
        var wstatus: u32 = undefined;
        const rc = std.os.system.waitpid(-1, &wstatus, std.os.WNOHANG);

        switch (std.os.errno(rc)) {
            0 => {}, // no problem
            std.os.system.ECHILD => break, // no more children
            else => break, // waitpid failure
        }

        const pid = @intCast(std.os.system.pid_t, rc);
        if (pid == 0) break;

        for (units.items) |u| {
            for (u.cmds) |*p| {
                if (p.pid == pid) {
                    p.running = false;
                    var x: usize = 0;
                    for (u.cmds) |*l| {
                        if (!l.running) x += 1;
                    }
                    if (x == u.cmds.len and u.running) {
                        std.debug.warn("unit completed: all units have exited\n", .{});
                        u.running = false;
                    }
                }
            }
        }

        if (std.os.system.WIFEXITED(wstatus)) { // normal termination
            continue;
        }
        if (std.os.system.WIFSIGNALED(wstatus)) { // killed by signal
            std.debug.print("note: killed by signal\n", .{});
        }
    }
}

const UnitJson = struct {
    name: []const u8,
    commands: []const []const []const u8,
    kind: []const u8,
    pub fn toUnit(self: *UnitJson, allocator: *std.mem.Allocator) !unit.Unit {
        var cmdsar = std.ArrayList(unit.Command).init(allocator);
        defer cmdsar.deinit();
        for (self.commands) |x| {
            try cmdsar.append(unit.Command{ .cmd = x, .pid = 0, .running = false });
        }
        return unit.Unit.init(self.name, cmdsar.toOwnedSlice(), if (std.mem.eql(u8, self.kind, "daemon")) unit.UnitKind.Daemon else if (std.mem.eql(u8, self.kind, "task")) unit.UnitKind.Blocking else unreachable, allocator);
        // the callee is not responsible for resource management of the returned Unit.
        // it is owned by the caller, and must be destroyed when out of scope with a .deinit() call.
    }
};
fn nextValid(walker: *std.fs.Walker) !?std.fs.Walker.Entry {
    while (true) {
        return walker.next() catch |err| switch (err) {
            error.AccessDenied => {
                std.debug.warn("warning: AccessDenied in some directory, ignoring\n", .{});
                continue;
            },
            else => return err,
        };
    }
}
fn sigaction(signo: u6, sigact: *const std.os.system.Sigaction) !void {
    switch (std.os.errno(std.os.system.sigaction(signo, sigact, null))) {
        0 => {},
        else => return error.SigActionFailure,
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) std.log.err("memory leak detected, report a bug\n", .{});
    const allocator = &gpa.allocator;
    units = std.ArrayList(*unit.Unit).init(allocator); // defined at global scope for sigchld handler
    defer units.deinit();

    pipefds = try std.os.pipe();

    _ = try std.Thread.spawn(struct {
        pub fn callback(_: void) !void {
            var rmsg: [1]u8 = .{0};
            while (true) {
                _ = try std.os.read(pipefds[0], &rmsg);
                if (rmsg[0] != '.') continue; // . = "go handle SIGCHLD"
                rmsg[0] = 0;
                sigchld();
            }
        }
    }.callback, {});

    // handle SIGCHLD
    try sigaction(std.os.SIGCHLD, &.{
        .handler = .{ .handler = _sigchld },
        .mask = std.os.system.empty_sigset,
        .flags = std.os.system.SA_NOCLDSTOP,
    });

    var walker = try std.fs.walkPath(allocator, "./units");
    while (try nextValid(&walker)) |ent| {
        std.debug.print("entry: {s}\n", .{ent.path});
    }

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var stream = std.json.TokenStream.init(
        \\{
        \\  "name": "tree",
        \\  "commands": [
        \\    ["ls", "/"]
        \\  ],
        \\  "kind": "daemon"
        \\}
    );
    var x = try std.json.parse(UnitJson, &stream, .{
        .allocator = allocator,
    });
    std.debug.print("{s}\n", .{x.commands});
    var y = try x.toUnit(allocator);
    defer y.deinit();
    defer std.json.parseFree(UnitJson, x, .{ .allocator = allocator });
    std.debug.print("{any}\n", .{y.cmds[0]});
    try units.append(&y);
    try units.append(&y);
    try y.load(&env);
    try y.load(&env);
    std.debug.print("done loading\n", .{});

    clients = std.ArrayList(*Client).init(allocator);

    defer {
        const lock = clients_mutex.acquire();
        defer lock.release();
        for (clients.items) |item| {
            item.deinit(); // dont bother removing, we're gonna clean it up and exit anyways
        }
        clients.deinit();
    }

    var addr = std.mem.zeroes(std.os.sockaddr_un);
    var buf: [512]u8 = undefined;
    var fd: std.os.socket_t = undefined;
    var cl: std.os.socket_t = undefined;
    var rc: usize = undefined;

    fd = try std.os.socket(std.os.AF_UNIX, std.os.SOCK_STREAM, 0);

    addr.family = std.os.AF_UNIX;
    std.mem.set(u8, &addr.path, 0);
    std.mem.copy(u8, &addr.path, "./socket");

    std.debug.print("{s}\n", .{addr.path}); // "./socket"

    std.fs.cwd().deleteFile("./socket") catch |e| switch (e) {
        error.FileNotFound => {},
        else => unreachable, // omg please stop
    };

    try std.os.bind(fd, @ptrCast(*const std.os.sockaddr, &addr), @sizeOf(@TypeOf(addr)));
    try std.os.listen(fd, 5); // backlog 5

    const S = struct {
        fn clientFn(_: void) !void {
            const socket = try std.net.connectUnixSocket("./socket");
            defer socket.close();
            std.debug.print("writing message\n", .{});
            try writePacketWriter(socket.writer(), "Hello World!");
            std.debug.warn("message written, client done\n", .{});
            while (true) {
                var _buf: [512]u8 = undefined;
                var z = try readPacketReader(socket.reader(), &_buf);
                std.debug.print("in buf: {s}\n", .{z});
            }
        }
    };

    const t = try std.Thread.spawn(S.clientFn, {}); // spawn client
    defer t.wait();
    var running = true;

    while (true) {
        cl = try std.os.accept(fd, null, null, 0);
        // var creds = std.mem.zeroes(ucred);
        // var len: u32 = @sizeOf(ucred);
        // var thing = std.c.getsockopt(cl, std.os.SOL_SOCKET, std.os.SO_PEERCRED, @ptrCast(*c_void, &creds), &len);
        // std.debug.print("uid: {}\nerror: {}\nerrno: {}\n", .{ creds.uid, thing, std.os.errno(thing) });
        var client = try Client.init(
            cl,
            allocator,
            &clients,
            &clients_mutex,
        );
        try client.runEvLoop();
        const lock = clients_mutex.acquire();
        defer lock.release();
        clients.append(client) catch {
            client.deinit();
            continue;
        };
        writePacket(client.conn, "Hello World from your sweet server!") catch |e| switch (e) {
            error.BrokenPipe => {
                std.debug.print("pipe broken, couldn't send\n", .{});
            },
            else => unreachable,
        };
    }
    // don't run in a loop so we can find memory leaks, nasty things
    // var conn = try server.accept();
    // var client = try Client.init(conn, allocator, &clients, &clients_mutex);
    // try client.runEvLoop();
    // const lock = clients_mutex.acquire();
    // defer lock.release();
    // try clients.append(client);
}
