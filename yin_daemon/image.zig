const std = @import("std");
const pixman = @import("pixman");
const zigimg = @import("zigimg");
const allocator = @import("util.zig").allocator;

pub const Image = @This();
src: *pixman.Image,
pixel_data: std.ArrayList(u32),

//load pixels from cache, very fast
pub fn load_image(path: []const u8) !?*Image {
    const file = try std.fs.openFileAbsolute(path, .{});
    //determine whether it is animated or static
    const static_or_animated_len = try file.reader().readInt(u8, .little);
    var _buffer = try allocator.alloc(u8, static_or_animated_len);
    defer allocator.free(_buffer);
    const _br = try file.reader().readAll(_buffer);

    if (std.mem.order(u8, _buffer[0.._br], "animated") == .eq) {
        return load_animated_image(&file);
    } else if (std.mem.order(u8, _buffer[0.._br], "static") != .eq) {
        //unknown, possibly corrupted.
        return null;
    }
    defer file.close();
    //read len
    const pixel_data_len = try file.reader().readInt(u32, .little);
    //read height
    const height = try file.reader().readInt(u32, .little);
    //read width
    const width = try file.reader().readInt(u32, .little);
    //read stride
    const stride = try file.reader().readInt(u8, .little);
    const bytes_to_read = pixel_data_len * 4;
    const pixel_bytes = try allocator.alloc(u8, bytes_to_read);
    defer allocator.free(pixel_bytes);
    _ = try file.reader().readAll(pixel_bytes);
    var pixel_data = std.ArrayList(u32).init(allocator); //freed after buffer
    try pixel_data.resize(pixel_data_len);
    const u32_slice = std.mem.bytesAsSlice(u32, pixel_bytes);
    @memcpy(pixel_data.items, u32_slice);
    const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(width), @intCast(height), @as([*]u32, @ptrCast(@alignCast(pixel_data.items.ptr))), @intCast(stride * width)) orelse return error.NoPixmanImage;
    const src = try allocator.create(Image);
    src.* = .{ .src = src_img, .pixel_data = pixel_data };
    return src;
}

pub fn load_animated_image(file: *const std.fs.File) !?*Image {
    defer file.close();
    std.debug.print("Trying to load an animated image", .{});

    const number_of_frames = try file.reader().readInt(u32, .little);
    const height = try file.reader().readInt(u32, .little);
    const width = try file.reader().readInt(u32, .little);
    const stride = try file.reader().readInt(u8, .little);

    //Go through frames
    var frames = std.ArrayList([]align(1) u32).init(allocator); //todo: find a place to deallocate this
    //can deinit safely after the memcopy is done, would this be fast with disk caching?
    defer {
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }
    for (0..number_of_frames) |_| {
        const duration_length = try file.reader().readInt(u32, .little);
        const duration_buffer = try allocator.alloc(u8, duration_length);
        defer allocator.free(duration_buffer);
        const br = try file.readAll(duration_buffer);
        const duration: f32 = std.mem.bytesToValue(f32, duration_buffer[0..br]);
        _ = duration;
        const pixel_data_len = try file.reader().readInt(u32, .little);
        const bytes_to_read = pixel_data_len * 4;
        const pixel_buffer = try allocator.alloc(u8, bytes_to_read); //todo find a place to deallocate this
        _ = try file.reader().readAll(pixel_buffer);
        const u32_slice: []align(1) u32 = std.mem.bytesAsSlice(u32, pixel_buffer);
        try frames.append(u32_slice);
    }

    //try to create a pixman image wih the first frame
    const first_frame = frames.items[0];
    var pixel_data = std.ArrayList(u32).init(allocator);
    try pixel_data.resize(first_frame.len);
    @memcpy(pixel_data.items, first_frame);

    const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(width), @intCast(height), @as([*]u32, @ptrCast(@alignCast(pixel_data.items.ptr))), @intCast(stride * width)) orelse return error.NoPixmanImage;
    const src = try allocator.create(Image);
    src.* = .{ .src = src_img, .pixel_data = pixel_data };
    return src;
}
pub fn deinit(image: *Image) void {
    image.pixel_data.deinit(); //destroy pixel data
    allocator.destroy(image);
}

fn calculate_scale(image_dimension: c_int, output_dimension: u32, scale: u32) f64 {
    const numerator: f64 = @floatFromInt(image_dimension);
    const denominator: f64 = @floatFromInt(output_dimension * scale);

    return numerator / denominator;
}

/// Calculates (image_dimension / dimension_scale - output_dimension) / 2 / dimension_scale;
fn calculate_transform(image_dimension: c_int, output_dimension: u32, dimension_scale: f64) f64 {
    const numerator1: f64 = @floatFromInt(image_dimension);
    const denominator1: f64 = dimension_scale;
    const subtruend: f64 = @floatFromInt(output_dimension);
    const numerator2: f64 = numerator1 / denominator1 - subtruend;

    return numerator2 / 2 / dimension_scale;
}

//transform, thanks beanbag
pub fn Scale(self: *Image, width: u32, height: u32, scale: u32) void {
    var image = self.src;
    var sx: f64 = @as(f64, @floatFromInt(image.getWidth())) / @as(f64, @floatFromInt(width * scale));
    var sy: f64 = calculate_scale(image.getHeight(), height, scale);
    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;
    const tx: f64 = calculate_transform(image.getWidth(), width, sx);
    const ty: f64 = calculate_transform(image.getWidth(), height, sy);

    var t: pixman.FTransform = undefined;
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initTranslate(&t, tx, ty);
    pixman.FTransform.initScale(&t, sx, sy);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = image.setTransform(&t2);
    _ = image.setFilter(.best, &[_]pixman.Fixed{}, 0);
}
