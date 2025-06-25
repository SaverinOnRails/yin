const std = @import("std");
const ffmpeg = @import("ffmpeg");
const shrink = @import("downsize.zig");
const lz4 = @import("shared").lz4;
const allocator = std.heap.page_allocator;
pub fn load_video(path: []const u8, file: *const std.fs.File, downsize: bool) !void {
    var fmt_ctx: [*c]ffmpeg.AVFormatContext = null;
    var codec_ctx: [*c]ffmpeg.AVCodecContext = null;
    var rgb_frame: [*c]ffmpeg.AVFrame = null;
    var frame: [*c]ffmpeg.AVFrame = null;
    var packet: [*c]ffmpeg.AVPacket = null;
    //open file
    _ = ffmpeg.avformat_open_input(&fmt_ctx, @ptrCast(path), null, null);
    _ = ffmpeg.avformat_find_stream_info(fmt_ctx, null);
    var video_stream_index: usize = undefined;
    for (0..@intCast(fmt_ctx.*.nb_streams)) |i| {
        if (fmt_ctx.*.streams[i].*.codecpar.*.codec_type == ffmpeg.AVMEDIA_TYPE_VIDEO) {
            video_stream_index = i;
            std.log.info("Located video stream", .{});
            break;
        }
    }
    const _codec = ffmpeg.avcodec_find_decoder(fmt_ctx.*.streams[video_stream_index].*.codecpar.*.codec_id);
    codec_ctx = ffmpeg.avcodec_alloc_context3(_codec);
    _ = ffmpeg.avcodec_parameters_to_context(codec_ctx, fmt_ctx.*.streams[video_stream_index].*.codecpar);
    _ = ffmpeg.avcodec_open2(codec_ctx, _codec, null);
    frame = ffmpeg.av_frame_alloc();
    packet = ffmpeg.av_packet_alloc();
    rgb_frame = ffmpeg.av_frame_alloc();
    //obtain number of frames, this is so retarded holy shit
    var total_frames: u32 = 0;
    while (ffmpeg.av_read_frame(fmt_ctx, packet) >= 0) {
        if (packet.*.stream_index == @as(i32, @intCast(video_stream_index))) {
            var ret = ffmpeg.avcodec_send_packet(codec_ctx, packet);
            if (ret < 0) {
                std.log.err("Error sending packet to decoder", .{});
                break;
            }
            while (ret >= 0) {
                ret = ffmpeg.avcodec_receive_frame(codec_ctx, frame);
                if (ret == ffmpeg.AVERROR(ffmpeg.EAGAIN) or ret == ffmpeg.AVERROR_EOF) {
                    break;
                } else if (ret < 0) {
                    std.log.err("Error receiving frame from decoder", .{});
                    break;
                }
                total_frames += 1;
            }
        }
        ffmpeg.av_packet_unref(packet);
    }
    //seek back to beginning
    const stream_index = @as(c_int, @intCast(video_stream_index));
    const timestamp = 0;
    const flags = ffmpeg.AVSEEK_FLAG_BACKWARD;
    if (ffmpeg.av_seek_frame(fmt_ctx, stream_index, timestamp, flags) < 0) {
        std.log.err("Failed to seek back to beginning of stream", .{});
    } else {
        // Flush decoder state to avoid stale frames from before the seek
        ffmpeg.avcodec_flush_buffers(codec_ctx);
    }
    //actual video dimensions
    const HEIGHT = codec_ctx.*.height;
    const WIDTH = codec_ctx.*.width;
    const src_pix_fmt = codec_ctx.*.pix_fmt;
    const sws_ctx = ffmpeg.sws_getContext(
        WIDTH,
        HEIGHT,
        src_pix_fmt,
        WIDTH,
        HEIGHT,
        ffmpeg.AV_PIX_FMT_BGRA,
        ffmpeg.SWS_BILINEAR,
        null,
        null,
        null,
    );
    //dimensions with downsizing considered. Will not be used for video processing
    var height: u32 = @intCast(HEIGHT);
    var width: u32 = @intCast(WIDTH);
    std.log.info("Caching video. Resolution : {d}x{d}", .{ width, height });
    if (downsize) {
        if (height > 1080 or width > 1920) {
            std.log.info("Downsizing to full HD", .{});
            height = 1080;
            width = 1920;
        }
    }
    //write number of frames
    try file.writer().writeInt(u32, total_frames, .little);
    //write height
    try file.writer().writeInt(u32, @intCast(height), .little);
    //write width
    try file.writer().writeInt(u32, @intCast(width), .little);
    //write stride
    try file.writer().writeInt(u8, 4, .little); //this still isnt stride

    const argb_buffer_size = ffmpeg.av_image_get_buffer_size(ffmpeg.AV_PIX_FMT_ARGB, WIDTH, HEIGHT, 1);
    var frame_count: usize = 0;
    while (ffmpeg.av_read_frame(fmt_ctx, packet) >= 0) {
        if (packet.*.stream_index == video_stream_index) {
            _ = ffmpeg.avcodec_send_packet(codec_ctx, packet);
            defer ffmpeg.av_packet_unref(packet);
            while (ffmpeg.avcodec_receive_frame(codec_ctx, frame) == 0) {
                const argb_buffer = try allocator.alignedAlloc(u8, @alignOf(u32), @intCast(argb_buffer_size));
                defer allocator.free(argb_buffer);
                // Setup RGB frame
                _ = ffmpeg.av_image_fill_arrays(&rgb_frame.*.data[0], &rgb_frame.*.linesize[0], argb_buffer.ptr, ffmpeg.AV_PIX_FMT_ARGB, WIDTH, HEIGHT, 1);
                frame_count += 1;
                _ = ffmpeg.sws_scale(sws_ctx, @ptrCast(&frame.*.data[0]), &frame.*.linesize[0], 0, HEIGHT, @ptrCast(&rgb_frame.*.data[0]), &rgb_frame.*.linesize[0]);
                const pixel_count = @as(usize, @intCast(WIDTH * HEIGHT));
                const argb_pixels: []u32 = std.mem.bytesAsSlice(u32, argb_buffer[0 .. pixel_count * 4]);
                try iter(
                    argb_pixels,
                    file,
                    downsize,
                    @intCast(HEIGHT),
                    @intCast(WIDTH),
                );
                const image_count: u32 = @intCast(frame_count);
                const frame_count_f32: f32 = @floatFromInt(total_frames);
                const image_count_f32: f32 = @floatFromInt(image_count);
                const percentage: f32 = (image_count_f32 / frame_count_f32) * 100.0;
                try std.io.getStdOut().writer().print("\rCaching mp4: {d}%/100%...", .{@round(percentage * 100) / 100});
            }
        }
    }
}

