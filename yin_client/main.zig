const std = @import("std");
const flags = @import("flags");
const crypto = @import("std").crypto;
const zigimg = @import("zigimg");
const shared = @import("shared");
const lz4 = shared.lz4;
const allocator = std.heap.c_allocator;
const Arguments = struct {
    img: ?[]u8 = null,
    color: ?[]u8 = null,
    restore: ?bool = null,
    pause: ?bool = null,
    play: ?bool = null,
};

fn parse_args() !Arguments {
    const argv = std.os.argv;
    var args: Arguments = .{};
    for (argv, 0..) |arg, i| {
        const arg_span = std.mem.span(arg);
        if (std.mem.order(u8, arg_span, "--img") == .eq) {
            if (i + 1 >= argv.len) {
                std.log.err("Image not provided to  --img flag", .{});
                return error.NoImage;
            }
            args.img = std.mem.span(argv[i + 1]);
        }
        if (std.mem.order(u8, arg_span, "--color") == .eq) {
            if (i + 1 >= argv.len) {
                std.log.err("Hex color not provided to --color flag", .{});
                return error.NoColor;
            }
            args.color = std.mem.span(argv[i + 1]);
        }
        if (std.mem.order(u8, arg_span, "--restore") == .eq) {
            args.restore = true;
        }
        if (std.mem.order(u8, arg_span, "--pause") == .eq) {
            args.pause = true;
        }
        if (std.mem.order(u8, arg_span, "--play") == .eq) {
            args.play = true;
        }
    }
    return args;
}
pub fn main() !void {
    const args = try parse_args();
    const stream = std.net.connectUnixSocket("/tmp/yin") catch {
        std.log.err("Could not connect to Yin daemon. Please ensure it is running before attempting to use IPC", .{});
        std.posix.exit(1);
    };
    if (args.img) |img| {
        try send_set_image(img, &stream);
    } else if (args.color) |color| {
        try send_hex_code(color, &stream);
    } else if (args.restore) |restore| {
        if (restore) try send_restore(&stream);
    } else if (args.pause) |_| {
        try send_toggle_play(false, &stream);
    } else if (args.play) |_| {
        try send_toggle_play(true, &stream);
    } else {
        print_help();
    }
    defer stream.close();
    std.log.info("Request sent to Daemon", .{});
}
fn print_help() void {
    const help =
        \\ Yin, An efficient wallpaper daemon for Wayland Compositors
        \\ --img:                             Pass an image or animated gif for the daemon to display
        \\ --color:                           Pass a hexcode to clear onto the display
        \\ --restore                          Restore the previous set wallpaper
        \\ --pause                            Pause an animated gif on the output
        \\ --play                             Play or resume an animated gif on the output
    ;
    std.debug.print(help, .{});
    std.posix.exit(1);
}
fn send_set_image(path: []u8, stream: *const std.net.Stream) !void {
    //check if a cache file fot this exists
    const safe_name = try sanitizeForFilename(path);
    const home = std.posix.getenv("HOME") orelse return error.NoHomeVariable;
    var cache_file_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "yin", safe_name });
    defer allocator.free(cache_file_path);

    _ = std.fs.openFileAbsolute(cache_file_path, .{}) catch {
        //any error here likely means it could not open the file, cache then
        cache_file_path = try cache_image(path);
    };
    const msg: shared.Message = .{
        .Image = .{ .path = cache_file_path },
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

fn send_toggle_play(play: bool, stream: *const std.net.Stream) !void {
    var msg: shared.Message = undefined;
    if (play == true) {
        msg = shared.Message.Play;
    } else {
        msg = shared.Message.Pause;
    }
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
}

fn cache_image(path: []const u8) ![]u8 {
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
    defer allocator.free(safe_file_name);
    const pixel_cache_file_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, safe_file_name });
    const pixel_cache_file = try std.fs.createFileAbsolute(pixel_cache_file_path, .{});

    if (image.isAnimation()) {
        try cache_animated_image(&image, &pixel_cache_file);
        return pixel_cache_file_path;
    }
    defer pixel_cache_file.close();
    if (image.pixelFormat() != .rgba32) try image.convert(.rgba32);
    const pixel_data = try to_argb(image.pixels.rgba32);

    //write static since it is not animated
    const static = "static";
    try pixel_cache_file.writer().writeInt(u8, static.len, .little);
    try pixel_cache_file.writer().writeAll(static);
    const pixel_bytes = std.mem.sliceAsBytes(pixel_data.items);
    //write original len
    try pixel_cache_file.writer().writeInt(u32, @intCast(pixel_data.items.len), .little);
    //compress
    const max_compressed_size = lz4.LZ4_compressBound(@intCast(pixel_bytes.len));
    const compressed_buffer = try allocator.alloc(u8, @intCast(max_compressed_size));
    defer allocator.free(compressed_buffer);
    const compressed_size = lz4.LZ4_compress_default(
        @ptrCast(@alignCast(pixel_bytes.ptr)),
        @ptrCast(@alignCast(compressed_buffer.ptr)),
        @intCast(pixel_bytes.len),
        @intCast(max_compressed_size),
    );
    //write compressed len
    try pixel_cache_file.writer().writeInt(u32, @intCast(compressed_size), .little);
    //write height
    try pixel_cache_file.writer().writeInt(u32, @intCast(image.height), .little);
    std.debug.print("stride is {d}", .{image.pixelFormat().pixelStride()});
    //write width
    try pixel_cache_file.writer().writeInt(u32, @intCast(image.width), .little);
    //write stride
    try pixel_cache_file.writer().writeInt(u8, image.pixelFormat().pixelStride(), .little);
    //write data
    try pixel_cache_file.writer().writeAll(compressed_buffer[0..@intCast(compressed_size)]);
    std.log.info("Cache Complete", .{});
    return pixel_cache_file_path;
}

