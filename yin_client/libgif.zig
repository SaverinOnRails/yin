// Simple Sequential Gif Loader based on libgif.
// This is used instead of zigimg because in addition to incorrectly loading some gifs,
// zigimg is slow and afaik does not support sequential loading meaning the entire potentially large gif will need to be loaded into memory

const std = @import("std");
const gif = @import("gif");
const magick = @import("magick");
const lz4 = @import("shared").lz4;
const GIF_ERROR = gif.GIF_ERROR;
pub const allocator = std.heap.c_allocator;

var composite_buffer: ?[]u32 = null;
var canvas_width: usize = 0;
var canvas_height: usize = 0;

pub fn initCompositeBuffer(width: usize, height: usize) !void {
    canvas_width = width;
    canvas_height = height;
    composite_buffer = try allocator.alloc(u32, width * height);
    @memset(composite_buffer.?, 0x00000000); //check if background color will work here
}

pub fn load_gif(path: []const u8, file_handle: *const std.fs.File) !void {
    var error_code: c_int = undefined;
    const file = gif.DGifOpenFileName(@ptrCast(path), &error_code) orelse return error.CouldNotLoadGif;
    const framecount = number_of_frames(path);
    var RecordType: gif.GifRecordType = undefined;
    try initCompositeBuffer(@intCast(file.*.SWidth), @intCast(file.*.SHeight));
    var ExtFunction: c_int = undefined;
    var ExtData: [*c]gif.GifByteType = undefined;
    var gcb: gif.GraphicsControlBlock = undefined;
    //write number of frames
    try file_handle.writer().writeInt(u32, @intCast(framecount), .little);
    //write height
    try file_handle.writer().writeInt(u32, @intCast(canvas_height), .little);
    //write width
    try file_handle.writer().writeInt(u32, @intCast(canvas_width), .little);
    //write stride
    try file_handle.writer().writeInt(u8, 4, .little); //just realised this isnt actually stride smh

    while (RecordType != gif.TERMINATE_RECORD_TYPE) {
        _ = gif.DGifGetRecordType(file, &RecordType);
        switch (RecordType) {
            gif.IMAGE_DESC_RECORD_TYPE => {
                //handle disposal modes
                std.debug.assert(gif.DGifGetImageDesc(file) != GIF_ERROR);
                //the current image
                var IMAGE = &file.*.SavedImages[@as(usize, @intCast(file.*.ImageCount)) - 1];
                const HEIGHT: usize = @intCast(IMAGE.ImageDesc.Height);
                const WIDTH: usize = @intCast(IMAGE.ImageDesc.Width);
                const SIZE = WIDTH * HEIGHT;
                const FRAME_LEFT: usize = @intCast(IMAGE.ImageDesc.Left);
                const FRAME_TOP: usize = @intCast(IMAGE.ImageDesc.Top);
                const _rasterbits_alloc = try allocator.alloc(gif.GifByteType, SIZE);
                //free frame data after loop
                defer allocator.free(_rasterbits_alloc);
                switch (gcb.DisposalMode) {
                    0, 1 => {},
                    2 => {
                        for (0..HEIGHT) |v| {
                            for (0..WIDTH) |u| {
                                const canvas_x = FRAME_LEFT + u;
                                const canvas_y = FRAME_TOP + v;

                                if (canvas_x >= canvas_width or canvas_y >= canvas_height) continue;

                                const canvas_index = canvas_y * canvas_width + canvas_x;
                                composite_buffer.?[canvas_index] = @intCast(file.*.SBackGroundColor);
                            }
                        }
                    },
                    3 => {}, //todo, or maybe not tbh
                    else => {},
                }
                IMAGE.RasterBits = _rasterbits_alloc.ptr;
                if (IMAGE.ImageDesc.Interlace) {
                    const interlacedOffset = [_]usize{ 0, 4, 2, 1 };
                    const interlacedJumps = [_]usize{ 8, 8, 4, 2 };

                    //need to perform 4 passes
                    for (0..4) |i| {
                        var j = interlacedOffset[i];
                        const end = HEIGHT;
                        while (j < end) : (j += interlacedJumps[i]) {
                            std.debug.assert(gif.DGifGetLine(file, IMAGE.RasterBits + j * WIDTH, IMAGE.ImageDesc.Width) != GIF_ERROR);
                        }
                    }
                } else {
                    std.debug.assert(gif.DGifGetLine(file, IMAGE.RasterBits, IMAGE.ImageDesc.Height * IMAGE.ImageDesc.Width) != GIF_ERROR);
                }
                if (file.*.ExtensionBlocks != null) {
                    IMAGE.ExtensionBlocks = file.*.ExtensionBlocks;
                    IMAGE.ExtensionBlockCount = file.*.ExtensionBlockCount;

                    file.*.ExtensionBlocks = null;
                    file.*.ExtensionBlockCount = 0;
                }
                try iter(file, IMAGE, gcb, file_handle);
                const image_count: i32 = @intCast(file.*.ImageCount);
                const frame_count_f32: f32 = @floatFromInt(framecount);
                const image_count_f32: f32 = @floatFromInt(image_count);
                const percentage: f32 = (image_count_f32 / frame_count_f32) * 100.0;
                std.log.info("Caching gif : {d}%/100%...", .{@round(percentage * 100) / 100});
            },

            gif.EXTENSION_RECORD_TYPE => {
                std.debug.assert(gif.DGifGetExtension(file, &ExtFunction, &ExtData) != GIF_ERROR);
                if (ExtFunction == gif.GRAPHICS_EXT_FUNC_CODE) {
                    std.debug.assert(gif.DGifExtensionToGCB(ExtData[0], ExtData + 1, &gcb) != GIF_ERROR);
                }
                while (true) {
                    std.debug.assert(gif.DGifGetExtensionNext(file, &ExtData) != GIF_ERROR);
                    if (ExtData == null) break;
                }
            },

            gif.TERMINATE_RECORD_TYPE => {},
            else => {},
        }
    }
}

