const std = @import("std");
const unit = @import("unit.zig");
const max_len = 512;
const Error = error{SystemCallFailure};
const net = std.net;
const Mutex = std.Thread.Mutex;

var units: std.ArrayList(*unit.Unit) = undefined;
var clients: std.ArrayList(*Client) = undefined;
var clients_mutex = Mutex {};
fn sigchld(signo: i32) callconv(.C) void {
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
            std.debug.warn("note: killed by signal\n", .{});
        }
    }
}

fn writePacket(writer: anytype, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    try writer.writeIntLittle(u32, @intCast(u32, bytes.len));
    try writer.writeAll(bytes);
}

fn readPacket(reader: anytype, buf: *[max_len]u8) ![]const u8 {
    const len = try reader.readIntLittle(u32);
    if (len > max_len) return error.InvalidPacket;
    const num_read = try reader.readAll(buf[0..len]);
    if (num_read != len) return error.Disconnected;
    return buf[0..len];
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
        else => return error.SystemCallFailure, // Nein, nein, nein! Our errors muss grosser sein, sein, sein!
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
    std.debug.warn("{s}\n", .{x.commands});
    var y = try x.toUnit(allocator);
    defer y.deinit();
    std.debug.warn("{any}\n", .{y.cmds[0]});
    defer l.deinit();
    try units.append(&l);
    try l.load(&env);
    std.debug.warn("done loading\n", .{});

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    const socket_path = "socket.unix";

    var socket_addr = try net.Address.initUnix(socket_path);
    clients = std.ArrayList(*Client).init(allocator);
    defer clients.deinit();
    defer for (clients.items) |item| item.deinit(); // dont bother removing, we're gonna clean it up and exit anyways
    defer std.fs.cwd().deleteFile(socket_path) catch {};
    try server.listen(socket_addr);

    const S = struct {
        fn clientFn(_: void) !void {
            const socket = try net.connectUnixSocket(socket_path);
            defer socket.close();

            try writePacket(socket.writer(), "Hello World!");
            // while (true) {
            //     var buf: [max_len]u8 = undefined;
            //     _ = try readPacket(socket.reader(), &buf);
            // }
        }
    };

    const t = try std.Thread.spawn(S.clientFn, {}); // spawn client
    defer t.wait();
    var running = true;
    while (running) {
        var conn = try server.accept();
        var client = Client.init(conn, allocator) catch continue;
        defer client.deinit();
        try client.runEvLoop();
        const lock = clients_mutex.tryAcquire().?;
        defer lock.release();
        clients.append(client) catch {
            client.deinit();
            continue;
        };
    }
    
}

const Client = struct {
    conn: net.StreamServer.Connection,
    thread: *std.Thread,
    running: std.atomic.Bool, // I think this works
    allocator: *std.mem.Allocator,
    // other state
    // maybe some queues of packets or something

    fn readerThreadProc(self: *Client) void {
        std.debug.warn("Hallo ", .{});
        while (self.running.load(.SeqCst)) {
            var buf: [max_len]u8 = undefined;
            std.debug.warn("about to...", .{});
            var x = readPacket(self.conn.stream.reader(), &buf) catch |e| {
                switch (e) {
                    error.EndOfStream => {
                        self.running.store(false, .SeqCst);
                        break; // out of the while loop
                    },
                    else => unreachable, // add more
                }
            };
            std.debug.warn("x {s}\n", .{x});
        }
        std.debug.warn("loop done!\n", .{});
        // the loop is done!
        // acquire lock
        const lock = clients_mutex.tryAcquire().?;
        defer lock.release(); // and release it later
        std.debug.warn("lock acquired!\n", .{});
        for (clients.items) |item, idx| {
            if (item == self) {
                std.debug.warn("destroying myself\n", .{});
                item.deinit();
                _ = clients.swapRemove(idx);
                break;
            }
        }
    }

    pub fn runEvLoop(self: *Client) !void {
        self.thread = try std.Thread.spawn(readerThreadProc, self);
    }

    pub fn init(c: net.StreamServer.Connection, allocator: *std.mem.Allocator) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .conn = c,
            .running = undefined,
            .thread = undefined,
            .allocator = allocator,
        };
        client.running.store(true, .SeqCst);
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.running.store(false, .SeqCst);
        self.thread.wait();
        self.allocator.destroy(self);
    }
};
