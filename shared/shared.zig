pub const std = @import("std");

const MessageTags = enum(u8) { StaticImage };
pub const Message = union(MessageTags) {
    StaticImage: StaticImage,
};
pub const StaticImage = struct { path: []u8 };

pub fn SerializeMessage(message: Message, writer: std.ArrayList(u8).Writer) !void {
    //write tag
    try writer.writeInt(u8, @intFromEnum(message), .little);

    switch (message) {
        .StaticImage => |s| {
            //write len
            try writer.writeInt(u32, @intCast(s.path.len), .little);
            //write path
            try writer.writeAll(s.path);
        },
    }
}

pub fn DeserializeMessage(reader: std.net.Stream.Reader, allocator: std.mem.Allocator) !Message {
    //read tag
    const tag = try reader.readInt(u8, .little);
    const msg: MessageTags = @enumFromInt(tag);
    switch (msg) {
        .StaticImage => {
            const len = try reader.readInt(u32, .little);
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();
            try buffer.resize(len);
            const bytes_read = try reader.readAll(buffer.items);
            std.debug.print("len was {d} and bytes read was {d}", .{ len, bytes_read });
            const path = buffer.items[0..bytes_read];
            return Message{ .StaticImage = .{ .path = try allocator.dupe(u8, path) } };
        },
    }
}