pub fn iter(file: [*c]gif.GifFileType, savedImage: [*c]gif.SavedImage, gcb: gif.GraphicsControlBlock, file_handle: *const std.fs.File) !void {
    const colorMap = savedImage.*.ImageDesc.ColorMap orelse file.*.SColorMap;
    const frame_width: usize = @intCast(savedImage.*.ImageDesc.Width);
    const frame_height: usize = @intCast(savedImage.*.ImageDesc.Height);
    const frame_left: usize = @intCast(savedImage.*.ImageDesc.Left);
    const frame_top: usize = @intCast(savedImage.*.ImageDesc.Top);
    const has_transparency = (gcb.TransparentColor != -1) and (gcb.TransparentColor >= 0);
    const transparent_index: u8 = if (has_transparency) @intCast(gcb.TransparentColor) else 0;
    //to argb32
    for (0..frame_height) |v| {
        for (0..frame_width) |u| {
            const canvas_x = frame_left + u;
            const canvas_y = frame_top + v;
            if (canvas_x >= canvas_width or canvas_y >= canvas_height) continue;
            const c = savedImage.*.RasterBits[v * frame_width + u];
            const canvas_index = canvas_y * canvas_width + canvas_x;
            if (has_transparency and c == transparent_index) {
                continue;
            } else {
                const rgb = colorMap.*.Colors[c];
                const r: u32 = @intCast(rgb.Red);
                const g: u32 = @intCast(rgb.Green);
                const b: u32 = @intCast(rgb.Blue);
                const argb = 0xFF << 24 | // Full alpha
                    r << 16 |
                    g << 8 |
                    b;
                composite_buffer.?[canvas_index] = argb;
            }
        }
    }
    // try magick_deband(composite_buffer.?, canvas_height, canvas_width);

    //composite buffer now contains the frame data
    //write duration
    var duration: f32 = @as(f32, @floatFromInt(gcb.DelayTime)) * 0.01;
    const float_as_bytes = std.mem.asBytes(&duration);
    try file_handle.writer().writeInt(u32, float_as_bytes.len, .little);
    try file_handle.writer().writeAll(std.mem.asBytes(&duration));
    const pixel_data = composite_buffer.?;
    const len = pixel_data.len;
    //write original length of pixel data
    try file_handle.writer().writeInt(u32, @intCast(len), .little);
    //compress this frame, i should really stop repeating this code
    const pixel_bytes = std.mem.sliceAsBytes(pixel_data);
    const max_compressed_size = lz4.LZ4_compressBound(@intCast(pixel_bytes.len));
    const compressed_buffer = try allocator.alloc(u8, @intCast(max_compressed_size));
    const compressed_size = lz4.LZ4_compress_default(
        @ptrCast(@alignCast(pixel_bytes.ptr)),
        @ptrCast(@alignCast(compressed_buffer.ptr)),
        @intCast(pixel_bytes.len),
        @intCast(max_compressed_size),
    );
    defer allocator.free(compressed_buffer);
    //write compressed length
    try file_handle.writer().writeInt(u32, @intCast(compressed_size), .little);
    //write data
    try file_handle.writer().writeAll(compressed_buffer[0..@intCast(compressed_size)]);
}

