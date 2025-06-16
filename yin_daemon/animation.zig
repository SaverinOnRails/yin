const std = @import("std");
const lz4 = @import("shared").lz4;
const posix = std.posix;
const pixman = @import("pixman");
const Output = @import("output.zig").Output;
const allocator = @import("util.zig").allocator;
const Image = @import("image.zig").Image;
//use global allocator
pub const AnimatedImage = struct {
    frames: []u64,
    durations: []f32,
    height: u32,
    file: *std.fs.File,
    width: u32,
    current_frame: u8 = 1,
    timer_fd: posix.fd_t,
    event_index: usize = 1,
    output_name: u32 = 0,
    stride: u8,
    pub fn deinit(self: *AnimatedImage) void {
        allocator.free(self.frames);
        allocator.free(self.durations);
        self.file.close();
        allocator.destroy(self.file);
        allocator.destroy(self);
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

    pub fn get_frame(self: *AnimatedImage, index: u32) !*AnimationFrame {
        const pos = self.frames[@intCast(index)];
        try self.file.seekTo(pos);
        //read duration
        const duration_length = try self.file.reader().readInt(u32, .little);
        const duration_buffer = try allocator.alloc(u8, duration_length);
        defer allocator.free(duration_buffer);
        _ = try self.file.readAll(duration_buffer);
        const duration: f32 = std.mem.bytesToValue(f32, duration_buffer);
        const original_pixel_len = try self.file.reader().readInt(u32, .little);
        const compressed_pixel_len = try self.file.reader().readInt(u32, .little);
        const compressed_buffer = try allocator.alloc(u8, compressed_pixel_len);
        defer allocator.free(compressed_buffer);
        _ = try self.file.reader().readAll(compressed_buffer);
        const decompressed_buffer = try allocator.alloc(u8, original_pixel_len * @sizeOf(u32));
        defer allocator.free(decompressed_buffer);
        const decompressed_size = lz4.LZ4_decompress_safe(
            @ptrCast(@alignCast(compressed_buffer.ptr)),
            @ptrCast(@alignCast(decompressed_buffer.ptr)),
            @intCast(compressed_buffer.len),
            @intCast(decompressed_buffer.len),
        );
        const decompressed_data_slice = decompressed_buffer[0..@intCast(decompressed_size)];
        const decompressed_data = std.mem.bytesAsSlice(u32, decompressed_data_slice);

        var pixel_data = std.ArrayList(u32).init(allocator);
        _ = try pixel_data.resize(decompressed_data.len);
        @memcpy(pixel_data.items, decompressed_data);
        const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(self.width), @intCast(self.height), @as([*]u32, @ptrCast(@alignCast(pixel_data.items.ptr))), @intCast(self.stride * self.width));
        const src = try allocator.create(Image);
        src.* = .{ .pixel_data = pixel_data, .src = src_img.? };
        const animatedframe = try allocator.create(AnimationFrame);
        animatedframe.* = .{ .image = src, .duration = duration };
        return animatedframe;
    }
};
pub const AnimationFrame = struct {
    image: ?*Image = null, //this will get released after a render, so we cannot release it here to prevent double free
    duration: f32,
    pub fn deinit(self: *AnimationFrame) void {
        allocator.destroy(self);
    }
};
