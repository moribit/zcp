const std = @import("std");
pub const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    pub fn read(self: Connection, bytes: []u8) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            var slices = [_][]u8{bytes[done..]};
            const n = (try self.stream.readWithControl(self.io, &slices, &.{})).data_len;
            if (n == 0) return error.UnexpectedEof;
            done += n;
        }
    }
    pub fn write(self: Connection, bytes: []const u8) !void {
        var writer = self.stream.writer(self.io, &.{});
        try writer.interface.writeAll(bytes);
    }
    pub fn close(self: Connection) void {
        self.stream.close(self.io);
    }
};
pub fn connect(io: std.Io, endpoint: []const u8) !Connection {
    const address = try std.Io.net.IpAddress.parseLiteral(endpoint);
    return .{ .stream = try address.connect(io, .{ .mode = .stream }), .io = io };
}
