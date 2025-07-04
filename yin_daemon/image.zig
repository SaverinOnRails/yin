const std = @import("std");
const Buffer = @import("Buffer.zig");
const pixman = @import("pixman");
const wl = @import("wayland").client.wl;
const lz4 = @import("shared").lz4;
const Output = @import("output.zig").Output;
const zigimg = @import("zigimg");
const allocator = @import("util.zig").allocator;
const animation = @import("animation.zig");
pub const Image = @This();
src: *pixman.Image,
pixel_data: std.ArrayList(u32),

const ImageResponse = union(enum) {
    Static: struct {
        image: *Image,
    },
    Animated: struct {
        image: animation.AnimatedImage,
    },
};
pub fn load_image(path: []const u8, output: *Output) !?ImageResponse {
    const _file = try std.fs.openFileAbsolute(path, .{});
    var file = try allocator.create(std.fs.File);
    file.* = _file;
    //determine whether it is animated or static
    const static_or_animated_len = try file.reader().readInt(u8, .little);
    var _buffer = try allocator.alloc(u8, static_or_animated_len);
    defer allocator.free(_buffer);
    const _br = try file.reader().readAll(_buffer);

    if (std.mem.order(u8, _buffer[0.._br], "animated") == .eq) {
        return load_animated_image(file, output);
    } else if (std.mem.order(u8, _buffer[0.._br], "static") != .eq) {
        //unknown, possibly corrupted.
        return null;
    }
    defer allocator.destroy(file);
    defer file.close();
    //read original
    const original_len = try file.reader().readInt(u32, .little);
    //read compressed len
    const compressed_len = try file.reader().readInt(u32, .little);
    //read height
    const height = try file.reader().readInt(u32, .little);
    //read width
    const width = try file.reader().readInt(u32, .little);
    //read stride
    const stride = try file.reader().readInt(u8, .little);
    //read data
    const bytes_to_read = compressed_len;
    const compressed_data_buffer = try allocator.alloc(u8, bytes_to_read);
    defer allocator.free(compressed_data_buffer);

    _ = try file.reader().readAll(compressed_data_buffer);
    const original_size: u32 = original_len * @sizeOf(u32);
    const decompressed_buffer = try allocator.alloc(u8, original_size);
    defer allocator.free(decompressed_buffer);
    const decompressed_size = lz4.LZ4_decompress_safe(
        @ptrCast(@alignCast(compressed_data_buffer.ptr)),
        @ptrCast(@alignCast(decompressed_buffer.ptr)),
        @intCast(compressed_data_buffer.len),
        @intCast(decompressed_buffer.len),
    );
    const decompressed_data_slice = decompressed_buffer[0..@intCast(decompressed_size)];
    const decompressed_data = std.mem.bytesAsSlice(u32, decompressed_data_slice);
    var pixel_data = std.ArrayList(u32).init(allocator);
    try pixel_data.resize(decompressed_data.len);
    @memcpy(pixel_data.items, decompressed_data);
    const src_img = pixman.Image.createBits(.a8r8g8b8, @intCast(width), @intCast(height), @as([*]u32, @ptrCast(@alignCast(pixel_data.items.ptr))), @intCast(stride * width)) orelse return error.NoPixmanImage;
    const src = try allocator.create(Image);
    src.* = .{ .src = src_img, .pixel_data = pixel_data };
    return ImageResponse{ .Static = .{ .image = src } };
}

