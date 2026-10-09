const std = @import("std");
const p = @import("protocol.zig");
const net = @import("transport.zig");
const transfer = @import("transfer.zig");
const Options = @import("cli.zig").Options;
const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    o: Options,
    file: std.Io.File,
    id: [32]u8,
    size: u64,
    index: u16,
    skipped: u64 = 0,
    err: ?anyerror = null,
    fn start(w: *Worker) void {
        w.run() catch |err| {
            w.err = err;
        };
    }
    fn run(w: *Worker) !void {
        const c = try net.connect(w.io, w.o.endpoint);
        defer c.close();
        var hello: [34]u8 = undefined;
        @memcpy(hello[0..32], &w.id);
        p.put(u16, hello[32..34], w.index);
        try p.send(c, .handshake, &hello);
        try w.onConnection(c);
    }
    fn onConnection(w: *Worker, c: net.Connection) !void {
        const r = transfer.range(w.size, w.o.connections, w.index);
        var assigned: [16]u8 = undefined;
        p.put(u64, assigned[0..8], r.start);
        p.put(u64, assigned[8..16], r.end);
        try p.send(c, .range, &assigned);
        var response: [16]u8 = undefined;
        try p.expect(c, .resume_offset, &response);
        const off = p.get(u64, response[0..8]);
        if (off < r.start or off > r.end or p.get(u64, response[8..16]) != r.end or (!w.o.resume_enabled and off != r.start)) return error.InvalidResumeOffset;
        w.skipped = off - r.start;
        const remaining: transfer.Range = .{ .start = off, .end = r.end };
        switch (w.o.io_backend) {
            .generic => try @import("io/generic.zig").send(c, w.allocator, w.file, remaining, w.o.buffer_size, w.o.buffers, w.o.integrity),
            .zero_copy => try @import("io/zero_copy.zig").send(c, w.file, remaining, w.o.buffer_size),
        }
        try p.send(c, .completion, &.{});
        try p.expect(c, .completion, &.{});
    }
};
pub fn run(io: std.Io, allocator: std.mem.Allocator, o: Options) !void {
    const file = try std.Io.Dir.cwd().openFile(io, o.path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    const id = try @import("integrity.zig").identity(io, file, stat);
    const name = std.fs.path.basename(o.path);
    if (!p.validName(name)) return error.InvalidFilename;
    const start: std.Io.Timestamp = .now(io, .awake);
    const c = try net.connect(io, o.endpoint);
    defer c.close();
    var hello: [34]u8 = @splat(0);
    p.put(u16, hello[32..34], 65535);
    try p.send(c, .handshake, &hello);
    var encoded: [303]u8 = undefined;
    const metadata: p.Metadata = .{ .id = id, .size = stat.size, .buffer_size = o.buffer_size, .connections = o.connections, .integrity = o.integrity, .resume_enabled = o.resume_enabled, .name = name };
    try p.send(c, .metadata, metadata.encode(&encoded));
    try p.expect(c, .metadata, &.{});
    const workers = try allocator.alloc(Worker, o.connections);
    defer allocator.free(workers);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (workers, 0..) |*w, index| {
        w.* = .{ .io = io, .allocator = allocator, .o = o, .file = file, .id = id, .size = stat.size, .index = @intCast(index) };
        if (o.connections == 1) try w.onConnection(c) else try group.concurrent(io, Worker.start, .{w});
    }
    try group.await(io);
    var skipped: u64 = 0;
    for (workers) |w| {
        if (w.err) |err| return err;
        skipped += w.skipped;
    }
    const after = try file.stat(io);
    if (after.size != stat.size or after.mtime.nanoseconds != stat.mtime.nanoseconds or after.ctime.nanoseconds != stat.ctime.nanoseconds) return error.SourceChanged;
    try p.send(c, .completion, &.{});
    try p.expect(c, .completion, &.{});
    @import("progress.zig").report(io, start, stat.size - skipped, skipped, o);
}
