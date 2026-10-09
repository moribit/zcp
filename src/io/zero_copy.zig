const std = @import("std");
const p = @import("../protocol.zig");
const Connection = @import("../transport.zig").Connection;
const Range = @import("../transfer.zig").Range;
// Strict sendfile backend: never silently substitute a buffered copy.
pub fn send(c: Connection, file: std.Io.File, r: Range, chunk_size: u32) !void {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.ZeroCopyUnavailable;
    var off = r.start;
    while (off < r.end) {
        const size: usize = @intCast(@min(chunk_size, r.end - off));
        var header: [32]u8 = undefined;
        @memcpy(header[0..16], &(p.Header{ .kind = .chunk, .length = @intCast(size + 16) }).encode());
        p.put(u64, header[16..24], off);
        p.put(u64, header[24..32], 0);
        try c.write(&header);
        var left = size;
        while (left > 0) {
            const n = try nativeSend(c, file, off + size - left, left);
            if (n == 0) return error.SourceChanged;
            left -= n;
        }
        off += size;
    }
}

// The 0.17 netWriteFile vtable is unimplemented, and its macOS File.Writer
// path asserts while consuming an unbuffered reader. Use std.c's typed OS
// bindings instead; libc is the sole system dependency. No buffered fallback.
fn nativeSend(c: Connection, file: std.Io.File, offset: u64, count: usize) !usize {
    while (true) {
        try c.io.checkCancel();
        switch (@import("builtin").os.tag) {
            .macos => {
                var len: std.c.off_t = @intCast(@min(count, 0x7ffff000));
                const rc = std.c.sendfile(file.handle, c.stream.socket.handle, @intCast(offset), &len, null, 0);
                const e = std.c.errno(rc);
                // macOS reports bytes transferred even on EINTR/EAGAIN.
                if (e == .SUCCESS or e == .INTR or e == .AGAIN) {
                    if (len > 0) return @intCast(len);
                    if (e == .INTR) continue;
                    if (e == .AGAIN) return error.NativeWouldBlock;
                    return 0;
                }
                return nativeError(e);
            },
            .linux => {
                var pos: std.c.off_t = @intCast(offset);
                const rc = std.c.sendfile(c.stream.socket.handle, file.handle, &pos, @min(count, 0x7ffff000));
                const e = std.c.errno(rc);
                if (e == .SUCCESS) return @intCast(rc);
                if (e == .INTR) continue;
                return nativeError(e);
            },
            else => return error.ZeroCopyUnavailable,
        }
    }
}
fn nativeError(e: std.c.E) anyerror {
    return switch (e) {
        .OPNOTSUPP, .NOSYS, .INVAL, .NOTSOCK => error.ZeroCopyUnavailable,
        .PIPE, .NOTCONN, .CONNRESET => error.BrokenPipe,
        .IO => error.InputOutput,
        .AGAIN => error.NativeWouldBlock,
        else => error.NativeSendfileFailed,
    };
}
