const std = @import("std");
pub const allocator = std.heap.page_allocator;

pub const Message = union(enum) {
    StaticImage: struct { path: []u8 },
};
