const std = @import("std");
const Buffer = @import("Buffer.zig");
const pixman = @import("pixman");
const wl = @import("wayland").client.wl;
const lz4 = @import("shared").lz4;
const Output = @import("output.zig").Output;
const zigimg = @import("zigimg");
const allocator = @import("util.zig").allocator;
const animation = @import("animation.zig");
pub const Image = @This();
src: *pixman.Image,
pixel_data: std.ArrayList(u32),

pub const ImageResponse = union(enum) {
    Static: struct {
        image: *Image,
    },
    Animated: struct {
        image: animation.AnimatedImage,
    },
};
pub fn load_image(path: []const u8, output: *Output) !?ImageResponse {
    const _file = try std.fs.openFileAbsolute(path, .{});
    var file = try allocator.create(std.fs.File);
    file.* = _file;
    //determine whether it is animated or static
    const static_or_animated_len = try file.reader().readInt(u8, .little);
    var _buffer = try allocator.alloc(u8, static_or_animated_len);
    defer allocator.free(_buffer);
    const _br = try file.reader().readAll(_buffer);

    if (std.mem.order(u8, _buffer[0.._br], "animated") == .eq) {
        return animation.load(file, output);
    } else if (std.mem.order(u8, _buffer[0.._br], "static") != .eq) {
        //unknown, possibly corrupted.
        return null;
    }
    defer allocator.destroy(file);
    defer file.close();
    //read original
    const original_len = try file.reader().readInt(u32, .little);
    //read compressed len
    const compressed_len = try file.reader().readInt(u32, .little);
    //read height
    const height = try file.reader().readInt(u16, .little);
    //read width
    const width = try file.reader().readInt(u16, .little);
    //read stride
    const stride: usize = 4;
    //read data
    const bytes_to_read = compressed_len;
    const compressed_data_buffer = try allocator.alloc(u8, bytes_to_read);
    defer allocator.free(compressed_data_buffer);
    _ = try file.reader().readAll(compressed_data_buffer);
    const original_size: u32 = original_len * @sizeOf(u32);
    const decompressed_buffer = try allocator.alloc(u8, original_size);
    defer allocator.free(decompressed_buffer);
    const decompressed_size = lz4.LZ4_decompress_safe(
        @ptrCast(@alignCast(compressed_data_buffer.ptr)),
        @ptrCast(@alignCast(decompressed_buffer.ptr)),
        @intCast(compressed_data_buffer.len),
        @intCast(decompressed_buffer.len),
    );
    const decompressed_data_slice = decompressed_buffer[0..@intCast(decompressed_size)];
    const decompressed_data = std.mem.bytesAsSlice(u32, decompressed_data_slice);
    var pixel_data = std.ArrayList(u32).init(allocator);
    try pixel_data.resize(decompressed_data.len);
    @memcpy(pixel_data.items, decompressed_data);
    const src_img = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(width),
        @intCast(height),
        @as([*]u32, @ptrCast(@alignCast(pixel_data.items.ptr))),
        @intCast(stride * width),
    ) orelse return error.NoPixmanImage;
    const src = try allocator.create(Image);
    src.* = .{ .src = src_img, .pixel_data = pixel_data };
    return ImageResponse{ .Static = .{ .image = src } };
}

pub fn deinit(image: *Image) void {
    image.pixel_data.deinit(); //destroy pixel data
    _ = image.src.unref();
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

//transform, thanks beanbag, i still do not really understand what happens here
pub fn Scale(self: *Image, output_width: u32, output_height: u32, scale: u32) void {
    var image = self.src;
    var sx: f64 = @as(f64, @floatFromInt(image.getWidth())) / @as(f64, @floatFromInt(output_width * scale));
    var sy: f64 = calculate_scale(image.getHeight(), output_height, scale);
    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;
    const tx: f64 = calculate_transform(image.getWidth(), output_width, sx);
    const ty: f64 = calculate_transform(image.getWidth(), output_height, sy);

    var t: pixman.FTransform = undefined;
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initTranslate(&t, tx, ty);
    pixman.FTransform.initScale(&t, sx, sy);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = image.setTransform(&t2);
    _ = image.setFilter(.best, &[_]pixman.Fixed{}, 0);
}
