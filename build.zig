const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vendor modules
    const hashmap_shim = b.createModule(.{
        .root_source_file = b.path("src/vendor/utils/hashmap_helper.zig"),
        .target = target,
        .optimize = optimize,
    });

    const simd_mod = b.createModule(.{
        .root_source_file = b.path("vendor/json/simd/dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });

    const json_mod = b.createModule(.{
        .root_source_file = b.path("vendor/json/json.zig"),
        .target = target,
        .optimize = optimize,
    });
    json_mod.addImport("utils.hashmap_helper", hashmap_shim);
    json_mod.addImport("json_simd", simd_mod);

    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("vendor/websocket/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "termweb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add C libraries
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/stb_image.c"),
        .flags = &.{"-O2"},
    });
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/stb_truetype.c"),
        .flags = &.{"-O2"},
    });
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/nanosvg.c"),
        .flags = &.{ "-O2", "-fno-strict-aliasing" },
    });
    exe.addIncludePath(b.path("src/vendor"));

    exe.linkLibC();

    // Add vendor imports
    exe.root_module.addImport("json", json_mod);
    exe.root_module.addImport("websocket", websocket_mod);

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run termweb");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
