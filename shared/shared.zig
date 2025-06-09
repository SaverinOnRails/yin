pub const std = @import("std");

const MessageTags = enum(u8) { StaticImage, Color };

pub const Message = union(MessageTags) {
    StaticImage: struct { path: []u8 },
    Color: struct { hexcode: []u8 },
};

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
        .Color => |c| {
            //write size
            try writer.writeInt(u32, @intCast(c.hexcode.len), .little);
            //write hex code
            try writer.writeAll(c.hexcode);
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
            const path = buffer.items[0..bytes_read];
            return Message{ .StaticImage = .{ .path = try allocator.dupe(u8, path) } };
        },
        .Color => {
            const len = try reader.readInt(u32, .little);
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();
            try buffer.resize(len);
            const bytes_read = try reader.readAll(buffer.items);
            const hexcode = buffer.items[0..bytes_read];
            return Message{ .Color = .{ .hexcode = try allocator.dupe(u8, hexcode) } };
        },
    }
}
