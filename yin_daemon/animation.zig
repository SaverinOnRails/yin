const std = @import("std");
const posix = std.posix;
const Output = @import("output.zig").Output;
//use global allocator
pub const AnimatedImage = struct {
    frames: std.ArrayList(AnimationFrame),
    height: u32,
    width: u32,
    current_frame: u8 = 1,
    output_name: u32 = 0,
    stride: u8,
    pub fn deinit(image: *AnimatedImage) void {
        for (image.frames.items) |frame| {
            frame.pixel_data.deinit();
        }
        image.frames.deinit();
    }

    pub fn set_timer_milliseconds(_: AnimatedImage, timer_fd: posix.fd_t, duration: f32) !void {
        const delay_microseconds = @as(u64, @intFromFloat(duration * 1000.0));
        const delay_ms = delay_microseconds;
        std.debug.print("Setting timer: duration={d}ms, delay_ms={d}\n", .{ duration, delay_ms });
        const spec: posix.system.itimerspec = .{
            .it_value = .{ .sec = @intCast(delay_ms / 1000), .nsec = @intCast((delay_ms % 1000) * 1000000) },
            .it_interval = .{ .sec = 0, .nsec = 0 },
        };
        try posix.timerfd_settime(timer_fd, .{}, &spec, null);
    }
};

pub const AnimationFrame = struct {
    pixel_data: std.ArrayList(u32),
    duration: f32,
};
