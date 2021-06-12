const max_len = 512;
const std = @import("std");

pub fn writePacket(writer: std.os.fd_t, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    var ln: [(@typeInfo(u32).Int.bits + 7) / 8]u8 = undefined;
    std.mem.writeIntLittle(u32, &ln, @intCast(u32, bytes.len));
    try std.os.send(fd, &ln, std.os.MSG_NOSIGNAL);
    try std.os.send(fd, &bytes, std.os.MSG_NOSIGNAL);
}

pub fn readPacket(reader: std.os.fd_t, buf: *[max_len]u8) ![]const u8 {
    var ln: [4]u8 = undefined;
    _ = try std.os.recv(reader, &ln, std.os.MSG_NOSIGNAL);
    const len = std.mem.readIntLittle(u32, &ln);
    if (len > max_len) return error.InvalidPacket;
    var idx: usize = 0;
    while (idx != buf.len) {
        const num_read = try std.os.recv(reader, buf[0..len], std.os.MSG_NOSIGNAL);
        if (num_read == 0) {
            return error.EndOfStream;
        }
        idx += num_read;
    }
    if (idx != len) return error.Disconnected;
    return buf[0..len];
}
