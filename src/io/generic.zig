const std = @import("std");
const Connection = @import("../transport.zig").Connection;
const transfer = @import("../transfer.zig");
const Slot = struct { bytes: []u8, len: usize = 0, offset: u64 = 0, hash: u64 = 0 };
const Pipeline = struct {
    c: Connection,
    file: std.Io.File,
    range: transfer.Range,
    integrity: bool,
    slots: []Slot,
    free: std.Io.Queue(usize),
    ready: std.Io.Queue(usize),
    err: ?anyerror = null,
    fn produce(p: *Pipeline) void {
        defer p.ready.close(p.c.io);
        p.read() catch |err| {
            p.err = err;
        };
    }
    fn read(p: *Pipeline) !void {
        var off = p.range.start;
        while (off < p.range.end) {
            const i = try p.free.getOne(p.c.io);
            const s = &p.slots[i];
            s.len = @intCast(@min(s.bytes.len, p.range.end - off));
            s.offset = off;
            if (try p.file.readPositionalAll(p.c.io, s.bytes[0..s.len], off) != s.len) return error.SourceChanged;
            s.hash = if (p.integrity) @import("../integrity.zig").hash(s.bytes[0..s.len]) else 0;
            try p.ready.putOne(p.c.io, i);
            off += s.len;
        }
    }
};
pub fn send(c: Connection, allocator: std.mem.Allocator, file: std.Io.File, r: transfer.Range, size: u32, count: u16, integrity: bool) !void {
    const pool = try allocator.alloc(u8, @as(usize, size) * count);
    defer allocator.free(pool);
    if (count == 1) return transfer.buffered(c, file, r, pool, integrity);
    const slots = try allocator.alloc(Slot, count);
    defer allocator.free(slots);
    const free_storage = try allocator.alloc(usize, count);
    defer allocator.free(free_storage);
    const ready_storage = try allocator.alloc(usize, count);
    defer allocator.free(ready_storage);
    var pipeline: Pipeline = .{ .c = c, .file = file, .range = r, .integrity = integrity, .slots = slots, .free = .init(free_storage), .ready = .init(ready_storage) };
    for (slots, 0..) |*s, i| {
        s.* = .{ .bytes = pool[i * size ..][0..size] };
        try pipeline.free.putOne(c.io, i);
    }
    var group: std.Io.Group = .init;
    defer {
        pipeline.free.close(c.io);
        pipeline.ready.close(c.io);
        group.cancel(c.io);
    }
    try group.concurrent(c.io, Pipeline.produce, .{&pipeline});
    while (true) {
        const i = pipeline.ready.getOne(c.io) catch |err| switch (err) {
            error.Closed => break,
            else => return err,
        };
        const s = &slots[i];
        try transfer.sendHashedChunk(c, s.offset, s.bytes[0..s.len], s.hash);
        try pipeline.free.putOne(c.io, i);
    }
    try group.await(c.io);
    if (pipeline.err) |err| return err;
}
