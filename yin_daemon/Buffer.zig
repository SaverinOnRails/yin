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
used: bool = false,
memory_map: []align(4096) u8,
pixman_image: *pixman.Image,
const MAX_BUFFERS = 2;
pub fn get_static_image_buffer(output: *Output, src_img: *image.Image, force_new: bool) !*PoolBuffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    const suitable_buffer = PoolBuffer.next_buffer(output, scaled_width, scaled_height, force_new) orelse return error.NoSuitableBuffer;
    suitable_buffer.busy = true;
    suitable_buffer.used = true;
    src_img.Scale(scaled_width, scaled_height, @intCast(output.scale));
    pixman.Image.composite32(
        .src,
        src_img.src,
        null,
        suitable_buffer.pixman_image,
        0,
        0,
        0,
        0,
        0,
        0,
        @intCast(scaled_width),
        @intCast(scaled_height),
    );
    return suitable_buffer;
}

pub fn get_solid_color_buffer(output: *Output, hex: u32) !*wl.Buffer {
    const scale: u32 = @intCast(output.scale);
    const scaled_width = output.width * scale;
    const scaled_height = output.height * scale;
    var color: pixman.Color = undefined;
    hex_to_pixman_color(hex, &color);
    const solid = pixman.Image.createSolidFill(&color);
    defer _ = solid.?.unref();
    const suitable_buffer = PoolBuffer.next_buffer(output, scaled_width, scaled_height, false) orelse return error.NoSuitableBuffer;
    suitable_buffer.busy = true;
    suitable_buffer.used = true;
    pixman.Image.composite32(.src, solid.?, null, suitable_buffer.pixman_image, 0, 0, 0, 0, 0, 0, @intCast(scaled_width), @intCast(scaled_height));
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
        .memory_map = data,
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
            poolBuffer.busy = false;
        },
    }
}

pub fn next_buffer(output: *Output, width: u32, height: u32, force_new: bool) ?*PoolBuffer {
    // if (output.buffer_ring.len() > MAX_BUFFERS) trimBuffers(output);
    if (force_new) {
        return add_buffer_to_ring(output);
    }
    var it = output.buffer_ring.first;
    while (it) |node| : (it = node.next) {
        if (node.data.width == width and node.data.height == height and node.data.busy == false) {
            return &node.data;
        }
    }
    // create a new buffer if needed
    return add_buffer_to_ring(output);
}

fn trimBuffers(output: *Output) void {
    var it = output.buffer_ring.first;
    std.log.debug("Trying to tirm buffers, len {d}", .{output.buffer_ring.len()});
    while (it) |node| {
        const next = node.next;
        if (node.data.busy == false and node.data.used == true) {
            std.log.debug("mmap len is {d}", .{node.data.memory_map.len});
            node.data.deinit();
            output.buffer_ring.remove(node);
            allocator.destroy(node);
        }
        it = next;
    }
}
pub fn deinit(poolBuffer: *PoolBuffer) void {
    std.log.debug("Destroying buffer", .{});
    poolBuffer.wlBuffer.destroy();
    _ = poolBuffer.pixman_image.unref();
    // std.posix.munmap(poolBuffer.memory_map);
    // allocator.destroy(poolBuffer);
}

pub fn add_buffer_to_ring(output: *Output) *PoolBuffer {
    const buffer = PoolBuffer.new_buffer(output) catch {
        std.log.err("Could not allocate buffer", .{});
        std.posix.exit(1);
    };
    const node = allocator.create(std.SinglyLinkedList(PoolBuffer).Node) catch {
        std.log.err("Out of memory", .{});
        std.posix.exit(1);
    };
    node.data = buffer.?.*;
    node.data.setListener();
    output.buffer_ring.prepend(node);
    return &node.data;
}
