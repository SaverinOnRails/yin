pub const std_options: std.Options = .{ .log_level = .info };
const std = @import("std");
const flags = @import("flags");
const stb = @import("stb");
const videoloader = @import("videoloader.zig");
const crypto = @import("std").crypto;
const zigimg = @import("zigimg");
const shared = @import("shared");
const lz4 = shared.lz4;
const allocator = @import("videoloader.zig").allocator;
const Transition = shared.Transition;
const Arguments = struct {
    img: ?[]u8 = null,
    color: ?[]u8 = null,
    restore: ?bool = null,
    pause: ?bool = null,
    play: ?bool = null,
    downsize: bool = true,
    transition: Transition = .BottomTop,
    output: ?[]u8 = null,
};

fn parseArgs() !Arguments {
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
        if (std.mem.order(u8, arg_span, "--trans") == .eq) {
            if (i + 1 >= argv.len) {
                std.log.err("No transition provided to --trans flag. Valid options are 'top-bottom' 'bottom-top' 'left-right' 'right-left' and 'none'", .{});
                return error.NoTransition;
            }
            args.transition = try Transition.from_string(std.mem.span(argv[i + 1]));
        }
        if (std.mem.order(u8, arg_span, "--output") == .eq) {
            if (i + 1 >= argv.len) {
                std.log.err("No output provided to --output flag. Provide the name the compositor has assigned your output", .{});
                return error.NoOutput;
            }
            args.output = std.mem.span(argv[i + 1]);
        }
    }
    return args;
}

pub fn main() !void {
    const args = try parseArgs();
    const stream = std.net.connectUnixSocket("/tmp/yin") catch {
        std.log.err("Could not connect to Yin daemon. Please ensure it is running before attempting to use IPC", .{});
        std.posix.exit(1);
    };
    if (args.img) |img| {
        try sendSetImage(img, &stream, args);
    } else if (args.color) |color| {
        try sendSetHexcode(color, &stream, args);
    } else if (args.restore) |restore| {
        if (restore) try sendRestore(&stream, args);
    } else if (args.pause) |_| {
        try sendTogglePlay(false, &stream, args);
    } else if (args.play) |_| {
        try sendTogglePlay(true, &stream, args);
    } else {
        printHelp();
    }
    defer stream.close();
}

fn getMonitorDimensions(
    stream: *const std.net.Stream,
    output: ?[]u8,
) !shared.MonitorSize {
    const msg: shared.Message = shared.Message{
        .payload = .MonitorSize,
        .output = output,
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);

    //read reply
    var buf: [100]u8 = undefined;
    const bytes_read = try stream.read(&buf);
    const res = buf[0..bytes_read];

    const x_pos = std.mem.indexOf(u8, res, "x") orelse return error.InvalidMonitorDimensions;
    const width_str = res[0..x_pos];
    const height_str = res[x_pos + 1 ..];
    const width = try std.fmt.parseInt(u32, width_str, 10);
    const height = try std.fmt.parseInt(u32, height_str, 10);
    return .{
        .width = width,
        .height = height,
    };
}

fn printHelp() noreturn {
    const help =
        \\ Yin, An efficient wallpaper daemon for Wayland Compositors, controlled at runtime
        \\ --img:                             Pass an image or animated gif for the daemon to display
        \\ --color:                           Pass a hexcode to clear onto the display
        \\ --restore                          Restore the previous set wallpaper
        \\ --pause                            Pause an animated gif on the output
        \\ --play                             Play or resume an animated gif on the output
        \\ --trans                            Pass a direction for the sliding transition. Valid options are 'top-bottom' 'bottom-top' 'left-right' 'right-left' or 'none' for none.
        \\--output                            Specify an output to render on. You can obtain this from your wayland compositor. Ignoring this will render on all outputs
    ;
    std.debug.print(help, .{});
    std.posix.exit(1);
}
fn sendSetImage(
    path: []u8,
    stream: *const std.net.Stream,
    args: Arguments,
) !void {
    //check if a cache file fot this exists
    const safe_name = try sanitizeForFilename(path);
    const home = std.posix.getenv("HOME") orelse return error.NoHomeVariable;
    var cache_file_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "yin", safe_name });
    defer allocator.free(cache_file_path);
    _ = std.fs.openFileAbsolute(cache_file_path, .{}) catch {
        //cache the image if we couldn't find the cache
        cache_file_path = try cacheImage(
            path,
            stream,
            args,
        );
    };
    const msg: shared.Message = .{
        .output = args.output,
        .payload = .{
            .Image = .{
                .path = cache_file_path,
                .transition = args.transition,
            },
        },
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
    std.log.info("Applying...", .{});
    try readIpcResponse(stream);
}