pub fn load_animated_image(file: *std.fs.File, output: *Output) !?ImageResponse {
    const output_scale: u32 = @intCast(output.scale);
    const output_height = output.height * output_scale;
    const output_width = output.width * output_scale;
    const output_stride = output_width * 4;

    const current_pos = try file.getPos();
    const file_size = try file.getEndPos();
    const file_mapped_memory = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    // defer std.posix.munmap(file_mapped_memory);
    const actual_data = file_mapped_memory[current_pos..];
    var fbs = std.io.fixedBufferStream(actual_data);
    defer {
        file.close();
        allocator.destroy(file);
    }
    const number_of_frames = try fbs.reader().readInt(u32, .little);
    const height = try fbs.reader().readInt(u32, .little);
    const width = try fbs.reader().readInt(u32, .little);
    const stride = try fbs.reader().readInt(u8, .little);

    //Go through frames
    var durations: []f32 = try allocator.alloc(f32, number_of_frames);
    var frame_fds = try allocator.alloc(std.posix.fd_t, number_of_frames);
    var mmaps = try allocator.alloc([]align(4096) u8, number_of_frames);
    for (0..number_of_frames) |i| {
        const full_or_composite = try fbs.reader().readByte();
        if (full_or_composite == 0) {
            composite_from_delta(&fbs, durations, mmaps, frame_fds, i, output_height, output_width, output_stride, output_scale) catch {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
            continue;
        }

        const duration_length = try fbs.reader().readInt(u32, .little);
        const duration_buffer = try allocator.alloc(u8, duration_length);
        defer allocator.free(duration_buffer);
        _ = try fbs.reader().readAll(duration_buffer);
        const duration: f32 = std.mem.bytesToValue(f32, duration_buffer);
        durations[i] = duration;
        const original_pixel_len = try fbs.reader().readInt(u32, .little);
        const compressed_pixel_len = try fbs.reader().readInt(u32, .little);
        const compressed_buffer = try allocator.alloc(u8, compressed_pixel_len);
        defer allocator.free(compressed_buffer);
        _ = try fbs.reader().readAll(compressed_buffer);
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

        //only because image struct needs this, todo: fix this
        var pixel_data = std.ArrayList(u32).init(allocator);
        defer pixel_data.deinit();
        const src_img = pixman.Image.createBits(
            .a8r8g8b8,
            @intCast(width),
            @intCast(height),
            @ptrCast(@alignCast(decompressed_data.ptr)),
            @intCast(stride * width),
        );
        var src: Image = .{ .src = src_img.?, .pixel_data = pixel_data };
        //write image directly to shm
        const fd = try std.posix.memfd_create("yin-frame-buffer", 0);
        //defer std.posix.close(fd);
        const size = output_width * output_stride;
        try std.posix.ftruncate(fd, @intCast(size));
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        mmaps[i] = data;
        // defer std.posix.munmap(data);
        const target_pixman = pixman.Image.createBits(
            .a8r8g8b8,
            @intCast(output_width),
            @intCast(output_height),
            @ptrCast(@alignCast(data.ptr)),
            @intCast(output_stride),
        );
        src.Scale(
            output.width * @as(u32, @intCast(output.scale)),
            output.height * @as(u32, @intCast(output.scale)),
            1,
        );
        pixman.Image.composite32(
            .src,
            src_img.?,
            null,
            target_pixman.?,
            0,
            0,
            0,
            0,
            0,
            0,
            @intCast(output.width * @as(u32, @intCast(output.scale))),
            @intCast(output.height * @as(u32, @intCast(output.scale))),
        );
        frame_fds[i] = fd;
    }
    const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{});
    return ImageResponse{ .Animated = .{ .image = .{
        .durations = durations,
        .framecount = number_of_frames,
        .frame_fds = frame_fds,
        .timer_fd = timer_fd,
    } } };
}

