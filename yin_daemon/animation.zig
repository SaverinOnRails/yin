const std = @import("std");
const posix = std.posix;
const pixman = @import("pixman");
const Output = @import("output.zig").Output;
const allocator = @import("util.zig").allocator;
const Image = @import("image.zig").Image;
//use global allocator
pub const AnimatedImage = struct {
    frames: std.ArrayList(AnimationFrame),
    height: u32,
    width: u32,
    current_frame: u8 = 1,
    timer_fd: posix.fd_t,
    event_index: usize = 1,
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
        const spec: posix.system.itimerspec = .{
            .it_value = .{ .sec = @intCast(delay_ms / 1000), .nsec = @intCast((delay_ms % 1000) * 1000000) },
            .it_interval = .{ .sec = 0, .nsec = 0 },
        };
        try posix.timerfd_settime(timer_fd, .{}, &spec, null);
    }
};

pub const AnimationFrame = struct {
    pixel_data: std.ArrayList(u32),
    image: ?*Image = null,
    duration: f32,
    pub fn to_image(self: *AnimationFrame, animated_image: *const AnimatedImage) !*Image {
        const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(animated_image.width), @intCast(animated_image.height), @as([*]u32, @ptrCast(@alignCast(self.pixel_data.items.ptr))), @intCast(animated_image.stride * animated_image.width));
        const src = try allocator.create(Image);

        //make a copy of pixel data because it is deallocated after the render and we dont want to deallocate the one here
        const _pixel_data = try self.pixel_data.clone();
        src.* = .{ .src = src_img.?, .pixel_data = _pixel_data };
        return src;
    }
};
