pub const Daemon = @This();
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const std = @import("std");
const Output = @import("output.zig").Output;

wlDisplay: *wl.Display,
wlCompositor: ?*wl.Compositor = null,
wlShm: ?*wl.Shm = null,
zwlrLayerShell: ?*zwlr.LayerShellV1 = null,
Outputs: std.SinglyLinkedList(Output) = .{},

//global allocator
const allocator = std.heap.page_allocator;

pub fn init() !void {
    var daemon: Daemon = .{ .wlDisplay = wl.Display.connect(null) catch die("Could not connect to wayland compositor") };
    const registry = try daemon.wlDisplay.getRegistry();
    registry.setListener(*Daemon, registry_listener, &daemon);
    if (daemon.wlDisplay.roundtrip() != .SUCCESS) die("Roundtrip failed");

    while (daemon.wlDisplay.dispatch() == .SUCCESS) {}
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
        .global_remove => {},
    }
}

fn die(comptime format: []const u8) noreturn {
    std.log.err(format, .{});
    std.posix.exit(1);
}