fn composite_from_delta(
    fbs: *std.io.FixedBufferStream([]u8),
    durations: []f32,
    mmaps: [][]align(4096) u8,
    frame_fds: []std.posix.fd_t,
    i: usize,
    height: u32,
    width: u32,
    stride: u32,
    scale: u32,
) !void {
    _ = scale;
    const duration_length = try fbs.reader().readInt(u32, .little);
    const duration_buffer = try allocator.alloc(u8, duration_length);
    defer allocator.free(duration_buffer);
    _ = try fbs.reader().readAll(duration_buffer);
    const duration: f32 = std.mem.bytesToValue(f32, duration_buffer);
    durations[i] = duration;

    //read compressed length
    const original_len = try fbs.reader().readInt(u32, .little);
    const compressed_len = try fbs.reader().readInt(u32, .little);
    const compressed_buffer = try allocator.alloc(u8, compressed_len);
    defer allocator.free(compressed_buffer);
    _ = try fbs.reader().readAll(compressed_buffer);
    const decompressed_buffer = try allocator.alloc(u8, original_len);
    defer allocator.free(decompressed_buffer);
    const decompressed_size = lz4.LZ4_decompress_safe(
        @ptrCast(@alignCast(compressed_buffer.ptr)),
        @ptrCast(@alignCast(decompressed_buffer.ptr)),
        @intCast(compressed_buffer.len),
        @intCast(decompressed_buffer.len),
    );

    // const prev_data = @as([*]u32, @ptrCast(mmaps[i - 1].ptr))[0 .. width * height];
    const encoded: []u8 = decompressed_buffer[0..@intCast(decompressed_size)];
    //decode
    // var efba = std.io.fixedBufferStream(encoded);
    // var output_pos: usize = 0;
    const fd = try std.posix.memfd_create("yin-frame-buffer", 0);
    // defer std.posix.close(fd);
    const size = width * stride;
    try std.posix.ftruncate(fd, @intCast(size));
    var data = try std.posix.mmap(
        null,
        encoded.len,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    _ = height;
    data = @alignCast(encoded);
    mmaps[i] = data;
    // const current_data = @as([*]u32, @ptrCast(data.ptr))[0 .. width * height];
    // while (true) {
    //     if (try efba.getPos() == try efba.getEndPos()) break;
    //     const tag = try efba.reader().readByte();
    //     if (tag != 0xE0 and tag != 0xD0) return error.InvalidTag;
    //     if (tag == 0xE0) {
    //         const unchanged_count = try efba.reader().readInt(u32, .little);
    //         @memcpy(
    //             data[output_pos * @sizeOf(u32) .. (output_pos + unchanged_count) * @sizeOf(u32)],
    //             mmaps[i - 1][output_pos * @sizeOf(u32) .. (output_pos + unchanged_count) * @sizeOf(u32)],
    //         );
    //         output_pos += unchanged_count;
    //     } else if (tag == 0xD0) {
    //         const changed_len = try efba.reader().readInt(u32, .little);
    //         const bytes_to_read = changed_len * @sizeOf(u32);
    //         const read_pos = try efba.getPos();
    //         const pixel_data = std.mem.bytesAsSlice(u32, encoded[read_pos .. read_pos + bytes_to_read]);
    //         @memcpy(current_data[output_pos .. output_pos + changed_len], pixel_data);
    //         try efba.seekTo(read_pos + bytes_to_read);
    //         output_pos += changed_len;
    //     }
    // }
    std.log.info("encoded len is {d}", .{encoded.len});
    frame_fds[i] = fd;
}

pub fn deinit(image: *Image) void {
    image.pixel_data.deinit(); //destroy pixel data
    _ = image.src.unref();
    allocator.destroy(image);
}

fn calculate_scale(image_dimension: c_int, output_dimension: u32, scale: u32) f64 {
    const numerator: f64 = @floatFromInt(image_dimension);
    const denominator: f64 = @floatFromInt(output_dimension * scale);

    return numerator / denominator;
}

/// Calculates (image_dimension / dimension_scale - output_dimension) / 2 / dimension_scale;
fn calculate_transform(image_dimension: c_int, output_dimension: u32, dimension_scale: f64) f64 {
    const numerator1: f64 = @floatFromInt(image_dimension);
    const denominator1: f64 = dimension_scale;
    const subtruend: f64 = @floatFromInt(output_dimension);
    const numerator2: f64 = numerator1 / denominator1 - subtruend;

    return numerator2 / 2 / dimension_scale;
}
//transform, thanks beanbag
pub fn Scale(self: *Image, width: u32, height: u32, scale: u32) void {
    var image = self.src;
    var sx: f64 = @as(f64, @floatFromInt(image.getWidth())) / @as(f64, @floatFromInt(width * scale));
    var sy: f64 = calculate_scale(image.getHeight(), height, scale);
    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;
    const tx: f64 = calculate_transform(image.getWidth(), width, sx);
    const ty: f64 = calculate_transform(image.getWidth(), height, sy);

    var t: pixman.FTransform = undefined;
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initTranslate(&t, tx, ty);
    pixman.FTransform.initScale(&t, sx, sy);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = image.setTransform(&t2);
    _ = image.setFilter(.best, &[_]pixman.Fixed{}, 0);
}
