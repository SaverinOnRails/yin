const std = @import("std");
const pixman = @import("pixman");
const zigimg = @import("zigimg");
const allocator = @import("util.zig").allocator;

const Image = @This();
src: *pixman.Image,
pixel_data: std.ArrayList(u32),

pub fn load_image() !?*Image {
    var image = try zigimg.Image.fromFilePath(allocator, "/home/noble/Pictures/wallpapers/police, video games, Grand Theft Auto V, pixel art, explosion, Grand Theft Auto, video game art, pixels, night, PC gaming | 1920x1080 Wallpaper - wallhaven.cc.jpg");
    defer image.deinit();
    if (image.pixelFormat() != .rgba32) try image.convert(.rgba32);
    const pixels = image.pixels.rgba32;
    const list = try to_argb(pixels);
    const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(image.width), @intCast(image.height), @as([*]u32, @ptrCast(@alignCast(list.items.ptr))), @intCast(image.pixelFormat().pixelStride() * image.width)) orelse return error.NoPixmanImage;
    const src = try allocator.create(Image);
    src.* = .{ .src = src_img, .pixel_data = list };
    return src;
}

pub fn deinit(image: *Image) void {
    allocator.destroy(image);
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
