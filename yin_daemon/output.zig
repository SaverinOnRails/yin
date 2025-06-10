const wl = @import("wayland").client.wl;
const std = @import("std");
const util = @import("util.zig");
const image = @import("image.zig");
const shared = @import("shared");
const zwlr = @import("wayland").client.zwlr;
const Buffer = @import("Buffer.zig").Buffer;
pub const Output = @This();
pub const Daemon = @import("daemon.zig").Daemon;
const allocator = @import("util.zig").allocator;
wlOutput: *wl.Output,
wlSurface: ?*wl.Surface = null,
wayland_name: u32 = 0,
scale: i32 = 0,
height: u32 = 0,
width: u32 = 0,
daemon: *Daemon,
needs_reload: bool = false,
identifier: ?[]u8 = null,
configured: bool = false,
zwlrLayerSurface: ?*zwlr.LayerSurfaceV1 = null,
pub fn setListener(output: *Output) !void {
    output.wlOutput.setListener(*Output, output_listener, output);
}

fn output_listener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .scale => |_s| {
            output.scale = _s.factor;
        },
        .done => {
            if (output.zwlrLayerSurface) |_| return;
            create_layer_surface(output) catch return;
        },
        .geometry => {}, //for transformation maybe?
        .mode => |_m| {
            output.height = @intCast(_m.height);
            output.width = @intCast(_m.width);
        },
        .name => {},
        .description => |desc| {
            //as per sway, this might break on compositors not wlroots compatible
            const desc_span = std.mem.span(desc.description);
            const start = std.mem.indexOf(u8, desc_span, "(") orelse return; //no exist
            const end = std.mem.indexOf(u8, desc_span, ")") orelse return;
            if (start > end) return;
            const output_name = desc_span[start + 1 .. end];
            output.identifier = allocator.dupe(u8, output_name) catch return;
        },
    }
}

fn create_layer_surface(output: *Output) !void {
    const compositor = output.daemon.wlCompositor orelse return error.NoCompositor;
    const layer_shell = output.daemon.zwlrLayerShell orelse return error.NoLayerShell;
    const surface = try compositor.createSurface();
    const input_region = try compositor.createRegion();
    defer input_region.destroy();
    surface.setInputRegion(input_region);

    const layer_surface = try layer_shell.getLayerSurface(surface, output.wlOutput, .background, "wallpaper");
    layer_surface.setSize(0, 0);
    layer_surface.setAnchor(.{ .top = true, .right = true, .bottom = true, .left = true });
    layer_surface.setExclusiveZone(-1);
    layer_surface.setListener(*Output, layer_surface_listener, output);
    output.wlSurface = surface;
    output.zwlrLayerSurface = layer_surface;
    surface.commit();
}

fn layer_surface_listener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, output: *Output) void {
    switch (event) {
        .configure => |_c| {
            output.width = _c.width;
            output.height = _c.height;
            output.zwlrLayerSurface.?.ackConfigure(_c.serial);
            output.configured = true;
        },
        .closed => {
            std.debug.print("Layer surface is getting destroyed", .{});
        },
    }
}

pub fn render(output: *Output, render_type: shared.Message) !void {
    if (output.configured == false) {
        std.log.err("Output not configured", .{});
        return;
    }
    const output_name = output.identifier orelse "Not Available";
    switch (render_type) {
        .Image => |s| {
            util.loginfo("Displaying static image {s} on display {s}", .{ s.path, output_name });
            try output.render_static_image(s.path);
        },
        .Color => |c| {
            util.loginfo("Displaying solid color with hex code {s} on display {s}", .{ c.hexcode, output_name });
            try output.render_solid_color(c.hexcode);
        },
        .Restore => {
            output.restore_wallpaper() catch |err| {
                std.log.err("Could not restore wallapaper {s}", .{@errorName(err)});
            };
        },
    }
}

fn restore_wallpaper(output: *Output) !void {
    const home_dir = std.posix.getenv("HOME").?;
    const identifier = output.identifier orelse {
        std.log.err("Output does not have identifier", .{});
        return;
    };
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".cache", "yin", identifier });
    defer allocator.free(file_path);
    const wallpaper_path = try std.fs.openFileAbsolute(file_path, .{});
    defer wallpaper_path.close();
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try buffer.resize(try wallpaper_path.getEndPos());

    const bytes_read = try wallpaper_path.readAll(buffer.items);
    const paper_path = buffer.items[0..bytes_read];
    std.debug.print("located restore {s}", .{paper_path});
    try output.render_static_image(paper_path);
}

fn render_static_image(output: *Output, path: []u8) !void {
    const surface = output.wlSurface orelse return;
    const src_img = try image.load_image(path) orelse return error.CouldNotLoadImage;
    std.debug.print("Finished loading image", .{});
    defer src_img.deinit();
    const buffer = Buffer.create_static_image_buffer(output, src_img) catch {
        std.log.err("Failed to create buffer", .{});
        return;
    };
    defer buffer.destroy();
    output.write_image_path_to_cache(path) catch {
        std.log.err("Could not write to cache", .{});
    };
    surface.attach(buffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.width));
    surface.commit();
}

fn render_solid_color(output: *Output, hexcode: []u8) !void {
    const surface = output.wlSurface orelse return;
    const hex = std.fmt.parseInt(u32, hexcode, 16) catch {
        std.log.err("Invalid hex code supplied", .{});
        return;
    };
    const buffer = Buffer.create_solid_color_buffer(output, hex) catch {
        std.log.err("Faield to creae buffer", .{});
        return;
    };
    defer buffer.destroy();
    surface.attach(buffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.width));
    surface.commit();
}

fn write_image_path_to_cache(output: *Output, path: []u8) !void {
    //write the name of the current image to the cache directory for restore
    const identifier = output.identifier orelse return;
    const home_dir = std.posix.getenv("HOME") orelse {
        std.log.err("Home environmental variable not set", .{});
        return;
    };
    const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".cache", "yin" }); //dont see why this would fail
    defer allocator.free(cache_path);
    //try to create cache path
    std.fs.makeDirAbsolute(cache_path) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {}, //cool ,
            else => return err,
        }
    };
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_path, identifier });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();
    try file.writer().writeAll(path);
}

pub fn deinit(output: *Output) void {
    //destroy globals
    output.wlSurface.?.destroy();
    output.wlOutput.destroy();
    output.zwlrLayerSurface.?.destroy();
    if (output.identifier) |id| allocator.free(id);
}
