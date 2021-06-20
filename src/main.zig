const std = @import("std");
const unit = @import("unit.zig");
const max_len = 512;
const Error = error{SigActionFailure};
usingnamespace @import("packets.zig");
const Client = @import("client.zig").Client;

var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = std.Thread.Mutex{};
var pipefds: [2]std.os.fd_t = undefined;

var units_tasks: std.ArrayList(unit.Unit) = undefined;
var units_daemons: @TypeOf(units_tasks) = undefined;

// write is signal safe
fn _sigchld(_: i32) callconv(.C) void {
    _ = std.os.send(pipefds[1], ".", std.os.MSG_NOSIGNAL) catch {};
}

fn sigchld() void {
    std.debug.print("Sigchld\n", .{});
    while (true) {
        var wstatus: c_int = undefined;
        const rc = std.os.system.waitpid(-1, &wstatus, std.os.WNOHANG);

        switch (std.os.errno(rc)) {
            0 => {}, // no problem
            std.os.system.ECHILD => break, // no more children
            else => break, // waitpid failure
        }

        const pid = @intCast(std.os.system.pid_t, rc);
        if (pid == 0) break;

        for (units_daemons.items) |*u| {
            for (u.cmds) |*p| {
                if (p.pid == pid) {
                    p.running = false;
                    var x: usize = 0;
                    for (u.cmds) |*l| {
                        if (!l.running) x += 1;
                    }
                    if (x == u.cmds.len and u.running) {
                        std.debug.print("unit completed: all units have exited\n", .{});
                        u.running = false;
                        break;
                    }
                }
            }
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
            const dupes = try allocator.dupe([]const u8, x);
            var i: usize = 0;
            errdefer {
                for (dupes[0..i]) |str| allocator.free(str);
                allocator.free(dupes);
            }
            while (i < dupes.len) : (i += 1) {
                dupes[i] = try allocator.dupe(u8, dupes[i]);
            }
            try cmdsar.append(unit.Command{ .cmd = dupes, .pid = 0, .running = false });
        }
        return unit.Unit.init(
            allocator,
            self.name,
            cmdsar.toOwnedSlice(),
            if (std.mem.eql(u8, self.kind, "daemon")) unit.UnitKind.Daemon else if (std.mem.eql(u8, self.kind, "task")) unit.UnitKind.Task else unreachable,
        );
    }
};

fn nextValid(walker: *std.fs.Walker) !?std.fs.Walker.Entry {
    while (true) {
        return walker.next() catch |err| switch (err) {
            error.AccessDenied => {
                std.debug.print("warning: AccessDenied in some directory, ignoring\n", .{});
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
    var units = std.ArrayList(unit.Unit).init(allocator); // defined at global scope for sigchld handler
    // the deinit goes when we're done with it.

    pipefds = try std.os.pipe();
    units_daemons = @TypeOf(units_daemons).init(allocator);
    units_tasks = @TypeOf(units_tasks).init(allocator);
    // same for deinit as units

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

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var walker = try std.fs.walkPath(allocator, "/home/user/knit/units");
    defer walker.deinit();
    while (try nextValid(&walker)) |ent| {
        std.debug.print("entry: {s}\n", .{ent.path});
        if (ent.kind == .File and std.mem.endsWith(u8, ent.basename, ".unit.json")) {
            std.debug.print("found a unit", .{});
            var f = try std.fs.cwd().openFile(ent.path, std.fs.File.OpenFlags{ .read = true });
            var stat = try f.stat();
            var buf = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), stat.size, @alignOf(u8), null);
            defer allocator.free(buf);
            var stream = std.json.TokenStream.init(buf);
            var parsed = try std.json.parse(UnitJson, &stream, .{ .allocator = allocator });
            defer std.json.parseFree(UnitJson, parsed, .{ .allocator = allocator });
            var unitized = try parsed.toUnit(allocator);
            try units.append(unitized);
        }
    }

    var on_daemons = false;

    for (units.items) |u| {
        if (u.kind == .Task) try units_tasks.append(u) else try units_daemons.append(u);
    }

    units.deinit();

    for (units_tasks.items) |*task| {
        try task.load(&env);
    }
    for (units_daemons.items) |*daemon| {
        try daemon.load(&env);
    }

    clients = @TypeOf(clients).init(allocator);

    defer {
        const lock = clients_mutex.acquire();
        defer lock.release();
        for (clients.items) |item| {
            item.deinit(); // dont bother removing, we're gonna clean it up and exit anyways
        }
        clients.deinit();
        for (units_tasks.items) |*t| {
            t.deinit();
        }
        for (units_daemons.items) |*t| {
            t.deinit();
        }
        units_tasks.deinit();
        units_daemons.deinit();
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
            std.debug.print("message written, client done\n", .{});
            // while (true) {
            //     var _buf: [512]u8 = undefined;
            //     var z = try readPacketReader(socket.reader(), &_buf);
            //     std.debug.print("in buf: {s}\n", .{z});
            // }
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
    // var conn = try std.os.accept(fd, null, null, 0);
    // var client = try Client.init(conn, allocator, &clients, &clients_mutex);
    // try client.runEvLoop();
    // const lock = clients_mutex.acquire();
    // try clients.append(client);
    // lock.release();
}
