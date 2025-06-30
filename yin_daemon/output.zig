const wl = @import("wayland").client.wl;
const std = @import("std");
const util = @import("util.zig");
const Transition = @import("transition.zig");
const image = @import("image.zig");
const shared = @import("shared");
const AnimatedImage = @import("animation.zig").AnimatedImage;
const zwlr = @import("wayland").client.zwlr;
const PoolBuffer = @import("Buffer.zig").PoolBuffer;
pub const Output = @This();
pub const Daemon = @import("daemon.zig").Daemon;
const allocator = @import("util.zig").allocator;
wlOutput: *wl.Output,
wlSurface: ?*wl.Surface = null,
wayland_name: u32 = 0,
buffer_ring: std.SinglyLinkedList(PoolBuffer) = .{}, //this is honestly pointless
scale: i32 = 0,
height: u32 = 0,
width: u32 = 0,
daemon: *Daemon,
current_mmap: ?[]align(4096) u8 = null, //reference to the data of the current surface
paused: bool = false,
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
    var it = output.daemon.animations.first;
    //remove animations for this output
    while (it) |_node| {
        const next = _node.next;
        const anim = _node.data;
        if (anim.output_name == output.wayland_name) {
            _node.data.deinit();
            //close the timerfd
            std.posix.close(_node.data.timer_fd);
            // can't remove the event from the event list because it can affect other animations, so just zero out the event
            output.daemon.pollfds.items[_node.data.event_index] = .{
                .fd = -1,
                .events = 0,
                .revents = 0,
            };
            output.daemon.animations.remove(_node);
            allocator.destroy(_node);
        }
        it = next;
    }
    switch (render_type) {
        .Image => |s| {
            try output.render_image(s.path, s.transition);
        },
        .Color => |c| {
            try output.render_solid_color(c.hexcode);
        },
        .Restore => {
            output.restore_wallpaper() catch |err| {
                std.log.err("Could not restore wallapaper {s}", .{@errorName(err)});
            };
        },
        else => {},
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
    try output.render_image(paper_path, .BottomTop);
}

fn render_image(output: *Output, path: []u8, transition: shared.Transition) !void {
    const src_img = try image.load_image(path, output) orelse return error.CouldNotLoadImage;
    switch (src_img) {
        .Static => |s| {
            try output.render_static_image(s.image, transition);
        },
        .Animated => |s| {
            const node = try allocator.create(std.SinglyLinkedList(AnimatedImage).Node);
            node.data = s.image;
            node.data.output_name = output.wayland_name;
            output.daemon.animations.prepend(node);
            // add animation fd to daemon
            try output.daemon.pollfds.append(.{
                .fd = node.data.timer_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            node.data.event_index = output.daemon.pollfds.items.len - 1;
            // schedule first frame
            try s.image.set_timer_milliseconds(node.data.timer_fd, node.data.durations[0]);
        },
    }
    output.write_image_path_to_cache(path) catch {
        std.log.err("Could not write to cache", .{});
    };
}

fn render_static_image(output: *Output, img: *image.Image, transition: shared.Transition) !void {
    defer img.deinit(); //deinit static image
    const surface = output.wlSurface orelse return;
    //force a new buffer when using transitions to avoid overwriting the memory of the current output
    const poolbuffer = PoolBuffer.get_static_image_buffer(output, img, transition != .None) catch {
        std.log.err("Failed to create buffer", .{});
        return;
    };
    if (transition != .None) {
        if (output.current_mmap) |mmap| {
            //todo: very annoying memory leak here
            try Transition.play_transition(
                mmap,
                poolbuffer.pixman_image,
                output,
                poolbuffer,
                Transition.SlideDirection.from_shared_transition(transition),
            );
            return;
        }
    }
    if (output.current_mmap) |mmap| {
        std.posix.munmap(mmap);
    }
    output.current_mmap = poolbuffer.memory_map;
    surface.attach(poolbuffer.wlBuffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.width));
    surface.setBufferScale(output.scale);
    surface.commit();
}
fn render_solid_color(output: *Output, hexcode: []u8) !void {
    const surface = output.wlSurface orelse return;
    const hex = std.fmt.parseInt(u32, hexcode, 16) catch {
        std.log.err("Invalid hex code supplied", .{});
        return;
    };
    const buffer = PoolBuffer.get_solid_color_buffer(output, hex) catch {
        std.log.err("Faield to creae buffer", .{});
        return;
    };
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

pub fn play_animation_frame(output: *Output, animated_image: *AnimatedImage) !void {
    const scale: u32 = @intCast(output.scale);
    const height = output.height * scale;
    const width = output.width * scale;
    const stride = width * 4;
    const fd = animated_image.frame_fds[animated_image.current_frame];
    const size = height * stride;
    const shmPool = try output.daemon.wlShm.?.createPool(fd, @intCast(size));
    defer shmPool.destroy();
    const wlBuffer = try shmPool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), .argb8888);
    output.current_mmap = null; //todo
    defer wlBuffer.destroy();
    // const poolbuffer = animated_image.framebuffers.items[animated_image.current_frame];
    const surface = output.wlSurface orelse return;
    // _ = poolbuffer;
    surface.attach(wlBuffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.height));
    surface.commit();
    if (animated_image.current_frame + 1 >= animated_image.framecount) {
        animated_image.current_frame = 1;
    } else {
        animated_image.current_frame += 1;
    }
    //schedule next frame
    if (output.paused == true) return;
    try animated_image.set_timer_milliseconds(animated_image.timer_fd, animated_image.durations[animated_image.current_frame]);
}
