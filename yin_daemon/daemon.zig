pub const Daemon = @This();
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const shared = @import("shared");
const posix = std.posix;
const std = @import("std");
const util = @import("util.zig");
const Output = @import("output.zig").Output;

wlDisplay: *wl.Display,
wlCompositor: ?*wl.Compositor = null,
wlShm: ?*wl.Shm = null,
zwlrLayerShell: ?*zwlr.LayerShellV1 = null,
Outputs: std.SinglyLinkedList(Output) = .{},

//global allocator
const allocator = util.allocator;

//init and run event loop
pub fn init() !void {
    var daemon: Daemon = .{ .wlDisplay = wl.Display.connect(null) catch die("Could not connect to wayland compositor") };
    const registry = try daemon.wlDisplay.getRegistry();
    registry.setListener(*Daemon, registry_listener, &daemon);
    if (daemon.wlDisplay.roundtrip() != .SUCCESS) die("Roundtrip failed");

    //ipc
    std.fs.deleteFileAbsolute("/tmp/yin") catch {};
    const addr = try std.net.Address.initUnix("/tmp/yin");
    var server = try addr.listen(.{});
    const handle = server.stream.handle; //should be fd
    defer server.deinit();
    const poll_wayland = 0;
    const poll_ipc: comptime_int = 1;
    var pollfds: [2]posix.pollfd = undefined;
    pollfds[poll_wayland] = .{
        .fd = daemon.wlDisplay.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    };

    pollfds[poll_ipc] = .{
        .fd = handle,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    while (true) {
        {
            const errno = daemon.wlDisplay.flush();
            if (errno != .SUCCESS) {
                std.log.err("Failed to dispatch wayland events. Exiting.", .{});
            }
        }
        _ = posix.poll(&pollfds, -1) catch {};
        if (pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = daemon.wlDisplay.dispatch();
            if (errno != .SUCCESS) {
                std.log.err("failed to dispatch Wayland events", .{});
                break;
            }
        }
        if (pollfds[poll_ipc].revents & posix.POLL.IN != 0) {
            const conn = try server.accept();
            defer conn.stream.close();
            const message = shared.DeserializeMessage(conn.stream.reader(), allocator) catch continue;
            daemon.handle_ipc_message(message);
        }
    }
    _ = daemon.wlDisplay.flush();
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, daemon: *Daemon) void {
    daemon.registry_event(registry, event) catch die("Error in registry");
}

fn registry_event(daemon: *Daemon, registry: *wl.Registry, event: wl.Registry.Event) !void {
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

pub fn configure(daemon: *Daemon, render_type: shared.Message) void {
    //just render this on all outputs since i havent figured out per output yet
    var it = daemon.Outputs.first;
    while (it) |node| : (it = node.next) {
        var output = node.data;
        output.render(render_type) catch return;
    }
}

fn handle_ipc_message(daemon: *Daemon, message: shared.Message) void {
    switch (message) {
        .Image => |s| {
            daemon.configure(message);
            allocator.free(s.path);
        },
        .Color => |c| {
            daemon.configure(message);
            allocator.free(c.hexcode);
        },
        .Restore => {
            daemon.configure(message);
        },
    }
}
