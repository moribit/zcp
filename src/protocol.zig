const std = @import("std");
const Connection = @import("transport.zig").Connection;
pub const version: u16 = 1;
pub const header_size = 16;
pub const Message = enum(u16) { handshake = 1, metadata = 2, resume_offset = 3, range = 4, chunk = 5, completion = 6, failure = 7 };
pub const Header = struct {
    kind: Message,
    flags: u32 = 0,
    length: u32,
    pub fn encode(h: Header) [16]u8 {
        var b: [16]u8 = undefined;
        @memcpy(b[0..4], "ZCP1");
        put(u16, b[4..6], version);
        put(u16, b[6..8], @backingInt(h.kind));
        put(u32, b[8..12], h.flags);
        put(u32, b[12..16], h.length);
        return b;
    }
    pub fn decode(b: *const [16]u8) !Header {
        if (!std.mem.eql(u8, b[0..4], "ZCP1")) return error.BadMagic;
        if (get(u16, b[4..6]) != version) return error.UnsupportedVersion;
        const kind = std.enums.fromInt(Message, get(u16, b[6..8])) orelse return error.UnknownMessage;
        if (get(u32, b[8..12]) != 0) return error.UnsupportedFlags;
        const length = get(u32, b[12..16]);
        if (length > 16 * 1024 * 1024 + 16) return error.OversizedMessage;
        return .{ .kind = kind, .length = length };
    }
};
pub fn put(comptime T: type, out: []u8, n: T) void {
    std.mem.writeInt(T, out[0..@sizeOf(T)], n, .big);
}
pub fn get(comptime T: type, in: []const u8) T {
    return std.mem.readInt(T, in[0..@sizeOf(T)], .big);
}
pub fn send(c: Connection, kind: Message, data: []const u8) !void {
    try c.write(&(Header{ .kind = kind, .length = @intCast(data.len) }).encode());
    try c.write(data);
}
pub fn readHeader(c: Connection) !Header {
    var b: [16]u8 = undefined;
    try c.read(&b);
    return Header.decode(&b);
}
pub fn expect(c: Connection, kind: Message, out: []u8) !void {
    const h = try readHeader(c);
    if (h.kind == .failure) {
        var message: [256]u8 = undefined;
        if (h.length > message.len) return error.InvalidErrorMessage;
        try c.read(message[0..h.length]);
        std.debug.print("receiver: {s}\n", .{message[0..h.length]});
        return error.RemoteFailure;
    }
    if (h.kind != kind or h.length != out.len) return error.UnexpectedMessage;
    try c.read(out);
}
pub fn fail(c: Connection, err: anyerror) void {
    send(c, .failure, @errorName(err)) catch {};
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.startsWith(u8, name, ".zcp-")) return false;
    for (name) |b| if (b == '/' or b == '\\' or b < 32 or b == 127) return false;
    return true;
}
pub const Metadata = struct {
    id: [32]u8,
    size: u64,
    buffer_size: u32,
    connections: u16,
    integrity: bool,
    resume_enabled: bool,
    name: []const u8,
    pub fn encode(m: Metadata, b: []u8) []const u8 {
        @memcpy(b[0..32], &m.id);
        put(u64, b[32..40], m.size);
        put(u32, b[40..44], m.buffer_size);
        put(u16, b[44..46], m.connections);
        b[46] = @intFromBool(m.integrity);
        b[47] = @intFromBool(m.resume_enabled);
        @memcpy(b[48..][0..m.name.len], m.name);
        return b[0 .. 48 + m.name.len];
    }
    pub fn decode(b: []const u8) !Metadata {
        if (b.len < 49 or b.len > 303 or !validName(b[48..])) return error.InvalidFilename;
        if (b[46] > 1 or b[47] > 1) return error.InvalidMetadata;
        const m: Metadata = .{ .id = b[0..32].*, .size = get(u64, b[32..40]), .buffer_size = get(u32, b[40..44]), .connections = get(u16, b[44..46]), .integrity = b[46] == 1, .resume_enabled = b[47] == 1, .name = b[48..] };
        if (m.buffer_size == 0 or m.buffer_size > 16 * 1024 * 1024 or m.connections == 0 or m.connections > 8 or m.size > std.math.maxInt(i64)) return error.InvalidMetadata;
        return m;
    }
};
test "header wire encoding and rejection" {
    var b = (Header{ .kind = .chunk, .length = 123 }).encode();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 5 }, b[4..8]);
    try std.testing.expectEqual(@as(u32, 123), (try Header.decode(&b)).length);
    b[0] = 0;
    try std.testing.expectError(error.BadMagic, Header.decode(&b));
    b[0] = 'Z';
    b[5] = 2;
    try std.testing.expectError(error.UnsupportedVersion, Header.decode(&b));
}
test "filename validation" {
    for ([_][]const u8{ "", "..", "../x", "a/b", "a\\b", ".zcp-state", "x\x00y" }) |s| try std.testing.expect(!validName(s));
    try std.testing.expect(validName("日本語 video.mp4"));
}
test "metadata roundtrip" {
    var b: [303]u8 = undefined;
    const m: Metadata = .{ .id = @splat(7), .size = 0x123456789, .buffer_size = 65536, .connections = 4, .integrity = true, .resume_enabled = true, .name = "a.mp4" };
    const decoded = try Metadata.decode(m.encode(&b));
    try std.testing.expectEqual(m.size, decoded.size);
    try std.testing.expectEqualSlices(u8, &m.id, &decoded.id);
}
