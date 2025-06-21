const std = @import("std");
const wl = @import("wayland").client.wl;
const lz4 = @import("shared").lz4;
const posix = std.posix;
const pixman = @import("pixman");
const Output = @import("output.zig").Output;
const allocator = @import("util.zig").allocator;
const Buffer = @import("Buffer.zig");
const Image = @import("image.zig").Image;
//use global allocator
pub const AnimatedImage = struct {
    frames: []u64,
    durations: []f32,
    framebuffers: std.ArrayList(Buffer.PoolBuffer),
    current_frame: u32 = 1,
    timer_fd: posix.fd_t,
    event_index: usize = 1,
    output_name: u32 = 0,
    pub fn deinit(self: *AnimatedImage) void {
        allocator.free(self.frames);
        allocator.free(self.durations);
        self.framebuffers.deinit();
        // allocator.destroy(self); //check why this fails
    }

    pub fn set_timer_milliseconds(_: AnimatedImage, timer_fd: posix.fd_t, duration: f32) !void {
        const delay_microseconds = @as(u64, @intFromFloat(duration * 1000.0));
        const delay_ms = delay_microseconds;
        const spec: posix.system.itimerspec = .{
            .it_value = .{ .sec = @intCast(delay_ms / 1000), .nsec = @intCast((delay_ms % 1000) * 1000000) },
            .it_interval = .{ .sec = 0, .nsec = 0 },
        };
        try posix.timerfd_settime(timer_fd, .{}, &spec, null);
    }

};
pub const AnimationFrame = struct {
    image: ?*Image = null, //this will get released after a render, so we cannot release it here to prevent double free
    duration: f32,
    pub fn deinit(self: *AnimationFrame) void {
        allocator.destroy(self);
    }
};