fn iter(buffer: []u32, file: *const std.fs.File, downsize: bool, height: usize, width: usize) !void {
    // defer allocator.free(buffer);
    //write duration , assume 25 ms for now
    const duration: f32 = 0.025;
    const float_as_bytes = std.mem.asBytes(&duration);
    try file.writer().writeInt(u32, float_as_bytes.len, .little);
    try file.writer().writeAll(float_as_bytes);

    const _pixel_data = buffer;
    const pixel_data = if (downsize and (width > 1920 or height > 1080)) blk: {
        const resized_data = try shrink.downsampleBilinear(
            _pixel_data,
            @intCast(width),
            @intCast(height),
            1920,
            1080,
            allocator,
        );
        break :blk resized_data;
    } else _pixel_data;
    defer if (downsize and (width > 1920 or height > 1080)) {
        allocator.free(pixel_data);
    };

    const len = pixel_data.len;
    //write original length of pixel data
    try file.writer().writeInt(u32, @intCast(len), .little);
    //compress this frame, i should really stop repeating this code
    const pixel_bytes = std.mem.sliceAsBytes(pixel_data);
    const max_compressed_size = lz4.LZ4_compressBound(@intCast(pixel_bytes.len));
    const compressed_buffer = try allocator.alloc(u8, @intCast(max_compressed_size));
    const compressed_size = lz4.LZ4_compress_HC(
        @ptrCast(@alignCast(pixel_bytes.ptr)),
        @ptrCast(@alignCast(compressed_buffer.ptr)),
        @intCast(pixel_bytes.len),
        @intCast(max_compressed_size),
        10,
    );
    defer allocator.free(compressed_buffer);
    //write compressed length
    try file.writer().writeInt(u32, @intCast(compressed_size), .little);
    //write data
    try file.writer().writeAll(compressed_buffer[0..@intCast(compressed_size)]);
}