//run through an acquire number of frames without any allocations
fn number_of_frames(path: []const u8) usize {
    var error_code: c_int = undefined;
    const file = gif.DGifOpenFileName(@ptrCast(path), &error_code);
    var framecount: usize = 0;
    var RecordType: gif.GifRecordType = undefined;
    var ExtFunction: c_int = undefined;
    var ExtData: [*c]gif.GifByteType = null;
    var CodeSize: c_int = undefined;
    var CodeBlock: [*c]gif.GifByteType = null;
    while (RecordType != gif.TERMINATE_RECORD_TYPE) {
        _ = gif.DGifGetRecordType(file, &RecordType);
        switch (RecordType) {
            gif.IMAGE_DESC_RECORD_TYPE => {
                std.debug.assert(gif.DGifGetImageDesc(file) != GIF_ERROR);
                std.debug.assert(gif.DGifGetCode(file, &CodeSize, &CodeBlock) != GIF_ERROR);
                while (CodeBlock != null) {
                    std.debug.assert(gif.DGifGetCodeNext(file, &CodeBlock) != GIF_ERROR);
                }
                framecount += 1;
            },
            gif.EXTENSION_RECORD_TYPE => {
                std.debug.assert(gif.DGifGetExtension(file, &ExtFunction, &ExtData) != GIF_ERROR);
                while (true) {
                    std.debug.assert(gif.DGifGetExtensionNext(file, &ExtData) != GIF_ERROR);
                    if (ExtData == null) break;
                }
            },
            gif.TERMINATE_RECORD_TYPE => {
                break;
            },
            else => {},
        }
    }
    return framecount;
}

//depand gifs, if we plan to support mp4s later , do we really need this?
fn magick_deband(buffer: []u32, height: usize, width: usize) !void {
    magick.MagickWandGenesis();
    const wand = magick.NewMagickWand();
    const rgba_buffer = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(rgba_buffer);
    //TODO: RGBA TO ARGB TO RGBA TO ARGB again is fucking retarded.
    for (0..width * height) |i| {
        const argb: u32 = buffer[i];
        const a = (argb >> 24) & 0xFF;
        const r = (argb >> 16) & 0xFF;
        const g = (argb >> 8) & 0xFF;
        const b = (argb) & 0xFF;
        rgba_buffer[i * 4 + 0] = @truncate(@as(u8, @intCast(r)));
        rgba_buffer[i * 4 + 1] = @truncate(@as(u8, @intCast(g)));
        rgba_buffer[i * 4 + 2] = @truncate(@as(u8, @intCast(b)));
        rgba_buffer[i * 4 + 3] = @truncate(@as(u8, @intCast(a)));
    }
    const status = magick.MagickConstituteImage(
        wand,
        @intCast(width),
        @intCast(height),
        "RGBA",
        magick.CharPixel,
        @ptrCast(@alignCast(rgba_buffer.ptr)),
    );
    std.debug.assert(status != magick.MagickFalse);

    _ = magick.MagickSetImageType(wand, magick.TrueColorType); // Ensure full-color base
    _ = magick.MagickSetImageDepth(wand, 8); // 8-bit per channel

    _ = magick.MagickGaussianBlurImage(wand, 1.2, 0.6);
    _ = magick.MagickExportImagePixels(wand, 0, 0, @intCast(width), @intCast(height), "RGBA", magick.CharPixel, @ptrCast(@alignCast(rgba_buffer.ptr)));

    for (0..width * height) |i| {
        const r: u32 = @intCast(rgba_buffer[i * 4 + 0]);
        const g: u32 = @intCast(rgba_buffer[i * 4 + 1]);
        const b: u32 = @intCast(rgba_buffer[i * 4 + 2]);
        const a: u32 = @intCast(rgba_buffer[i * 4 + 3]);
        composite_buffer.?[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }
}
