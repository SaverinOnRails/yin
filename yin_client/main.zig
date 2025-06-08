const std = @import("std");
const flags = @import("flags");
const pixman = @import("pixman");
const shared = @import("shared");

pub fn main() !void {
    const args = std.os.argv;
    const image_path = args[1];
    const stream = try std.net.connectUnixSocket("/tmp/yin");

    const msg: shared.Message = .{
        .StaticImage = .{ .path = std.mem.span(image_path) },
    };

    switch (msg) {
        .StaticImage => |s| {
            // var buffer: [100]u8 = undefined;
            // const buf = try std.fmt.bufPrint(&buffer, "static-image: {s}", .{s.path});
            _ = try stream.write(s.path);
            stream.close();
        },
    }
}
