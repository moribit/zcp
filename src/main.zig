const std = @import("std");
const cli = @import("cli.zig");
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("zcp: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try cli.parse(args);
    if (options.help) {
        std.debug.print("{s}", .{cli.usage});
        return;
    }
    switch (options.command) {
        .send => try @import("sender.zig").run(init.io, init.gpa, options),
        .receive => try @import("receiver.zig").run(init.io, init.gpa, options),
    }
}
test {
    _ = @import("protocol.zig");
    _ = @import("integrity.zig");
    _ = @import("cli.zig");
    _ = @import("transfer.zig");
}
