const std = @import("std");
const p = @import("protocol.zig");
const net = @import("transport.zig");
const transfer = @import("transfer.zig");
const Options = @import("cli.zig").Options;
const Worker = struct {
    c: net.Connection,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    state: std.Io.File,
    metadata: p.Metadata,
    index: u16,
    offset: u64,
    err: ?anyerror = null,
    fn start(w: *Worker) void {
        defer w.c.close();
        w.run() catch |err| {
            w.err = err;
            p.fail(w.c, err);
        };
    }
    fn checkpoint(w: *Worker) !void {
        var b: [16]u8 = undefined;
        p.put(u64, b[0..8], w.offset);
        p.put(u64, b[8..16], ~w.offset);
        try w.state.writePositionalAll(w.c.io, &b, 512 + @as(u64, w.index) * 16);
    }
    fn run(w: *Worker) !void {
        const io = w.c.io;
        const r = transfer.range(w.metadata.size, w.metadata.connections, w.index);
        var response: [16]u8 = undefined;
        p.put(u64, response[0..8], w.offset);
        p.put(u64, response[8..16], r.end);
        try p.send(w.c, .resume_offset, &response);
        const buffer = try w.allocator.alloc(u8, w.metadata.buffer_size);
        defer w.allocator.free(buffer);
        while (w.offset < r.end) {
            const h = try p.readHeader(w.c);
            if (h.kind != .chunk or h.length <= 16 or h.length > buffer.len + 16 or h.length - 16 > r.end - w.offset) return error.InvalidChunk;
            var chunk: [16]u8 = undefined;
            try w.c.read(&chunk);
            if (p.get(u64, chunk[0..8]) != w.offset) return error.InvalidChunkOffset;
            const bytes = buffer[0 .. h.length - 16];
            try w.c.read(bytes);
            if (w.metadata.integrity) try @import("integrity.zig").verify(bytes, p.get(u64, chunk[8..16])) else if (p.get(u64, chunk[8..16]) != 0) return error.UnexpectedHash;
            try w.file.writePositionalAll(io, bytes, w.offset);
            w.offset += bytes.len;
            try w.checkpoint();
        }
        try p.expect(w.c, .completion, &.{});
        try p.send(w.c, .completion, &.{});
    }
};
const Batch = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    workers: []Worker,
    id: [32]u8,
    err: ?anyerror = null,
    fn start(b: *Batch) void {
        b.run() catch |err| {
            b.err = err;
        };
    }
    fn run(b: *Batch) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(b.io);
        var seen: [8]bool = @splat(false);
        for (0..b.workers.len) |_| {
            const stream = try b.server.accept(b.io);
            const c: net.Connection = .{ .stream = stream, .io = b.io };
            const greeting = hello(c) catch |err| {
                c.close();
                return err;
            };
            const index = p.get(u16, greeting[32..34]);
            if (index >= b.workers.len or seen[index] or !std.mem.eql(u8, greeting[0..32], &b.id)) {
                p.fail(c, error.InvalidRangeConnection);
                c.close();
                return error.InvalidRangeConnection;
            }
            var assigned: [16]u8 = undefined;
            p.expect(c, .range, &assigned) catch |err| {
                p.fail(c, err);
                c.close();
                return err;
            };
            const r = transfer.range(b.workers[index].metadata.size, @intCast(b.workers.len), index);
            if (p.get(u64, assigned[0..8]) != r.start or p.get(u64, assigned[8..16]) != r.end) {
                p.fail(c, error.InvalidRange);
                c.close();
                return error.InvalidRange;
            }
            seen[index] = true;
            b.workers[index].c = c;
            group.concurrent(b.io, Worker.start, .{&b.workers[index]}) catch |err| {
                c.close();
                return err;
            };
        }
        try group.await(b.io);
        for (b.workers) |w| if (w.err) |err| return err;
    }
};
fn hello(c: net.Connection) ![34]u8 {
    var bytes: [34]u8 = undefined;
    try p.expect(c, .handshake, &bytes);
    return bytes;
}
fn session(io: std.Io, allocator: std.mem.Allocator, server: *std.Io.net.Server, dir: std.Io.Dir, c: net.Connection) !void {
    const started: std.Io.Timestamp = .now(io, .awake);
    const initial = try hello(c);
    if (p.get(u16, initial[32..34]) != 65535) return error.ExpectedControlConnection;
    const h = try p.readHeader(c);
    if (h.kind != .metadata or h.length > 303) return error.InvalidMetadata;
    var bytes: [303]u8 = undefined;
    try c.read(bytes[0..h.length]);
    const m = try p.Metadata.decode(bytes[0..h.length]);
    // Canonical persistent metadata excludes the resume request flag.
    bytes[47] = 0;
    @memset(bytes[40..44], 0); // Buffer size can change when resuming.
    var name_buffer: [96]u8 = undefined;
    const key = std.fmt.bytesToHex(m.id, .lower);
    const part_name = try std.fmt.bufPrint(&name_buffer, ".zcp-{s}-{d}.part", .{ key, m.connections });
    var state_buffer: [100]u8 = undefined;
    const state_name = try std.fmt.bufPrint(&state_buffer, ".zcp-{s}-{d}.state", .{ key, m.connections });
    // Refuse existing destinations before transferring; renamePreserve closes the race.
    if (dir.openFile(io, m.name, .{})) |existing| {
        existing.close(io);
        return error.DestinationExists;
    } else |err| if (err != error.FileNotFound) return err;
    const file = try dir.createFile(io, part_name, .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    defer file.close(io);
    const state = try dir.createFile(io, state_name, .{ .read = true, .truncate = false });
    defer state.close(io);
    var stored: [303]u8 = undefined;
    const state_stat = try state.stat(io);
    if (m.resume_enabled and state_stat.size != 0) {
        var length: [2]u8 = undefined;
        if (try state.readPositionalAll(io, &length, 304) != 2 or p.get(u16, &length) != h.length) return error.ResumeMetadataMismatch;
        if (try state.readPositionalAll(io, stored[0..h.length], 0) != h.length or !std.mem.eql(u8, stored[0..h.length], bytes[0..h.length])) return error.ResumeMetadataMismatch;
    } else {
        try file.setLength(io, 0);
        try state.setLength(io, 0);
        try state.writePositionalAll(io, bytes[0..h.length], 0);
        var length: [2]u8 = undefined;
        p.put(u16, &length, @intCast(h.length));
        try state.writePositionalAll(io, &length, 304);
    }
    const workers = try allocator.alloc(Worker, m.connections);
    defer allocator.free(workers);
    const file_size = (try file.stat(io)).size;
    for (workers, 0..) |*w, i| {
        const r = transfer.range(m.size, m.connections, @intCast(i));
        var off = r.start;
        if (m.resume_enabled and state_stat.size != 0) {
            var saved: [16]u8 = undefined;
            if (try state.readPositionalAll(io, &saved, 512 + i * 16) == 16) {
                const candidate = p.get(u64, saved[0..8]);
                if (candidate == ~p.get(u64, saved[8..16]) and candidate >= r.start and candidate <= r.end and candidate <= file_size) off = candidate;
            }
        }
        w.* = .{ .c = undefined, .allocator = allocator, .file = file, .state = state, .metadata = m, .index = @intCast(i), .offset = off };
    }
    var skipped: u64 = 0;
    for (workers) |w| skipped += w.offset - transfer.range(m.size, m.connections, w.index).start;
    try p.send(c, .metadata, &.{});
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    if (m.connections == 1) {
        var assigned: [16]u8 = undefined;
        try p.expect(c, .range, &assigned);
        if (p.get(u64, assigned[0..8]) != 0 or p.get(u64, assigned[8..16]) != m.size) return error.InvalidRange;
        workers[0].c = c;
        try workers[0].run();
        try p.expect(c, .completion, &.{});
    } else {
        var batch: Batch = .{ .io = io, .server = server, .workers = workers, .id = m.id };
        try group.concurrent(io, Batch.start, .{&batch});
        // Control EOF cancels accept and read tasks, including before workers arrive.
        try p.expect(c, .completion, &.{});
        try group.await(io);
        if (batch.err) |err| return err;
    }
    try file.setLength(io, m.size);
    try file.sync(io);
    try state.sync(io);
    try std.Io.Dir.renamePreserve(dir, part_name, dir, m.name, io);
    dir.deleteFile(io, state_name) catch {};
    try p.send(c, .completion, &.{});
    std.debug.print("Received: {s} ({d} bytes)\n", .{ m.name, m.size });
    @import("progress.zig").report(io, started, m.size - skipped, skipped, .{ .buffer_size = m.buffer_size, .connections = m.connections, .integrity = m.integrity, .command = .receive });
}
pub fn run(io: std.Io, allocator: std.mem.Allocator, o: Options) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, o.output, .{});
    defer dir.close(io);
    const address = try std.Io.net.IpAddress.parse(o.bind, o.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("Listening: {s}:{d}\n", .{ o.bind, o.port });
    while (true) {
        const stream = try server.accept(io);
        const c: net.Connection = .{ .stream = stream, .io = io };
        defer c.close();
        session(io, allocator, &server, dir, c) catch |err| {
            p.fail(c, err);
            std.debug.print("receive: {s}\n", .{@errorName(err)});
            if (o.once) return err;
        };
        if (o.once) return;
    }
}
