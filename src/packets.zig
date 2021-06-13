const max_len = 512;
const std = @import("std");

pub fn writePacket(writer: std.os.fd_t, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    var ln: [(@typeInfo(u32).Int.bits + 7) / 8]u8 = undefined;
    std.mem.writeIntLittle(u32, &ln, @intCast(u32, bytes.len));
    _ = try std.os.send(writer, &ln, std.os.MSG_NOSIGNAL);
    _ = try std.os.send(writer, bytes, std.os.MSG_NOSIGNAL);
}

pub fn readPacket(reader: std.os.fd_t, buf: *[max_len]u8) ![]const u8 {
    var ln: [4]u8 = undefined;
    var x = try std.os.recv(reader, &ln, std.os.MSG_NOSIGNAL); // read the length
    std.debug.print("finished recv\n", .{});
    if (x == 0) {
        return error.EndOfStream;
    }
    const len = std.mem.readIntLittle(u32, &ln);
    if (len > max_len) return error.InvalidPacket;
    var idx: usize = 0;
    while (idx != len) { 
        const num_read = try std.os.recv(reader, buf[idx..], std.os.MSG_NOSIGNAL);
        if (num_read == 0) {
            return error.EndOfStream;
        }
        idx += num_read;
        std.debug.print("idx: {}\nbuf len: {}\n", .{idx, buf.len});
    }
    std.debug.print("finished main loop\n", .{});
    if (idx != len) return error.Disconnected;
    return buf[0..len];
}

pub fn writePacketWriter(writer: anytype, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    try writer.writeIntLittle(u32, @intCast(u32, bytes.len));
    try writer.writeAll(bytes);
}

pub fn readPacketReader(reader: anytype, buf: *[max_len]u8) ![]const u8 {
    const len = try reader.readIntLittle(u32);
    if (len > max_len) return error.InvalidPacket;
    const num_read = try reader.readAll(buf[0..len]);
    if (num_read != len) return error.Disconnected;
    return buf[0..len];
}