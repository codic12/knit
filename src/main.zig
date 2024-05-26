const std = @import("std");
const unit = @import("unit.zig");
const max_len = 512;
const Error = error{SigActionFailure};
const packets = @import("packets.zig");
const Client = @import("client.zig").Client;

var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = std.Thread.Mutex{};
var pipefds: [2]std.posix.fd_t = undefined;

var units_tasks: std.ArrayList(unit.Unit) = undefined;
var units_daemons: @TypeOf(units_tasks) = undefined;

// write is signal safe
fn _sigchld(_: i32) callconv(.C) void {
    _ = std.posix.write(pipefds[1], ".") catch {};
}

fn sigchld() void {
    std.debug.print("Sigchld\n", .{});
    while (true) {
        var wstatus: c_int = undefined;
        const rc = std.posix.system.waitpid(-1, &wstatus, std.posix.W.NOHANG);

        switch (rc) {
            0 => {}, // no problem
            else => break,
        }

        const pid: std.posix.system.pid_t = @intCast(rc);
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
    pub fn toUnit(self: *UnitJson, allocator: *const std.mem.Allocator) !unit.Unit {
        var cmdsar = std.ArrayList(unit.Command).init(allocator.*);
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
            try cmdsar.toOwnedSlice(),
            if (std.mem.eql(u8, self.kind, "daemon")) unit.UnitKind.Daemon else if (std.mem.eql(u8, self.kind, "task")) unit.UnitKind.Task else unreachable,
        );
    }
};

fn nextValid(walker: *std.fs.Dir.Walker) !?std.fs.Dir.Walker.Entry {
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
fn sigaction(signo: u6, sigact: *const std.posix.Sigaction) !void {
    try std.posix.sigaction(signo, sigact, null);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) @panic("Memory leak");
    }
    const allocator = gpa.allocator();
    var units = std.ArrayList(unit.Unit).init(allocator); // defined at global scope for sigchld handler
    // the deinit goes when we're done with it.

    pipefds = try std.posix.pipe();
    units_daemons = @TypeOf(units_daemons).init(allocator);
    units_tasks = @TypeOf(units_tasks).init(allocator);
    // same for deinit as units

    _ = try std.Thread.spawn(.{}, struct {
        pub fn callback() !void {
            var rmsg: [1]u8 = .{0};
            while (true) {
                _ = try std.posix.read(pipefds[0], &rmsg);
                if (rmsg[0] != '.') continue; // . = "go handle SIGCHLD"
                rmsg[0] = 0;
                sigchld();
            }
        }
    }.callback, .{});

    // handle SIGCHLD
    try sigaction(std.posix.SIG.CHLD, &.{
        .handler = .{ .handler = _sigchld },
        .mask = std.posix.system.empty_sigset,
        .flags = std.posix.system.SA.NOCLDSTOP,
    });

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var dir = try std.fs.cwd().openDir("units", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try nextValid(&walker)) |ent| {
        std.debug.print("entry: {s}\n", .{ent.path});
        if (ent.kind == .file and std.mem.endsWith(u8, ent.basename, ".unit.json")) {
            std.debug.print("found a unit", .{});
            var f = try dir.openFile(ent.path, .{});
            const stat = try f.stat();
            const buf = try f.readToEndAllocOptions(allocator, std.math.maxInt(usize), stat.size, @alignOf(u8), null);
            defer allocator.free(buf);
            // var stream = std.json.TokenStream.init(buf);
            var parsed = try std.json.parseFromSlice(UnitJson, allocator, buf, .{});
            defer parsed.deinit();
            const unitized = try parsed.value.toUnit(&allocator);
            try units.append(unitized);
        }
    }

    for (units.items) |u| {
        if (u.kind == .Task) try units_tasks.append(u) else try units_daemons.append(u);
    }

    units.deinit();

    for (units_tasks.items) |*task| {
        try task.load();
    }
    for (units_daemons.items) |*daemon| {
        try daemon.load();
    }

    clients = @TypeOf(clients).init(allocator);

    defer {
        clients_mutex.lock();
        defer clients_mutex.unlock();
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

    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    var fd: std.posix.socket_t = undefined;
    var cl: std.posix.socket_t = undefined;

    fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);

    addr.family = std.posix.AF.UNIX;
    //@memset(addr.path[0..addr.path.len], 0);
    @memcpy(addr.path[0..8], "./socket");

    std.debug.print("{s}\n", .{addr.path}); // "./socket"

    std.fs.cwd().deleteFile("./socket") catch |e| switch (e) {
        error.FileNotFound => {},
        else => unreachable, // omg please stop
    };

    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try std.posix.listen(fd, 5); // backlog 5

    const S = struct {
        fn clientFn() !void {
            const socket = try std.net.connectUnixSocket("./socket");
            defer socket.close();
            std.debug.print("writing message\n", .{});
            try packets.writePacketWriter(socket.writer(), "Hello World!");
            std.debug.print("message written, client done\n", .{});
            // while (true) {
            //     var _buf: [512]u8 = undefined;
            //     var z = try readPacketReader(socket.reader(), &_buf);
            //     std.debug.print("in buf: {s}\n", .{z});
            // }
        }
    };

    const t = try std.Thread.spawn(.{}, S.clientFn, .{}); // spawn client
    defer t.join();
    const running = true;
    while (running) {
        cl = try std.posix.accept(fd, null, null, 0);
        // var creds = std.mem.zeroes(ucred);
        // var len: u32 = @sizeOf(ucred);
        // var thing = std.c.getsockopt(cl, std.posix.SOL_SOCKET, std.posix.SO_PEERCRED, @ptrCast(*c_void, &creds), &len);
        // std.debug.print("uid: {}\nerror: {}\nerrno: {}\n", .{ creds.uid, thing, std.posix.errno(thing) });
        var client = try Client.init(
            cl,
            &allocator,
            &clients,
            &clients_mutex,
        );
        try client.runEvLoop();
        clients_mutex.lock();
        defer clients_mutex.unlock();
        clients.append(client) catch {
            client.deinit();
            continue;
        };
        packets.writePacket(client.conn, "Hello World from your sweet server!") catch |e| switch (e) {
            error.BrokenPipe => {
                std.debug.print("pipe broken, couldn't send\n", .{});
            },
            else => unreachable,
        };
    }
    // var conn = try std.posix.accept(fd, null, null, 0);
    // var client = try Client.init(conn, allocator, &clients, &clients_mutex);
    // try client.runEvLoop();
    // const lock = clients_mutex.lock();
    // try clients.append(client);
    // lock.unlock();
}
