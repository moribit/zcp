const std = @import("std");
const Options = @import("cli.zig").Options;
pub fn report(io: std.Io, start: std.Io.Timestamp, bytes: u64, skipped: u64, o: Options) void {
    const elapsed = @as(f64, @floatFromInt(start.durationTo(.now(io, .awake)).nanoseconds)) / 1e9;
    const seconds = @max(elapsed, 0.000000001);
    const amount: f64 = @floatFromInt(bytes);
    std.debug.print("Transferred: {d:.3} GiB\nElapsed:     {d:.6} s\nAverage:     {d:.2} MB/s ({d:.2} MiB/s)\nResumed:     {d} bytes\nBuffer:      {d} bytes x {d}; connections: {d}; I/O: {s}; integrity: {s}\nPayload RAM:  {d} bytes (payload pool; excludes runtime/kernel/cache)\n", .{ amount / 1073741824, elapsed, amount / seconds / 1e6, amount / seconds / 1048576, skipped, o.buffer_size, o.buffers, o.connections, @tagName(o.io_backend), if (o.integrity) "on" else "off", if (o.io_backend == .zero_copy) @as(u64, 0) else @as(u64, o.buffer_size) * o.buffers * o.connections });
}
