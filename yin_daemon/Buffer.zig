pub const Buffer = @This();
const std = @import("std");
const zigimg = @import("zigimg");
const pixman = @import("pixman");
const image = @import("image.zig");
const allocator = @import("util.zig").allocator; //should probably not use this allocator
const posix = std.posix;
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;

pub fn create_buffer(output: *Output , src_img: *image.Image) !*wl.Buffer {
    const stride = output.width * 4;
    const size = output.height * stride;
    const scale: u32 = @intCast(output.scale);
    //shm
    const fd = try posix.memfd_create("yin-background-image", 0);
    try posix.ftruncate(fd, size);
    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();
    const buffer = shm_pool.createBuffer(0, @intCast(output.width * scale), @intCast(output.height * scale), @intCast(stride), .argb8888);
    const data_slice: [*]u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)));
    defer _ = src_img.src.unref();
    const dst_img = pixman.Image.createBits(.a8r8g8b8, @intCast(output.width * scale), @intCast(output.height * scale), data_slice, @intCast(stride));
    defer _ = dst_img.?.unref();

    src_img.Scale(output.width, output.height, scale);
    pixman.Image.composite32(.src, src_img.src, null, dst_img.?, 0, 0, 0, 0, 0, 0, @intCast(output.width), @intCast(output.height));
    return buffer;
}
