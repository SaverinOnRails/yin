const std = @import("std");
const flags = @import("flags");
const pixman = @import("pixman");
const shared = @import("shared");

const allocator = std.heap.page_allocator;
pub fn main() !void {
    const args = std.os.argv;
    const stream = std.net.connectUnixSocket("/tmp/yin") catch {
        std.log.err("Could not connect to Yin daemon. Please ensure it is running before attempting to use IPC", .{});
        std.posix.exit(1);
    };

    defer stream.close();
    if (std.mem.orderZ(u8, args[1], "img") == .eq) {
        const image_path = args[2];
        try send_set_static_image(std.mem.span(image_path), &stream);
    }
    if (std.mem.orderZ(u8, args[1], "color") == .eq) {
        //clear an arbitrary color onto the display
        const hexcode = args[2];
        try send_hex_code(std.mem.span(hexcode), &stream);
    }
}

fn send_set_static_image(path: []u8, stream: *const std.net.Stream) !void {
    const msg: shared.Message = .{
        .StaticImage = .{ .path = path },
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
}

fn send_hex_code(hexcode: []u8, stream: *const std.net.Stream) !void {
    const msg: shared.Message = .{
        .Color = .{ .hexcode = hexcode },
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
}
