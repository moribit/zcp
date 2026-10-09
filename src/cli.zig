const std = @import("std");
pub const Options = struct {
    command: enum { send, receive } = .send,
    help: bool = false,
    endpoint: []const u8 = "",
    path: []const u8 = "",
    output: []const u8 = ".",
    bind: []const u8 = "0.0.0.0",
    port: u16 = 9000,
    buffer_size: u32 = 1024 * 1024,
    buffers: u16 = 1,
    connections: u16 = 1,
    integrity: bool = true,
    resume_enabled: bool = false,
    once: bool = false,
    io_backend: enum { generic, zero_copy } = .generic,
};
pub const usage =
    \\zcp send [options] IP:PORT FILE
    \\zcp receive [--port 9000] [--bind IP] [--output DIR] [--once]
    \\Options: --buffer-size 64K|256K|1M|4M|16M --buffers 1..64
    \\         --connections 1..8 --resume --integrity off|on --io generic|zero-copy
    \\Sizes use binary K/M/G. No compression or encryption. Trusted LAN only.
    \\
;
pub fn size(text: []const u8) !u32 {
    if (text.len == 0) return error.InvalidBufferSize;
    const last = text[text.len - 1];
    const multiplier: u64 = switch (last) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (multiplier == 1) text else text[0 .. text.len - 1];
    const value = try std.fmt.parseInt(u64, digits, 10);
    if (value == 0 or value > (16 * 1024 * 1024) / multiplier) return error.InvalidBufferSize;
    return @intCast(value * multiplier);
}
pub fn parse(args: []const []const u8) !Options {
    var o: Options = .{};
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        o.help = true;
        return o;
    }
    if (std.mem.eql(u8, args[1], "send")) o.command = .send else if (std.mem.eql(u8, args[1], "receive")) o.command = .receive else return error.UnknownCommand;
    var i: usize = 2;
    var positional: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            o.help = true;
            return o;
        }
        if (std.mem.eql(u8, a, "--resume")) {
            o.resume_enabled = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--once")) {
            o.once = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            const v = args[i];
            if (std.mem.eql(u8, a, "--buffer-size")) o.buffer_size = try size(v) else if (std.mem.eql(u8, a, "--buffers")) o.buffers = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, a, "--connections")) o.connections = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, a, "--port")) o.port = try std.fmt.parseInt(u16, v, 10) else if (std.mem.eql(u8, a, "--bind")) o.bind = v else if (std.mem.eql(u8, a, "--output")) o.output = v else if (std.mem.eql(u8, a, "--integrity")) {
                if (std.mem.eql(u8, v, "on")) o.integrity = true else if (std.mem.eql(u8, v, "off")) o.integrity = false else return error.InvalidIntegrity;
            } else if (std.mem.eql(u8, a, "--io")) {
                if (std.mem.eql(u8, v, "generic")) o.io_backend = .generic else if (std.mem.eql(u8, v, "zero-copy")) o.io_backend = .zero_copy else return error.InvalidBackend;
            } else return error.UnknownOption;
        } else {
            if (o.command != .send or positional >= 2) return error.UnexpectedArgument;
            if (positional == 0) o.endpoint = a else o.path = a;
            positional += 1;
        }
    }
    if (o.command == .send and positional != 2) return error.MissingArguments;
    if (o.connections == 0 or o.connections > 8 or o.buffers == 0 or o.buffers > 64 or o.port == 0) return error.InvalidOption;
    if (@as(u64, o.buffer_size) * o.buffers * o.connections > 512 * 1024 * 1024) return error.MemoryLimit;
    if (o.io_backend == .zero_copy and (o.integrity or o.buffers != 1)) return error.IncompatibleZeroCopy;
    return o;
}
test "buffer sizes and bounds" {
    try std.testing.expectEqual(@as(u32, 4194304), try size("4M"));
    try std.testing.expectError(error.InvalidBufferSize, size("17M"));
    try std.testing.expectError(error.InvalidBufferSize, size("0"));
}
