const std = @import("std");
const net = std.net;
const max_len = 512;

fn writePacket(writer: anytype, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    try writer.writeIntLittle(u32, @intCast(u32, bytes.len));
    try writer.writeAll(bytes);
}

fn readPacket(reader: anytype, buf: *[max_len]u8) ![]u8 {
    const len = try reader.readIntLittle(u32);
    if (len > max_len) return error.InvalidPacket;
    const num_read = try reader.readAll(buf[0..len]);
    if (num_read != len) return error.Disconnected;
    return buf[0..len];
}

pub fn main() !void {
    var server = net.StreamServer.init(.{});
    defer server.deinit();

    const socket_path = "socket.unix";

    var socket_addr = try net.Address.initUnix(socket_path);
    var clients = std.ArrayList(*net.StreamServer.Connection).init(std.heap.page_allocator);
    defer clients.deinit();
    defer std.fs.cwd().deleteFile(socket_path) catch {};
    try server.listen(socket_addr);

    const S = struct {
        fn clientFn(_: void) !void {
            const socket = try net.connectUnixSocket(socket_path);
            defer socket.close();

            try writePacket(socket.writer(), "Hello World!");
            while (true) {
                var buf: [max_len]u8 = undefined;
                _ = try readPacket(socket.reader(), &buf);
            }
        }
    };

    const t = try std.Thread.spawn(S.clientFn, {}); // spawn client
    defer t.wait();

    while (true) {
        var conn = try server.accept();
        var client = try Client.init(conn);
        try client.runEvLoop();
    }
}

const Client = struct {
    conn: net.StreamServer.Connection,
    thread: *std.Thread,
    running: std.atomic.Bool, // I think this works
    // other state
    // maybe some queues of packets or something

    fn readerThreadProc(self: *Client) void {
        while (self.running.load(.SeqCst)) {
            var buf: [max_len]u8 = undefined;
            var x = readPacket(self.conn.stream.reader(), &buf) catch |e| {
                switch (e) {
                    error.EndOfStream => break,
                    else => unreachable, // add more
                }
            };
            std.debug.warn("{s}\n", .{x});
        }
    }
    pub fn runEvLoop(self: *Client) !void {
        _ = try std.Thread.spawn(readerThreadProc, self);
    }

    pub fn init(c: net.StreamServer.Connection) !Client {
        var client: Client = undefined;
        client.conn = c;
        client.running.store(true, .SeqCst);
        client.thread = undefined;
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.running.store(false, .SeqCst);
        // send disconnect packet
        // close connection
        self.thread.join();
        // free client memory
    }
};
