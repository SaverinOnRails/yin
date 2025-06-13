const std = @import("std");
const posix = std.posix;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const allocator = gpa.allocator();

pub fn loginfo(comptime format: []const u8, args: anytype) void {
    std.log.info(format, args);
}

