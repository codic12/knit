const std = @import("std");
const max_len = 512;
usingnamespace @import("packets.zig");

pub const Client = struct {
    conn: std.net.StreamServer.Connection,
    thread: *std.Thread,
    running: std.atomic.Atomic(bool),
    allocator: *std.mem.Allocator,
    clients: *std.ArrayList(*Client),
    clients_mutex: *std.Thread.Mutex,

    fn readerThreadProc(self: *Client) void {
        std.debug.print("Hallo ", .{});
        while (self.running.load(.SeqCst)) {
            var buf: [max_len]u8 = undefined;
            std.debug.print("about to...", .{});
            var x = readPacket(self.conn.stream.reader(), &buf) catch |e| {
                switch (e) {
                    error.EndOfStream => {
                        self.running.store(false, .SeqCst);
                        break; // out of the while loop
                    },
                    else => unreachable, // add more
                }
            };
            std.debug.print("x {s}\n", .{x});
        }
        std.debug.print("loop done!\n", .{});
        // the loop is done!
        // acquire lock
        const lock = self.clients_mutex.acquire();
        defer lock.release(); // and release it later
        std.debug.print("lock acquired!\n", .{});
        var idx_outer: ?usize = undefined;
        for (self.clients.items) |item, idx| {
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
        self.thread = try std.Thread.spawn(readerThreadProc, self);
    }

    // ctor
    pub fn init(
        c: std.net.StreamServer.Connection,
        allocator: *std.mem.Allocator,
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
        client.running.store(true, .SeqCst);
        return client;
    }

    // dtor
    pub fn deinit(self: *Client) void {
        self.running.store(false, .SeqCst);
        // self.thread.wait();
        self.allocator.destroy(self);
    }
};
