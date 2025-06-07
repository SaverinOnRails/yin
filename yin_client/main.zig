const std = @import("std");
const flags = @import("flags");
pub fn main() !void {
    const args = std.os.argv;
    const image_path = args[1];

    _ = image_path;

    const stream = try std.net.connectUnixSocket("/tmp/yin");

    const message = "hello world";
    _ = try stream.write(message);
}
