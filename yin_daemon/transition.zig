pub const Transition = @This();
const std = @import("std");
const pixman = @import("pixman");
const wl = @import("wayland").client.wl;
const Output = @import("output.zig").Output;
const PoolBuffer = @import("Buffer.zig").PoolBuffer;
const allocator = @import("util.zig").allocator;
pub const SlideDirection = enum {
    left_right,
    right_left,
    top_bottom,
    bottom_top,
};

pub fn play_transition(
    original_memory_map: []align(4096) u8,
    new_pixman_ref: *pixman.Image,
    output: *Output,
    poolbuffer: *PoolBuffer,
    direction: SlideDirection,
) !void {
    const scale: u32 = @intCast(output.scale);
    const height = output.height * scale;
    const width = output.width * scale;
    const stride = width * 4;
    defer _ = new_pixman_ref.unref();

    const new_pixman_data_copy = try allocator.alloc(u32, height * width);
    defer allocator.free(new_pixman_data_copy);

    //create a copy of the new pixman image
    @memcpy(new_pixman_data_copy, new_pixman_ref.getData().?[0 .. height * width]);
    const new_pixman = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(width),
        @intCast(height),
        @ptrCast(@alignCast(new_pixman_data_copy)),
        @intCast(stride),
    );
    defer _ = new_pixman.?.unref();

    const initial_pixman = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(width),
        @intCast(height),
        @ptrCast(@alignCast(original_memory_map.ptr)),
        @intCast(stride),
    );
    defer _ = initial_pixman.?.unref();

    const transition_duration_ms: u64 = 500;
    const target_fps: u32 = 90;
    const frame_duration_ms: u64 = 1000 / target_fps;
    const frame_count: u32 = @intCast(transition_duration_ms / frame_duration_ms);
    for (1..frame_count + 1) |i| {
        const progress: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frame_count));
        const slide_params = calculate_slide_params(direction, progress, width, height);
        render_transition(
            initial_pixman,
            new_pixman.?,
            width,
            height,
            stride,
            slide_params,
            poolbuffer,
            output,
        );
        std.Thread.sleep(frame_duration_ms * std.time.ns_per_ms);
    }
    output.current_mmap = poolbuffer.memory_map;
}

const SlideParams = struct {
    // Initial image positioning
    initial_src_x: u32,
    initial_src_y: u32,
    initial_dst_x: u32,
    initial_dst_y: u32,
    initial_width: u32,
    initial_height: u32,

    // New image positioning
    new_src_x: u32,
    new_src_y: u32,
    new_dst_x: u32,
    new_dst_y: u32,
    new_width: u32,
    new_height: u32,
};

fn calculate_slide_params(
    direction: SlideDirection,
    progress: f32,
    width: u32,
    height: u32,
) SlideParams {
    return switch (direction) {
        .right_left => {
            const slide_offset = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * progress));
            return SlideParams{
                .initial_src_x = slide_offset,
                .initial_src_y = 0,
                .initial_dst_x = 0,
                .initial_dst_y = 0,
                .initial_width = width - slide_offset,
                .initial_height = height,
                .new_src_x = 0,
                .new_src_y = 0,
                .new_dst_x = width - slide_offset,
                .new_dst_y = 0,
                .new_width = slide_offset,
                .new_height = height,
            };
        },
        .left_right => {
            const slide_offset = @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * progress));
            return SlideParams{
                .initial_src_x = 0,
                .initial_src_y = 0,
                .initial_dst_x = slide_offset,
                .initial_dst_y = 0,
                .initial_width = width - slide_offset,
                .initial_height = height,

                .new_src_x = width - slide_offset,
                .new_src_y = 0,
                .new_dst_x = 0,
                .new_dst_y = 0,
                .new_width = slide_offset,
                .new_height = height,
            };
        },
        .bottom_top => {
            const slide_offset = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * progress));
            return SlideParams{
                .initial_src_x = 0,
                .initial_src_y = slide_offset,
                .initial_dst_x = 0,
                .initial_dst_y = 0,
                .initial_width = width,
                .initial_height = height - slide_offset,

                .new_src_x = 0,
                .new_src_y = 0,
                .new_dst_x = 0,
                .new_dst_y = height - slide_offset,
                .new_width = width,
                .new_height = slide_offset,
            };
        },
        .top_bottom => {
            const slide_offset = @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * progress));
            return SlideParams{
                .initial_src_x = 0,
                .initial_src_y = 0,
                .initial_dst_x = 0,
                .initial_dst_y = slide_offset,
                .initial_width = width,
                .initial_height = height - slide_offset,
                .new_src_x = 0,
                .new_src_y = height - slide_offset,
                .new_dst_x = 0,
                .new_dst_y = 0,
                .new_width = width,
                .new_height = slide_offset,
            };
        },
    };
}

fn render_transition(
    initial_pixman: ?*pixman.Image,
    new_pixman: *pixman.Image,
    width: u32,
    height: u32,
    stride: u32,
    slide_params: SlideParams,
    poolbuffer: *PoolBuffer,
    output: *Output,
) void {
    //empty pixman image
    const result_pixman = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(width),
        @intCast(height),
        null,
        @intCast(stride),
    );
    defer _ = result_pixman.?.unref();
    pixman.Image.composite32(
        .src,
        initial_pixman.?,
        null,
        result_pixman.?,
        @intCast(slide_params.initial_src_x),
        @intCast(slide_params.initial_src_y),
        0,
        0,
        @intCast(slide_params.initial_dst_x),
        @intCast(slide_params.initial_dst_y),
        @intCast(slide_params.initial_width),
        @intCast(slide_params.initial_height),
    );
    pixman.Image.composite32(
        .over,
        new_pixman,
        null,
        result_pixman.?,
        @intCast(slide_params.new_src_x),
        @intCast(slide_params.new_src_y),
        0,
        0,
        @intCast(slide_params.new_dst_x),
        @intCast(slide_params.new_dst_y),
        @intCast(slide_params.new_width),
        @intCast(slide_params.new_height),
    );

    //composite to buffer
    pixman.Image.composite32(
        .src,
        result_pixman.?,
        null,
        poolbuffer.pixman_image,
        0,
        0,
        0,
        0,
        0,
        0,
        @intCast(width),
        @intCast(height),
    );

    const surface = output.wlSurface orelse return;
    surface.attach(poolbuffer.wlBuffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.width));
    surface.setBufferScale(output.scale);
    surface.commit();
    _ = output.daemon.wlDisplay.flush();
}
