const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // NAPI shared library for Node.js
    const napi = b.addLibrary(.{
        .name = "metrics",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metrics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    napi.linkLibC();

    // Allow undefined NAPI symbols (provided by Node.js at runtime)
    napi.linker_allow_shlib_undefined = true;

    // Install as .node file
    const napi_install = b.addInstallArtifact(napi, .{
        .dest_sub_path = "metrics.node",
    });
    b.getInstallStep().dependOn(&napi_install.step);
}
