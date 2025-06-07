pub const Buffer = @This();
const std = @import("std");
const zigimg = @import("zigimg");
const pixman = @import("pixman");
const allocator = @import("util.zig").allocator; //should probably not use this allocator
const posix = std.posix;
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;

pub fn create_buffer(output: *Output) !*wl.Buffer {
    const stride = output.width * 4;
    const size = output.height * stride;
    const scale: u32 = @intCast(output.scale);
    //shm
    const fd = try posix.memfd_create("yin-background-image", 0);
    try posix.ftruncate(fd, size);
    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();
    const buffer = shm_pool.createBuffer(0, @intCast(output.width), @intCast(output.height), @intCast(stride), .argb8888);
    const data_slice: [*]u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)));
    const src_img = try load_image() orelse return error.CouldNotLoadImage;
    defer _ = src_img.unref();

    //transform, thanks beanbag
    var sx: f64 = @as(f64, @floatFromInt(src_img.getWidth())) / @as(f64, @floatFromInt(output.width * scale));
    var sy: f64 = calculate_scale(src_img.getHeight(), output.height, scale);
    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;
    const tx: f64 = calculate_transform(src_img.getWidth(), output.width, sx);
    const ty: f64 = calculate_transform(src_img.getWidth(), output.height, sy);

    var t: pixman.FTransform = undefined;
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initTranslate(&t, tx, ty);
    pixman.FTransform.initScale(&t, sx, sy);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = src_img.setTransform(&t2);
    _ = src_img.setFilter(.best, &[_]pixman.Fixed{}, 0);

    const dst_img = pixman.Image.createBits(.a8r8g8b8, @intCast(output.width), @intCast(output.height), data_slice, @intCast(stride));
    defer _ = dst_img.?.unref();

    //transform source
    pixman.Image.composite32(.src, src_img, null, dst_img.?, 0, 0, 0, 0, 0, 0, @intCast(output.width), @intCast(output.height));
    return buffer;
}

fn load_image() !?*pixman.Image {
    var image = try zigimg.Image.fromFilePath(allocator, "/home/noble/Pictures/wallpapers/typography, flag, American flag, USA, text, beige background, digital art | 1920x1200 Wallpaper - wallhaven.cc.jpg");
    defer image.deinit();
    if (image.pixelFormat() != .rgba32) try image.convert(.rgba32);
    const pixels = image.pixels.rgba32;
    const list = try to_argb(pixels);
    const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(image.width), @intCast(image.height), @as([*]u32, @ptrCast(@alignCast(list.items.ptr))), @intCast(image.pixelFormat().pixelStride() * image.width));
    return src_img;
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
