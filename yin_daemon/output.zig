const wl = @import("wayland").client.wl;
const std = @import("std");
const image = @import("image.zig");
const shared = @import("shared");
const zwlr = @import("wayland").client.zwlr;
const Buffer = @import("Buffer.zig").Buffer;
pub const Output = @This();
pub const Daemon = @import("daemon.zig").Daemon;
wlOutput: *wl.Output,
wlSurface: ?*wl.Surface = null,
wayland_name: u32 = 0,
scale: i32 = 0,
height: u32 = 0,
width: u32 = 0,
daemon: *Daemon,
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
            create_layer_surface(output) catch return;
        },
        .geometry => {},
        .mode => |_m| {
            output.height = @intCast(_m.height);
            output.width = @intCast(_m.width);
        },
        .name => {},
        .description => {},
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
        .closed => {},
    }
}

pub fn render(output: *Output, render_type: shared.Message) !void {
    if (output.configured == false) {
        std.log.err("Output not configured", .{});
        return;
    }
    switch (render_type) {
        .StaticImage => |s| {
            try output.render_static_image(s.path);
        },
        .Color => |c| {
            try output.render_solid_color(c.hexcode);
        },
    }
}

fn render_static_image(output: *Output, path: []u8) !void {
    const surface = output.wlSurface orelse return;
    const src_img = try image.load_image(path) orelse return error.CouldNotLoadImage;
    defer src_img.deinit();
    const buffer = Buffer.create_static_image_buffer(output, src_img) catch {
        std.log.err("Failed to create buffer", .{});
        return;
    };
    defer buffer.destroy();
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

pub fn deinit(output: *Output) void {
    //destroy globals
    output.wlSurface.?.destroy();
    output.wlOutput.destroy();
    output.zwlrLayerSurface.?.destroy();
}
