const std = @import("std");
const unit = @import("unit.zig");
const max_len = 512;
const Error = error{SigActionFailure};
usingnamespace @import("packets.zig");
const Client = @import("client.zig").Client;

var units: std.ArrayList(*unit.Unit) = undefined;
var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = std.Thread.Mutex{};

fn sigchld(signo: i32) callconv(.C) void {
    std.debug.print("Sigchld", .{});
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

        for (units.items) |u, i| {
            for (u.cmds) |p, j| {
                if (p.pid == pid) {
                    // in the future, we want to start it again
                    // does not work for blocking which is ok
                    // because that never makes the running change in first place
                    // as it has to wait
                    units.items[i].running = false;
                    for (u.cmds) |l| {
                        if (l.pid != pid) std.os.kill(l.pid, std.os.SIGKILL) catch {}; // this one has already been killed so we kill the rest
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
        defer cmdsar.deinit(); // here is the deinit
        for (self.commands) |x| {
            try cmdsar.append(unit.Command{ .cmd = x, .pid = 0 });
        }
        return unit.Unit{
            .name = self.name,
            .cmds = cmdsar.toOwnedSlice(),
            .kind = if (std.mem.eql(u8, self.kind, "daemon")) unit.UnitKind.Daemon else if (std.mem.eql(u8, self.kind, "task")) unit.UnitKind.Blocking else unreachable, // lol pls fix
            .allocator = allocator,
            .running = false,
        }; // switch to .init()
        // the callee is not responsible for resource management of the returned Unit.
        // it is owned by the caller, and must be destroyed when out of scope with a .deinit() call.
    }
};

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

    // handle SIGCHLD
    try sigaction(std.os.SIGCHLD, &.{
        .handler = .{ .handler = sigchld },
        .mask = std.os.system.empty_sigset,
        .flags = std.os.system.SA_NOCLDSTOP,
    });

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var l = try unit.Unit.init(
        "ls",
        &.{
            unit.Command{
                .cmd = &.{ "ls", "/" },
                .pid = 0,
            },
        },
        unit.UnitKind.Daemon,
        allocator,
    );

    var stream = std.json.TokenStream.init(
        \\{
        \\  "name": "tree",
        \\  "commands": [
        \\    ["tree", "/"]
        \\  ],
        \\  "kind": "task"
        \\}
    );
    var x = try std.json.parse(UnitJson, &stream, .{
        .allocator = allocator,
    });
    defer std.json.parseFree(UnitJson, x, .{ .allocator = allocator });
    std.debug.print("{s}\n", .{x.commands});
    var y = try x.toUnit(allocator);
    defer y.deinit();
    std.debug.print("{any}\n", .{y.cmds[0]});
    defer l.deinit();
    try units.append(&l);
    try l.load(&env);
    std.debug.print("done loading\n", .{});

    var server = std.net.StreamServer.init(.{});
    defer server.deinit();

    const socket_path = "socket.unix";

    var socket_addr = try std.net.Address.initUnix(socket_path);
    clients = std.ArrayList(*Client).init(allocator);

    defer {
        const lock = clients_mutex.acquire();
        defer lock.release();
        for (clients.items) |item| {
            item.deinit(); // dont bother removing, we're gonna clean it up and exit anyways
        }
        clients.deinit();
    }

    defer std.fs.cwd().deleteFile(socket_path) catch {};
    try server.listen(socket_addr);

    const S = struct {
        fn clientFn(_: void) !void {
            const socket = try std.net.connectUnixSocket(socket_path);
            defer socket.close();

            try writePacket(socket.writer(), "Hello World!");
        }
    };

    const t = try std.Thread.spawn(S.clientFn, {}); // spawn client
    defer t.wait();
    var running = true;
    while (running) {
        var conn = try server.accept();
        var client = try Client.init(
            conn,
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
    }
    // don't run in a loop so we can find memory leaks, nasty things
    // var conn = try server.accept();
    // var client = try Client.init(conn, allocator, &clients, &clients_mutex);
    // try client.runEvLoop();
    // const lock = clients_mutex.acquire();
    // defer lock.release();
    // try clients.append(client);
}
