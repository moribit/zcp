const std = @import("std");
const p = @import("protocol.zig");
const Connection = @import("transport.zig").Connection;
pub const Range = struct { start: u64, end: u64 };
pub fn range(size: u64, count: u16, index: u16) Range {
    const base = size / count;
    const extra = size % count;
    const start = base * index + @min(index, extra);
    return .{ .start = start, .end = start + base + @intFromBool(index < extra) };
}
pub fn sendChunk(c: Connection, off: u64, bytes: []const u8, integrity: bool) !void {
    return sendHashedChunk(c, off, bytes, if (integrity) @import("integrity.zig").hash(bytes) else 0);
}
pub fn sendHashedChunk(c: Connection, off: u64, bytes: []const u8, hash: u64) !void {
    var header: [32]u8 = undefined;
    @memcpy(header[0..16], &(p.Header{ .kind = .chunk, .length = @intCast(bytes.len + 16) }).encode());
    p.put(u64, header[16..24], off);
    p.put(u64, header[24..32], hash);
    // One vectored socket write avoids tiny TCP header packets.
    var writer = c.stream.writer(c.io, &.{});
    var vectors = [_][]const u8{ &header, bytes };
    try writer.interface.writeVecAll(&vectors);
}
pub fn buffered(c: Connection, file: std.Io.File, r: Range, buffer: []u8, integrity: bool) !void {
    var off = r.start;
    while (off < r.end) {
        const n: usize = @intCast(@min(buffer.len, r.end - off));
        if (try file.readPositionalAll(c.io, buffer[0..n], off) != n) return error.SourceChanged;
        try sendChunk(c, off, buffer[0..n], integrity);
        off += n;
    }
}
test "ranges partition huge and empty files" {
    for ([_]u64{ 0, 1, 7, 123456789012 }) |size| for ([_]u16{ 1, 2, 4, 8 }) |count| {
        var previous: u64 = 0;
        for (0..count) |i| {
            const r = range(size, count, @intCast(i));
            try std.testing.expectEqual(previous, r.start);
            try std.testing.expect(r.end >= r.start);
            previous = r.end;
        }
        try std.testing.expectEqual(size, previous);
    };
}
