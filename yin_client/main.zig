const std = @import("std");
const flags = @import("flags");
const pixman = @import("pixman");
const shared = @import("shared");

const allocator = std.heap.page_allocator;
pub fn main() !void {
    const args = std.os.argv;
    const image_path = args[1];
    const stream = try std.net.connectUnixSocket("/tmp/yin");

    const msg: shared.Message = .{
        .StaticImage = .{ .path = std.mem.span(image_path) },
    };
    var buffer = std.ArrayList(u8).init(allocator);

    try shared.SerializeMessage(msg, buffer.writer());
    std.debug.print("{d}", .{buffer.items.len});
    _ = try stream.write(buffer.items);
    stream.close();
}
