const std = @import("std");
pub const allocator = std.heap.page_allocator;

pub fn loginfo(comptime format: []const u8, args: anytype) void {
    std.log.info(format, args);
}
