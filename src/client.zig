const std = @import("std");
const max_len = 512;
const packets = @import("packets.zig");

const Error = error{NotRunning};

pub const Client = struct {
    conn: std.posix.socket_t,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    allocator: *const std.mem.Allocator,
    clients: *std.ArrayList(*Client),
    clients_mutex: *std.Thread.Mutex,

    fn readerThreadProc(self: *Client) void {
        while (self.running.load(.seq_cst)) {
            var buf: [max_len]u8 = undefined;
            std.debug.print("about to...\n", .{});
            const x = packets.readPacket(self.conn, &buf) catch |e| {
                switch (e) {
                    error.EndOfStream, error.ConnectionResetByPeer => {
                        std.debug.print("eof\n", .{});
                        break; // out of the while loop
                    },
                    else => {
                        std.debug.print("e: {}\n", .{e});
                        std.posix.exit(1);
                    }, // add more
                }
            };
            std.debug.print("got packet {s}\n", .{x});
        }
        self.running.store(false, .seq_cst);
        std.debug.print("loop done!\n", .{});
        // the loop is done!
        // acquire lock
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock(); // and release it later
        std.debug.print("lock acquired!\n", .{});
        var idx_outer: ?usize = null;
        for (self.clients.items, 0..) |item, idx| {
            if (item == self) {
                std.debug.print("destroying myself\n", .{});
                std.debug.print("The len is: {} and we are removing at: {}\n", .{ self.clients.items.len, idx });
                idx_outer = idx;
                break;
            }
        }
        if (idx_outer) |i| {
            _ = self.clients.swapRemove(i);
            self.deinit();
        } else unreachable;
    }

    pub fn runEvLoop(self: *Client) !void {
        self.thread = try std.Thread.spawn(.{}, readerThreadProc, .{self});
    }

    // ctor
    pub fn init(
        c: std.posix.socket_t,
        allocator: *const std.mem.Allocator,
        clients: *std.ArrayList(*Client),
        clients_mutex: *std.Thread.Mutex,
    ) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .conn = c,
            .running = undefined,
            .thread = undefined,
            .allocator = allocator,
            .clients = clients,
            .clients_mutex = clients_mutex,
        };
        client.running.store(true, .seq_cst);
        return client;
    }

    // dtor
    pub fn deinit(self: *Client) void {
        self.running.store(false, .seq_cst);
        // self.thread.wait();
        self.allocator.destroy(self);
    }
};
