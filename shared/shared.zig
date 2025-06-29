pub const std = @import("std");
pub const lz4 = @import("lz4");
const MessageTags = enum(u8) {
    Image,
    Color,
    Restore,
    Pause,
    Play,
    MonitorSize,
};

pub const Message = union(MessageTags) {
    Image: struct { path: []u8, transition: Transition, output: ?[]u8 },
    Color: struct { hexcode: []u8 },
    Restore,
    Pause,
    Play,
    MonitorSize,
};

pub fn SerializeMessage(message: Message, writer: std.ArrayList(u8).Writer) !void {
    //write tag
    try writer.writeInt(u8, @intFromEnum(message), .little);

    switch (message) {
        .Image => |s| {
            //write len
            try writer.writeInt(u32, @intCast(s.path.len), .little);
            //write path
            try writer.writeAll(s.path);
            //write transition
            try writer.writeInt(u8, @intFromEnum(s.transition), .little);
            //write len of output_name
            const output_name_len = if (s.output == null) 0 else s.output.?.len;
            try writer.writeInt(u8, @intCast(output_name_len), .little);

            if (s.output) |out| {
                try writer.writeAll(out);
            }
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
        .Pause => {
            //nothing to write
        },
        .Play => {
            //nothing to write
        },
        .MonitorSize => {
            //nothing to write
        },
    }
}

pub fn DeserializeMessage(reader: std.net.Stream.Reader, allocator: std.mem.Allocator) !Message {
    //read tag
    const tag = try reader.readInt(u8, .little);
    const msg: MessageTags = @enumFromInt(tag);
    switch (msg) {
        .Image => {
            const len = try reader.readInt(u32, .little);
            var buffer = try allocator.alloc(u8, len);
            defer allocator.free(buffer);
            const bytes_read = try reader.readAll(buffer);
            const path = try allocator.dupe(u8, buffer[0..bytes_read]);
            const trans_tag = try reader.readInt(u8, .little);
            const trans: Transition = @enumFromInt(trans_tag);

            //read output name
            var output_name: ?[]u8 = null;
            const output_name_len = try reader.readInt(u8, .little);
            if (output_name_len > 0) {
                buffer = try allocator.realloc(buffer, output_name_len);
                const output_name_bytes_read = try reader.readAll(buffer);
                output_name = try allocator.dupe(u8, buffer[0..output_name_bytes_read]);
            }
            return Message{ .Image = .{
                .path = path,
                .transition = trans,
                .output = output_name,
            } };
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
        .Pause => {
            //nothing to read
            return Message.Pause;
        },
        .Play => {
            //nothing to read
            return Message.Play;
        },
        .MonitorSize => {
            //nothing to read
            return Message.MonitorSize;
        },
    }
}

pub const MonitorSize = struct {
    height: u32,
    width: u32,
};

pub const Transition = enum {
    LeftRight,
    RightLeft,
    TopBottom,
    BottomTop,
    None,

    pub fn from_string(trans: []u8) !Transition {
        if (std.mem.eql(u8, "top-bottom", trans)) return .TopBottom;
        if (std.mem.eql(u8, "bottom-top", trans)) return .BottomTop;
        if (std.mem.eql(u8, "left-right", trans)) return .LeftRight;
        if (std.mem.eql(u8, "right-left", trans)) return .RightLeft;
        if (std.mem.eql(u8, "none", trans)) return .None;
        std.log.err("Invalid input provided to transition", .{});
        return error.InvalidInput;
    }
};
