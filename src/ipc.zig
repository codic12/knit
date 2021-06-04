const max_len = 512;

pub fn writePacket(writer: anytype, bytes: []const u8) !void {
    if (bytes.len > max_len) return error.InvalidPacket;
    try writer.writeIntLittle(u32, @intCast(u32, bytes.len));
    try writer.writeAll(bytes);
}

pub fn readPacket(reader: anytype, buf: *[max_len]u8) ![]const u8 {
    const len = try reader.readIntLittle(u32);
    if (len > max_len) return error.InvalidPacket;
    const num_read = try reader.readAll(buf[0..len]);
    if (num_read != len) return error.Disconnected;
    return buf[0..len];
}