fn cache_animated_image(image: *zigimg.Image, file: *const std.fs.File) !void {
    //write animated since it is  animated
    const animated = "animated";
    try file.writer().writeInt(u8, animated.len, .little);
    try file.writer().writeAll(animated);
    const frames = image.animation.frames.items;
    //write number of frames
    try file.writer().writeInt(u32, @intCast(frames.len), .little);
    //write height
    try file.writer().writeInt(u32, @intCast(image.height), .little);
    //write width
    try file.writer().writeInt(u32, @intCast(image.width), .little);
    //write stride
    try file.writer().writeInt(u8, image.pixelFormat().pixelStride(), .little);
    for (frames) |frame| {
        //write duration
        const float_as_bytes = std.mem.asBytes(&frame.duration);
        try file.writer().writeInt(u32, float_as_bytes.len, .little);
        try file.writer().writeAll(std.mem.asBytes(&frame.duration));
        std.debug.print("duration {d}", .{frame.duration});
        const _p = frame.pixels;
        var rgba32_pixels: zigimg.color.PixelStorage = undefined;
        if (frame.pixels != .rgba32) {
            rgba32_pixels = try zigimg.PixelFormatConverter.convert(allocator, &_p, .rgba32);
        } else {
            rgba32_pixels = frame.pixels;
        }
        const pixel_data = try to_argb(rgba32_pixels.rgba32);
        const len = pixel_data.items.len;
        //write original length of pixel data
        try file.writer().writeInt(u32, @intCast(len), .little);
        //compress this frame, i should really stop repeating this code
        const pixel_bytes = std.mem.sliceAsBytes(pixel_data.items);
        const max_compressed_size = lz4.LZ4_compressBound(@intCast(pixel_bytes.len));
        const compressed_buffer = try allocator.alloc(u8, @intCast(max_compressed_size));
        const compressed_size = lz4.LZ4_compress_default(
            @ptrCast(@alignCast(pixel_bytes.ptr)),
            @ptrCast(@alignCast(compressed_buffer.ptr)),
            @intCast(pixel_bytes.len),
            @intCast(max_compressed_size),
        );
        defer allocator.free(compressed_buffer);
        //write compressed length
        try file.writer().writeInt(u32, @intCast(compressed_size), .little);
        //write data
        try file.writer().writeAll(compressed_buffer[0..@intCast(compressed_size)]);
    }
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
    const max_filename_len = 255;

    const len = @min(path.len, max_filename_len);
    const result = try allocator.dupe(u8, path[0..len]);

    for (result) |*char| {
        switch (char.*) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => char.* = '_',
            else => {},
        }
    }

    return result;
}