fn readIpcResponse(stream: *const std.net.Stream) !void {
    // wait for a reading
    var response: [1000]u8 = undefined;
    const bytes_read = stream.read(&response) catch |err| switch (err) {
        error.BrokenPipe => return, // Expected when server closes
        else => return err,
    };
    if (bytes_read != 0) {
        std.log.info("{s}", .{response[0..bytes_read]});
    }
}

fn sendSetHexcode(hexcode: []u8, stream: *const std.net.Stream, args: Arguments) !void {
    const msg: shared.Message = .{
        .output = args.output,
        .payload = .{
            .Color = .{
                .hexcode = hexcode,
            },
        },
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
    try readIpcResponse(stream);
}

fn sendRestore(stream: *const std.net.Stream, args: Arguments) !void {
    const msg: shared.Message = .{
        .output = args.output,
        .payload = .Restore,
    };
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
    try readIpcResponse(stream);
}

fn sendTogglePlay(
    play: bool,
    stream: *const std.net.Stream,
    args: Arguments,
) !void {
    var msg: shared.Message = .{
        .output = args.output,
        .payload = .Play,
    };
    if (play == true) {
        msg.payload = .Play;
    } else {
        msg.payload = .Pause;
    }
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try shared.SerializeMessage(msg, buffer.writer());
    _ = try stream.write(buffer.items);
    try readIpcResponse(stream);
}

fn cacheImage(
    path: []const u8,
    stream: *const std.net.Stream,
    args: Arguments,
) ![]u8 {
    const monitor_size = try getMonitorDimensions(stream, args.output);
    std.log.info("Requested monitor has dimensions {d}x{d}", .{ monitor_size.width, monitor_size.height });
    //create paths
    const home = std.posix.getenv("HOME") orelse return error.NoHomeVariable;
    const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "yin" });
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
    //very crude,but currently the quickest way i can determine if a file is a gif without parsing the whole thing:
    if (std.mem.endsWith(u8, path, ".gif") or
        std.mem.endsWith(u8, path, ".mp4") or
        std.mem.endsWith(u8, path, ".mkv") or
        std.mem.endsWith(u8, path, ".webm"))
    {
        try cacheAnimation(path, &pixel_cache_file, args.downsize, monitor_size);
        return pixel_cache_file_path;
    }
    std.log.info("Loading Image...", .{});
    var image = try zigimg.Image.fromFilePath(allocator, path);
    std.log.info("Caching image. Resolution : {d}x{d}", .{ image.width, image.width });
    defer image.deinit();
    defer allocator.free(cache_dir);
    defer pixel_cache_file.close();
    if (image.pixelFormat() != .rgba32) try image.convert(.rgba32);
    var pixel_data = try toArgb(image.pixels.rgba32);
    //write static since it is not animated
    const static = "static";
    var HEIGHT = image.height;
    var WIDTH = image.width;
    // const shouldResize: bool = args.downsize;
    const shouldResize = false; //skip resizing for now
    if (shouldResize) {
        //only downsize if need be
        if (image.width > monitor_size.width or image.height > monitor_size.height) {
            std.log.info("Downsizing to  {d}x{d}", .{ monitor_size.width, monitor_size.height });
            const pixel_data_u8 = std.mem.sliceAsBytes(pixel_data.items);
            const output_pixels_u8 = try allocator.alloc(u8, monitor_size.height * monitor_size.width * @sizeOf(u32));
            _ = stb.stbir_resize_uint8_srgb(
                @ptrCast(@alignCast(pixel_data_u8.ptr)),
                @intCast(image.width),
                @intCast(image.height),
                0,
                @ptrCast(@alignCast(output_pixels_u8.ptr)),
                @intCast(monitor_size.width),
                @intCast(monitor_size.height),
                0,
                4,
            );
            const output_pixels_u32 = std.mem.bytesAsSlice(u32, output_pixels_u8);
            pixel_data.clearRetainingCapacity();
            try pixel_data.resize(monitor_size.height * monitor_size.width);
            @memcpy(pixel_data.items, output_pixels_u32);
            WIDTH = monitor_size.width;
            HEIGHT = monitor_size.height;
        }
    }

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
    try pixel_cache_file.writer().writeInt(u16, @intCast(HEIGHT), .little);
    //write width
    try pixel_cache_file.writer().writeInt(u16, @intCast(WIDTH), .little);
    //write data
    try pixel_cache_file.writer().writeAll(compressed_buffer[0..@intCast(compressed_size)]);
    std.log.info("Cache Complete", .{});
    return pixel_cache_file_path;
}

fn cacheAnimation(path: []const u8, file: *const std.fs.File, downsize: bool, monitor_size: shared.MonitorSize) !void {
    //write animated since it is  animated
    const animated = "animated";
    try file.writer().writeInt(u8, animated.len, .little);
    try file.writer().writeAll(animated);
    try videoloader.load_video(path, file, downsize, monitor_size);
}
fn toArgb(pixels: []zigimg.color.Rgba32) !std.ArrayList(u32) {
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
