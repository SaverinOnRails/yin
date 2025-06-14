const std = @import("std");
const zigimg = @import("zigimg");
const pixman = @import("pixman");
const image = @import("image.zig");
const allocator = @import("util.zig").allocator; //should probably not use this allocator
const posix = std.posix;
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;
pub const PoolBuffer = @This();
wlBuffer: *wl.Buffer,
height: u32,
width: u32,
busy: bool,
data: [*]u32,
pixman_image: *pixman.Image,

pub fn get_static_image_buffer(output: *Output, src_img: *image.Image) !*wl.Buffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    const suitable_buffer = PoolBuffer.next_buffer(output, scaled_width, scaled_height) orelse return error.NoSuitableBuffer;
    suitable_buffer.busy = true;
    src_img.Scale(scaled_width, scaled_height, 1);
    pixman.Image.composite32(.src, src_img.src, null, suitable_buffer.pixman_image, 0, 0, 0, 0, 0, 0, @intCast(scaled_width), @intCast(scaled_height));
    return suitable_buffer.wlBuffer;
}

pub fn get_solid_color_buffer(output: *Output, hex: u32) !*wl.Buffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    var color: pixman.Color = undefined;
    hex_to_pixman_color(hex, &color);
    const solid = pixman.Image.createSolidFill(&color);
    defer _ = solid.?.unref();

    const suitable_buffer = PoolBuffer.next_buffer(output, scaled_width, scaled_height) orelse return error.NoSuitableBuffer;
    pixman.Image.composite32(.src, solid.?, null, suitable_buffer.pixman_image, 0, 0, 0, 0, 0, 0, @intCast(scaled_width), @intCast(scaled_height));
    suitable_buffer.busy = true;
    return suitable_buffer.wlBuffer;
}

fn hex_to_pixman_color(hex: u32, color: *pixman.Color) void {
    color.red = @as(u16, @truncate((hex >> 16) & 0xFF)) * 257;
    color.green = @as(u16, @truncate((hex >> 8) & 0xFF)) * 257;
    color.blue = @as(u16, @truncate(hex & 0xFF)) * 257;
    color.alpha = 65535;
}

pub fn new_buffer(output: *Output) !?*PoolBuffer {
    const scale: u32 = @intCast(output.scale);
    const height = output.height * scale;
    const width = output.width * scale;
    const stride = width * 4;
    const fd = try posix.memfd_create("yin-shm-buffer", 0);
    defer posix.close(fd);
    const size = height * stride;
    try posix.ftruncate(fd, @intCast(height * stride));

    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();

    const wlBuffer = try shm_pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), .argb8888);
    const data_slice = @as([*]u32, @ptrCast(@alignCast(data.ptr)));
    //create pixman image
    const pixman_image = pixman.Image.createBits(.a8r8g8b8, @intCast(width), @intCast(height), data_slice, @intCast(stride));
    const poolbuffer = try allocator.create(PoolBuffer);
    poolbuffer.* = .{
        .wlBuffer = wlBuffer,
        .height = height,
        .width = width,
        .busy = false,
        .data = data_slice,
        .pixman_image = pixman_image.?,
    };
    return poolbuffer;
}

pub fn setListener(buffer: *PoolBuffer) void {
    buffer.wlBuffer.setListener(*PoolBuffer, buffer_listener, buffer);
}
fn buffer_listener(_: *wl.Buffer, event: wl.Buffer.Event, poolBuffer: *PoolBuffer) void {
    switch (event) {
        .release => {
            std.log.debug("Releasing buffer, busy was {d}", .{@intFromBool(poolBuffer.busy)});
            poolBuffer.busy = false;
        },
    }
}

pub fn next_buffer(output: *Output, width: u32, height: u32) ?*PoolBuffer {
    var it = output.buffer_ring.first;
    while (it) |node| : (it = node.next) {
        if (node.data.width == width and node.data.height == height and node.data.busy == false) {
            return &node.data;
        }
    }
    //
    std.debug.print("No buffer available", .{});
    return null;
}
pub fn deinit(poolBuffer: *PoolBuffer) void {
    poolBuffer.wlBuffer.destroy();
}
