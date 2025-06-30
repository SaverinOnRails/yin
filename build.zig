const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const yin_daemon = b.addExecutable(.{ .name = "yin", .target = target, .optimize = optimize, .root_source_file = b.path("yin_daemon/main.zig") });

    const yin_client = b.addExecutable(.{
        .name = "yinctl",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("yin_client/main.zig"),
    });

    const run_step = b.step("run", "Run yin");
    const run_yin_daemon = b.addRunArtifact(yin_daemon);

    const run_client_step = b.step("client", "Run the client program");
    const run_client = b.addRunArtifact(yin_client);

    const shared = b.addModule("shared", .{ .root_source_file = b.path("shared/shared.zig") });

    run_client_step.dependOn(&run_client.step);
    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const pixman = b.dependency("pixman", .{}).module("pixman");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_layer_shell_v1", 1);
    scanner.generate("wl_output", 4);
    run_step.dependOn(&run_yin_daemon.step);

    yin_daemon.root_module.addImport("wayland", wayland);
    yin_daemon.root_module.addImport("pixman", pixman);
    yin_client.root_module.addImport("pixman", pixman);
    yin_daemon.linkSystemLibrary("wayland-client");
    yin_daemon.linkSystemLibrary("pixman-1");
    yin_daemon.linkLibC();
    yin_client.linkLibC();
    const stb = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("./stub.h",
            \\#include <stb/stb_image_resize2.h>
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stb.addIncludePath(b.path("./stb"));
    const stb_root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_c = false });
    stb_root_module.addCSourceFile(.{
        .file = b.addWriteFiles().add("./stb.c",
            \\#define STB_IMAGE_RESIZE_IMPLEMENTATION
            \\#include <stb/stb_image_resize2.h>
        ),
    });
    const stb_lib = b.addLibrary(.{
        .root_module = stb_root_module,
        .name = "stb",
    });
    stb_lib.linkLibC();
    stb_lib.addIncludePath(b.path("stb"));
    yin_client.linkLibrary(stb_lib);
    const zigimg_dependency = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    if (b.args) |args| {
        run_client.addArgs(args);
    }
    yin_daemon.root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));
    yin_client.root_module.addImport("zigimg", zigimg_dependency.module("zigimg"));
    yin_daemon.root_module.addImport("shared", shared);
    yin_client.root_module.addImport("shared", shared);

    const lz4 = b.addTranslateC(.{
        .root_source_file = b.path("vendor/lz4.h"),
        .optimize = optimize,
        .target = target,
    });

    const ffmpeg = b.addTranslateC(.{
        .root_source_file = b.path("vendor/ffmpeg.h"),
        .target = target,
        .optimize = optimize,
    });
    shared.addImport("lz4", lz4.createModule());
    yin_client.root_module.addImport("ffmpeg", ffmpeg.createModule());
    yin_client.linkSystemLibrary("lz4");
    yin_client.root_module.addImport("stb", stb.createModule());
    yin_daemon.linkSystemLibrary("lz4");
    yin_client.linkSystemLibrary("MagickWand-7.Q16HDRI");
    yin_client.linkSystemLibrary("libswscale");
    yin_client.linkSystemLibrary("avformat");
    yin_client.linkSystemLibrary("avcodec");
    yin_client.linkSystemLibrary("avutil");

    b.installArtifact(yin_daemon);
    b.installArtifact(yin_client);
}
