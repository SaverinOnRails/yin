pub const Buffer = @This();
const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;

pub fn create_buffer(output: *Output) !*wl.Buffer {
    const stride = output.width * 4;
    const size = output.height * stride;
    //shm
    const fd = try posix.memfd_create("yin-background-image", 0);
    try posix.ftruncate(fd, size);
    const data = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);

    const shm_pool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shm_pool.destroy();
    const buffer = shm_pool.createBuffer(0, @intCast(output.width), @intCast(output.height), @intCast(stride), .argb8888);

    const data_slice: [*]u32 = @as([*]u32, @ptrCast(@alignCast(data.ptr)))[0..];
    for (0..output.height) |y| {
        for (0..output.width) |x| {
            if ((x + y / 8 * 8) % 16 < 8) {
                data_slice[y * output.width + x] = 0xFF666666;
            } else {
                data_slice[y * output.width + x] = 0xFFEEEEEE;
            }
        }
    }
    return buffer;
}
