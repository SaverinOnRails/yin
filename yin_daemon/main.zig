const std = @import("std");
const daemon = @import("daemon.zig");
pub fn main() !void {
    try daemon.init();
}
