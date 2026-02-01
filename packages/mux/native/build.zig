const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Server executable
    const server = b.addExecutable(.{
        .name = "termweb-mux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Static link against pre-built libghostty
    // Build with: cd vendor/ghostty && zig build -Dapp-runtime=none
    server.addObjectFile(b.path("../vendor/ghostty/zig-out/lib/libghostty.a"));

    // Add ghostty header include path
    server.addIncludePath(b.path("../vendor/ghostty/include"));

    // macOS frameworks required by libghostty
    server.linkFramework("Foundation");
    server.linkFramework("CoreFoundation");
    server.linkFramework("CoreGraphics");
    server.linkFramework("CoreText");
    server.linkFramework("CoreVideo");
    server.linkFramework("QuartzCore");
    server.linkFramework("IOSurface");
    server.linkFramework("Metal");
    server.linkFramework("MetalKit");
    server.linkFramework("Carbon");
    server.linkFramework("AppKit");
    server.linkLibCpp();

    // Add termweb's websocket vendor
    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("../../../vendor/websocket/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    server.root_module.addImport("websocket", websocket_mod);

    // Add SIMD mask module from termweb
    const simd_mask_mod = b.createModule(.{
        .root_source_file = b.path("../../../src/simd/mask.zig"),
        .target = target,
        .optimize = optimize,
    });
    server.root_module.addImport("simd_mask", simd_mask_mod);

    // Add libdeflate for compression and decompression
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/deflate_compress.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/deflate_decompress.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/zlib_compress.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/zlib_decompress.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/adler32.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/crc32.c"), .flags = &.{"-O2"} });
    server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/utils.c"), .flags = &.{"-O2"} });
    if (target.result.cpu.arch == .aarch64) {
        server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/arm/cpu_features.c"), .flags = &.{"-O2"} });
    } else {
        server.addCSourceFile(.{ .file = b.path("../../../vendor/libdeflate/lib/x86/cpu_features.c"), .flags = &.{"-O2"} });
    }
    server.addIncludePath(b.path("../../../vendor/libdeflate"));

    // Add xxHash for SIMD-accelerated hashing (XXH3)
    server.addIncludePath(b.path("../../../vendor/xxhash"));
    server.addCSourceFile(.{ .file = b.path("../../../vendor/xxhash/xxhash.c"), .flags = &.{"-O2"} });

    server.linkLibC();

    b.installArtifact(server);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
