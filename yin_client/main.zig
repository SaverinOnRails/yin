const std = @import("std");
const flags = @import("flags");
const crypto = @import("std").crypto;
const zigimg = @import("zigimg");
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
        // try cache_static_image(std.mem.span(image_path));
    }
    if (std.mem.orderZ(u8, args[1], "color") == .eq) {
        //clear an arbitrary color onto the display
        const hexcode = args[2];
        try send_hex_code(std.mem.span(hexcode), &stream);
    }
    if (std.mem.orderZ(u8, args[1], "restore") == .eq) {
        //restore last used image to display
        try send_restore(&stream);
    }

    std.log.info("Request sent to Daemon", .{});
}

fn send_set_static_image(path: []u8, stream: *const std.net.Stream) !void {
    //check if a cache file fot this exists
    const safe_name = try sanitizeForFilename(path);
    const home = std.posix.getenv("HOME") orelse return error.NoHomeVariable;
    var cache_file_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "yin", safe_name });
    defer allocator.free(cache_file_path);

    _ = std.fs.openFileAbsolute(cache_file_path, .{}) catch {
        //any error here likely means it could not open the file, cache then
        cache_file_path = try cache_static_image(path);
    };
    const msg: shared.Message = .{
        .StaticImage = .{ .path = cache_file_path },
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

fn send_restore(stream: *const std.net.Stream) !void {
    const msg: shared.Message = shared.Message.Restore;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
}

//cache static image, just trying random bullshit here, try to write all of the pixel data to a cache file
fn cache_static_image(path: []const u8) ![]u8 {
    std.log.info("Caching image", .{});
    var image = try zigimg.Image.fromFilePath(allocator, path);
    defer image.deinit();

    const home = std.posix.getenv("HOME") orelse return error.NoHomeVariable;
    const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "yin" });
    defer allocator.free(cache_dir);

    //try create cache dir
    std.fs.makeDirAbsolute(cache_dir) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {}, //expected, continue
            else => return err,
        }
    };
    const safe_file_name = try sanitizeForFilename(path);
    const pixel_cache_file_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, safe_file_name });
    const pixel_cache_file = try std.fs.createFileAbsolute(pixel_cache_file_path, .{});
    defer pixel_cache_file.close();
    //write pixels
    if (image.pixelFormat() != .rgba32) try image.convert(.rgba32);
    const pixel_data = try to_argb(image.pixels.rgba32);

    //write len
    try pixel_cache_file.writer().writeInt(u32, @intCast(pixel_data.items.len), .little);
    //write height
    try pixel_cache_file.writer().writeInt(u32, @intCast(image.height), .little);
    std.debug.print("stride is {d}", .{image.pixelFormat().pixelStride()});
    //write width
    try pixel_cache_file.writer().writeInt(u32, @intCast(image.width), .little);
    //write stride
    try pixel_cache_file.writer().writeInt(u8, image.pixelFormat().pixelStride(), .little);
    //write data
    try pixel_cache_file.writer().writeAll(std.mem.sliceAsBytes(pixel_data.items));
    std.log.info("Cache Complete", .{});
    return pixel_cache_file_path;
}

fn to_argb(pixels: []zigimg.color.Rgba32) !std.ArrayList(u32) {
    var arraylist = try std.ArrayList(u32).initCapacity(allocator, pixels.len);
    for (0..pixels.len) |p| {
        const a: u32 = @as(u32, @intCast(pixels[p].a));
        const r: u32 = @as(u32, @intCast(pixels[p].r));
        const g: u32 = @as(u32, @intCast(pixels[p].g));
        const b: u32 = @as(u32, @intCast(pixels[p].b));
        const new_pixel: u32 = (a << 24) | (r << 16) | (g << 8) | b;
        try arraylist.append(new_pixel);
    }
    return arraylist;
}

fn sanitizeForFilename(path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);

    for (result) |*char| {
        switch (char.*) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => char.* = '_',
            else => {},
        }
    }
    return result;
}
