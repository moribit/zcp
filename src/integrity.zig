const std = @import("std");
const p = @import("protocol.zig");
pub fn hash(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(0, bytes);
}
pub fn verify(bytes: []const u8, expected: u64) !void {
    if (hash(bytes) != expected) return error.CorruptedChunk;
}
// Stable source identity: source metadata plus three bounded content samples.
// This is an identity, not a full-file content checksum (see protocol specification).
pub fn identity(io: std.Io, file: std.Io.File, stat: std.Io.File.Stat) ![32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("zcp-source-identity-v1");
    var meta: [48]u8 = undefined;
    p.put(u64, meta[0..8], stat.size);
    p.put(u64, meta[8..16], @intCast(stat.inode));
    p.put(i128, meta[16..32], stat.mtime.nanoseconds);
    p.put(i128, meta[32..48], stat.ctime.nanoseconds);
    h.update(&meta);
    var sample: [65536]u8 = undefined;
    const offsets = [_]u64{ 0, stat.size / 2, stat.size -| sample.len };
    for (offsets) |off| {
        const len: usize = @intCast(@min(sample.len, stat.size - off));
        if (try file.readPositionalAll(io, sample[0..len], off) != len) return error.SourceChanged;
        h.update(sample[0..len]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}
test "corruption detected" {
    var bytes = [_]u8{ 1, 2, 3, 4 };
    const expected = hash(&bytes);
    try verify(&bytes, expected);
    bytes[2] ^= 1;
    try std.testing.expectError(error.CorruptedChunk, verify(&bytes, expected));
}
