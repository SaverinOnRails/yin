pub const Buffer = @This();
const std = @import("std");
const zigimg = @import("zigimg");
const pixman = @import("pixman");
const image = @import("image.zig");
const allocator = @import("util.zig").allocator; //should probably not use this allocator
const posix = std.posix;
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;

pub fn create_static_image_buffer(output: *Output, src_img: *image.Image) !*wl.Buffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    const stride = scaled_width * 4;
    const size = scaled_height * stride;

    // shm
    const fd = try posix.memfd_create("yin-background-image", 0);
    defer posix.close(fd);
    try posix.ftruncate(fd, size);
    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();

    const buffer = shm_pool.createBuffer(0, @intCast(scaled_width), @intCast(scaled_height), @intCast(stride), .argb8888);

    const data_slice: [*]u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)));

    const dst_img = pixman.Image.createBits(.a8r8g8b8, @intCast(scaled_width), @intCast(scaled_height), data_slice, @intCast(stride));
    defer _ = dst_img.?.unref();

    src_img.Scale(scaled_width, scaled_height, 1); 

    pixman.Image.composite32(.src, src_img.src, null, dst_img.?, 0, 0, 0, 0, 0, 0, @intCast(scaled_width), @intCast(scaled_height));

    return buffer;
}

pub fn create_solid_color_buffer(output: *Output, hex: u32) !*wl.Buffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    const stride = scaled_width * 4;
    const size = scaled_height * stride;

    const fd = try posix.memfd_create("yin-background-image", 0);
    defer posix.close(fd);
    try posix.ftruncate(fd, size);
    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);

    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();

    const buffer = shm_pool.createBuffer(0, @intCast(scaled_width), @intCast(scaled_height), @intCast(stride), .argb8888);

    const data_slice: [*]u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)));

    const dst_img = pixman.Image.createBits(.a8r8g8b8, @intCast(scaled_width), @intCast(scaled_height), data_slice, @intCast(stride));
    defer _ = dst_img.?.unref();

    var color: pixman.Color = undefined;
    hex_to_pixman_color(hex, &color);
    const solid = pixman.Image.createSolidFill(&color);
    defer _ = solid.?.unref();

    pixman.Image.composite32(.src, solid.?, null, dst_img.?, 0, 0, 0, 0, 0, 0, @intCast(scaled_width), @intCast(scaled_height));
    return buffer;
}

fn hex_to_pixman_color(hex: u32, color: *pixman.Color) void {
    color.red = @as(u16, @truncate((hex >> 16) & 0xFF)) * 257;
    color.green = @as(u16, @truncate((hex >> 8) & 0xFF)) * 257;
    color.blue = @as(u16, @truncate(hex & 0xFF)) * 257;
    color.alpha = 65535;
}
