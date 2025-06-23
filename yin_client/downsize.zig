// Downsize pixels to hd, ripped from ClaudeAI
const std = @import("std");
pub fn downsampleBilinear(src_pixels: []u32, src_width: u32, src_height: u32, dst_width: u32, dst_height: u32, allocator: std.mem.Allocator) ![]u32 {
    const dst_pixels = try allocator.alloc(u32, dst_width * dst_height);
    const x_ratio = @as(f32, @floatFromInt(src_width)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src_height)) / @as(f32, @floatFromInt(dst_height));

    for (0..dst_height) |y| {
        for (0..dst_width) |x| {
            const src_x = @as(f32, @floatFromInt(x)) * x_ratio;
            const src_y = @as(f32, @floatFromInt(y)) * y_ratio;

            const x1 = @as(u32, @intFromFloat(src_x));
            const y1 = @as(u32, @intFromFloat(src_y));
            const x2 = @min(x1 + 1, src_width - 1);
            const y2 = @min(y1 + 1, src_height - 1);

            const dx = src_x - @as(f32, @floatFromInt(x1));
            const dy = src_y - @as(f32, @floatFromInt(y1));

            const p1 = src_pixels[y1 * src_width + x1];
            const p2 = src_pixels[y1 * src_width + x2];
            const p3 = src_pixels[y2 * src_width + x1];
            const p4 = src_pixels[y2 * src_width + x2];

            dst_pixels[y * dst_width + x] = bilinearInterpolate(p1, p2, p3, p4, dx, dy);
        }
    }

    return dst_pixels;
}

fn bilinearInterpolate(p1: u32, p2: u32, p3: u32, p4: u32, dx: f32, dy: f32) u32 {
    // Extract ARGB components from p1 (top-left)
    const a1 = @as(u8, @intCast((p1 >> 24) & 0xFF));
    const r1 = @as(u8, @intCast((p1 >> 16) & 0xFF));
    const g1 = @as(u8, @intCast((p1 >> 8) & 0xFF));
    const b1 = @as(u8, @intCast(p1 & 0xFF));

    // Extract ARGB components from p2 (top-right)
    const a2 = @as(u8, @intCast((p2 >> 24) & 0xFF));
    const r2 = @as(u8, @intCast((p2 >> 16) & 0xFF));
    const g2 = @as(u8, @intCast((p2 >> 8) & 0xFF));
    const b2 = @as(u8, @intCast(p2 & 0xFF));

    // Extract ARGB components from p3 (bottom-left)
    const a3 = @as(u8, @intCast((p3 >> 24) & 0xFF));
    const r3 = @as(u8, @intCast((p3 >> 16) & 0xFF));
    const g3 = @as(u8, @intCast((p3 >> 8) & 0xFF));
    const b3 = @as(u8, @intCast(p3 & 0xFF));
    const a4 = @as(u8, @intCast((p4 >> 24) & 0xFF));
    const r4 = @as(u8, @intCast((p4 >> 16) & 0xFF));
    const g4 = @as(u8, @intCast((p4 >> 8) & 0xFF));
    const b4 = @as(u8, @intCast(p4 & 0xFF));

    const a = @as(u8, @intFromFloat(@as(f32, @floatFromInt(a1)) * (1 - dx) * (1 - dy) +
        @as(f32, @floatFromInt(a2)) * dx * (1 - dy) +
        @as(f32, @floatFromInt(a3)) * (1 - dx) * dy +
        @as(f32, @floatFromInt(a4)) * dx * dy));

    const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(r1)) * (1 - dx) * (1 - dy) +
        @as(f32, @floatFromInt(r2)) * dx * (1 - dy) +
        @as(f32, @floatFromInt(r3)) * (1 - dx) * dy +
        @as(f32, @floatFromInt(r4)) * dx * dy));

    const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(g1)) * (1 - dx) * (1 - dy) +
        @as(f32, @floatFromInt(g2)) * dx * (1 - dy) +
        @as(f32, @floatFromInt(g3)) * (1 - dx) * dy +
        @as(f32, @floatFromInt(g4)) * dx * dy));

    const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(b1)) * (1 - dx) * (1 - dy) +
        @as(f32, @floatFromInt(b2)) * dx * (1 - dy) +
        @as(f32, @floatFromInt(b3)) * (1 - dx) * dy +
        @as(f32, @floatFromInt(b4)) * dx * dy));

    // Pack back into ARGB format
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}
