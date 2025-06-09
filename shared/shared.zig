pub const std = @import("std");

const MessageTags = enum(u8) { StaticImage, Color, Restore };

pub const Message = union(MessageTags) {
    StaticImage: struct { path: []u8 },
    Color: struct { hexcode: []u8 },
    Restore,
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
        .Restore => {
            //nothing to write
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
            var buffer = try allocator.alloc(u8, len);
            defer allocator.free(buffer);
            const bytes_read = try reader.readAll(buffer);
            const path = buffer[0..bytes_read];
            return Message{ .StaticImage = .{ .path = try allocator.dupe(u8, path) } };
        },
        .Color => {
            const len = try reader.readInt(u32, .little);
            var buffer = try allocator.alloc(u8, len);
            defer allocator.free(buffer);
            const bytes_read = try reader.readAll(buffer);
            const hexcode = buffer[0..bytes_read];
            return Message{ .Color = .{ .hexcode = try allocator.dupe(u8, hexcode) } };
        },
        .Restore => {
            //nothing to read
            return Message.Restore;
        },
    }
}
