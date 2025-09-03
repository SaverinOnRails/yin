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
asyncReadFd: std.posix.fd_t = undefined,
asyncWriteFd: std.posix.fd_t = undefined,
ipcBusy: bool = false,

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
    const poll_async: comptime_int = 2;
    const async_pipe = try std.posix.pipe();
    daemon.asyncReadFd = async_pipe[0];
    daemon.asyncWriteFd = async_pipe[1];
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
    try daemon.pollfds.append(.{
        .fd = async_pipe[0],
        .events = posix.POLL.IN,
        .revents = 0,
    });
    const registry = try daemon.wlDisplay.getRegistry();
    registry.setListener(*Daemon, registryListener, &daemon);
    if (daemon.wlDisplay.roundtrip() != .SUCCESS) die("Roundtrip failed");
    var connInstance: std.net.Server.Connection = undefined;
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
            if (daemon.ipcBusy) continue; //TODO: respond appropriately
            const conn = try server.accept();
            connInstance = conn;
            const message = shared.DeserializeMessage(conn.stream.reader(), allocator) catch return;

            //handle short term request like pause, play or monitor size
            daemon.handleIpcMessage(message, &conn) catch continue;
            if (message.payload == .MonitorSize) {
                //handle long term like image
                daemon.ipcBusy = true;
                _ = std.Thread.spawn(.{}, ipcMessageAsync, .{ &daemon, conn }) catch continue;
            } else {
                conn.stream.close();
                connInstance = undefined;
            }
        }
        if (daemon.pollfds.items[poll_async].revents & posix.POLL.IN != 0) {
            var buf: [128]u8 = undefined;
            const size = std.posix.read(daemon.asyncReadFd, &buf) catch continue;
            var arraylist = std.ArrayList(u8).init(allocator);
            defer arraylist.deinit();
            arraylist.resize(size) catch continue;
            @memcpy(arraylist.items, buf[0..size]);
            var fba = std.io.fixedBufferStream(arraylist.items);
            const message = shared.DeserializeMessage(fba.reader(), allocator) catch continue;
            //this can now block the event loop as it is safe
            daemon.handleIpcMessage(message, &connInstance) catch return;
            daemon.ipcBusy = false;
            connInstance.stream.close();
            connInstance = undefined;
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

// Caching the image at the client side is what takes the most time, it's also another process entirely so is thread safe.
// We can keep the event loop running and only pause when the client is done and we actually need to load the image
// This will do for now until i can make this whole thing thread safe
fn ipcMessageAsync(daemon: *Daemon, conn: std.net.Server.Connection) void {
    const async_message = shared.DeserializeMessage(conn.stream.reader(), allocator) catch return;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    shared.SerializeMessage(async_message, buffer.writer()) catch return;
    _ = posix.write(daemon.asyncWriteFd, buffer.items) catch return;
    // conn.stream.close();
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
) !void {
    try output.render(render_type);
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
            daemon.configure(requested_output, message.payload) catch {
                //any error while applying should trigger this
                try conn.stream.writer().writeAll("Cache file missing or corrupt, Please clear cache (~/.cache/yin) and try again.");
                return;
            };
            allocator.free(s.path);
        },
        .Color => |c| {
            daemon.configure(requested_output, message.payload) catch return;
            allocator.free(c.hexcode);
        },
        .Restore => {
            daemon.configure(
                requested_output,
                message.payload,
            ) catch {
                return try conn.stream.writer().writeAll("Cache file missing or corrupt, Please clear cache (~/.cache/yin) and try again.");
            };
        },
        .Pause => {
            daemon.togglePlay(requested_output, false);
        },
        .Play => {
            daemon.togglePlay(requested_output, true);
        },
        .MonitorSize => {
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
