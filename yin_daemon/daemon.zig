pub const Daemon = @This();
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const shared = @import("shared");
const posix = std.posix;
const std = @import("std");
const util = @import("util.zig");
const Output = @import("output.zig").Output;
const AnimatedImage = @import("animation.zig").AnimatedImage;
wlDisplay: *wl.Display,
wlCompositor: ?*wl.Compositor = null,
wlShm: ?*wl.Shm = null,
zwlrLayerShell: ?*zwlr.LayerShellV1 = null,
Outputs: std.SinglyLinkedList(Output) = .{},
animations: std.SinglyLinkedList(AnimatedImage) = .{},
pollfds: std.ArrayList(posix.pollfd) = undefined,

//global allocator
const allocator = util.allocator;

//init and run event loop
pub fn init() !void {
    if (instanceRunning()) return error.InstanceAlreadyRunning;
    var daemon: Daemon = .{
        .wlDisplay = wl.Display.connect(null) catch die("Could not connect to wayland compositor"),
    };

    std.fs.deleteFileAbsolute("/tmp/yin") catch {};
    const addr = try std.net.Address.initUnix("/tmp/yin");
    var server = try addr.listen(.{});
    const handle = server.stream.handle; //should be fd
    defer server.deinit();
    const poll_wayland = 0;
    const poll_ipc: comptime_int = 1;
    daemon.pollfds = std.ArrayList(posix.pollfd).init(allocator);
    defer daemon.pollfds.deinit();

    try daemon.pollfds.append(.{
        .fd = daemon.wlDisplay.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    });
    try daemon.pollfds.append(.{
        .fd = handle,
        .events = posix.POLL.IN,
        .revents = 0,
    });
    const registry = try daemon.wlDisplay.getRegistry();
    registry.setListener(*Daemon, registryListener, &daemon);
    if (daemon.wlDisplay.roundtrip() != .SUCCESS) die("Roundtrip failed");
    //ipc
    while (true) {
        {
            const errno = daemon.wlDisplay.flush();
            if (errno != .SUCCESS) {
                std.log.err("Failed to dispatch wayland events. Exiting.", .{});
            }
        }
        _ = posix.poll(daemon.pollfds.items, -1) catch {};
        if (daemon.pollfds.items[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = daemon.wlDisplay.dispatch();
            if (errno != .SUCCESS) {
                std.log.err("failed to dispatch Wayland events", .{});
                break;
            }
        }
        if (daemon.pollfds.items[poll_ipc].revents & posix.POLL.IN != 0) {
            const conn = try server.accept();
            defer conn.stream.close();
            const message = shared.DeserializeMessage(conn.stream.reader(), allocator) catch continue;
            daemon.handleIpcMessage(message, &conn) catch continue;

            //expect follow up message
            if (message.payload == .MonitorSize) {
                const follow_up = shared.DeserializeMessage(conn.stream.reader(), allocator) catch continue;
                daemon.handleIpcMessage(follow_up, &conn) catch continue;
            }
        }
        //go through animations
        var it = daemon.animations.first;
        while (it) |node| : (it = node.next) {
            if (daemon.pollfds.items[node.data.event_index].revents & posix.POLL.IN != 0) {
                var timer_data: u64 = undefined;
                _ = posix.read(node.data.timer_fd, std.mem.asBytes(&timer_data)) catch {};
                node.data.play_frame(&daemon.Outputs.first.?.data) catch {};
            }
        }
    }
    _ = daemon.wlDisplay.flush();
}
fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, daemon: *Daemon) void {
    daemon.registryEvent(registry, event) catch die("Error in registry");
}
fn registryEvent(daemon: *Daemon, registry: *wl.Registry, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |ev| {
            //wl_compositor
            if (std.mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                daemon.wlCompositor = try registry.bind(ev.name, wl.Compositor, 4);
            }
            //wh_shm
            if (std.mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                daemon.wlShm = try registry.bind(ev.name, wl.Shm, 1);
            }
            //layer shell
            if (std.mem.orderZ(u8, ev.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                daemon.zwlrLayerShell = try registry.bind(ev.name, zwlr.LayerShellV1, 1);
            }
            //outputs
            if (std.mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                const wlOutoutput = try registry.bind(ev.name, wl.Output, 4);

                const output: Output = .{
                    .wlOutput = wlOutoutput,
                    .wayland_name = ev.name,
                    .daemon = daemon,
                };
                const node = try allocator.create(std.SinglyLinkedList(Output).Node);
                node.data = output;
                try node.data.setListener();
                daemon.Outputs.prepend(node);
            }
        },
        .global_remove => |ev| {
            var it = daemon.Outputs.first;
            while (it) |node| : (it = node.next) {
                var output = node.data;
                if (output.wayland_name == ev.name) {
                    output.deinit();
                    daemon.Outputs.remove(node);
                    allocator.destroy(node);
                }
            }
        },
    }
}

fn die(comptime format: []const u8) noreturn {
    std.log.err(format, .{});
    std.posix.exit(1);
}

fn configure(
    _: *Daemon,
    output: *Output,
    render_type: shared.MessagePayload,
) void {
    output.render(render_type) catch return;
}

fn togglePlay(daemon: *Daemon, output: *Output, play: bool) void {
    //do this on all outputs for now
    output.paused = !play;
    //resume the animation, there has to be a much better way to do this
    if (!output.paused) {
        const output_name = output.wayland_name;
        var it = daemon.animations.first;
        while (it) |node| : (it = node.next) {
            if (node.data.output_name == output_name) {
                node.data.play_frame(output) catch return;
            }
        }
    }
}
fn handleIpcMessage(daemon: *Daemon, message: shared.Message, conn: *const std.net.Server.Connection) !void {
    defer if (message.output) |out| allocator.free(out);
    const requested_output = try daemon.getTargetMonitorFromName(&conn.stream, message.output);
    switch (message.payload) {
        .Image => |s| {
            daemon.configure(requested_output, message.payload);
            allocator.free(s.path);
        },
        .Color => |c| {
            daemon.configure(requested_output, message.payload);
            allocator.free(c.hexcode);
        },
        .Restore => {
            daemon.configure(
                requested_output,
                message.payload,
            );
        },
        .Pause => {
            daemon.togglePlay(requested_output, false);
        },
        .Play => {
            daemon.togglePlay(requested_output, true);
        },
        .MonitorSize => {
            //return the dimensions of the requested output, TODO: should take an output identifier
            //first output for now
            if (!requested_output.configured) return;
            var buffer: [100]u8 = undefined;
            const dim = try std.fmt.bufPrint(&buffer, "{d}x{d}", .{
                requested_output.width,
                requested_output.height,
            });
            try conn.stream.writer().writeAll(dim);
        },
    }
}

fn getTargetMonitorFromName(daemon: *Daemon, stream: *const std.net.Stream, name: ?[]u8) !*Output {
    if (name == null) {
        return &daemon.Outputs.first.?.data;
    }
    const output_name = name.?;
    var it = daemon.Outputs.first;
    while (it) |node| : (it = node.next) {
        if (std.mem.eql(u8, output_name, node.data.identifier.?)) return &node.data;
    }
    const message = std.fmt.allocPrint(allocator, "Could not find output {s}", .{output_name}) catch return error.NoOutput;
    stream.writeAll(message) catch return error.NoOutput;
    return error.NoOutput;
}

fn instanceRunning() bool {
    //check if we can ping the unix socket
    const stream = std.net.connectUnixSocket("/tmp/yin") catch return false;
    stream.close();
    return true;
}
