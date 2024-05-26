const max_len = 512;
const std = @import("std");

pub fn writePacket(writer: std.posix.fd_t, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    var ln: [(@typeInfo(u32).Int.bits + 7) / 8]u8 = undefined;
    std.mem.writeInt(u32, &ln, @intCast(bytes.len), .little);
    _ = try std.posix.send(writer, &ln, 0);
    _ = try std.posix.send(writer, bytes, 0);
}

pub fn readPacket(reader: std.posix.fd_t, buf: *[max_len]u8) ![]const u8 {
    var ln: [4]u8 = undefined;
    const x = try std.posix.recv(reader, &ln, 0); // read the length
    std.debug.print("finished recv\n", .{});
    if (x == 0) {
        return error.EndOfStream;
    }
    const len = std.mem.readInt(u32, &ln, .little);
    if (len > max_len) return error.InvalidPacket;
    var idx: usize = 0;
    while (idx != len) {
        const num_read = try std.posix.recv(reader, buf[idx..], 0);
        if (num_read == 0) {
            return error.EndOfStream;
        }
        idx += num_read;
        std.debug.print("idx: {}\nbuf len: {}\n", .{ idx, buf.len });
    }
    std.debug.print("finished main loop\n", .{});
    if (idx != len) return error.Disconnected;
    return buf[0..len];
}

pub fn writePacketWriter(writer: anytype, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}

pub fn readPacketReader(reader: anytype, buf: *[max_len]u8) ![]const u8 {
    const len = try reader.readInt(u32, .little);
    if (len > max_len) return error.InvalidPacket;
    const num_read = try reader.readAll(buf[0..len]);
    if (num_read != len) return error.Disconnected;
    return buf[0..len];
}
