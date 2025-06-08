const std = @import("std");
pub const allocator = std.heap.page_allocator;

pub fn loginfo(comptime format: []const u8, args: anytype) void {
    const _format = "[INFO]" ++ format;
    std.log.info(_format, args);
}
