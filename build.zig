const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Read version from package.json at build time
    const version = getVersionFromPackageJson(b) orelse "0.0.0";

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

    // Embed version from package.json as compile-time option
    const version_option = b.addOptions();
    version_option.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", version_option);

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

    // Static link libjpeg-turbo for fast JPEG decoding
    if (target.result.os.tag == .macos) {
        // macOS: homebrew on ARM64, /usr/local on x86_64
        if (target.result.cpu.arch == .aarch64) {
            exe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/jpeg-turbo/include" });
            exe.addObjectFile(.{ .cwd_relative = "/opt/homebrew/opt/jpeg-turbo/lib/libturbojpeg.a" });
        } else {
            exe.addIncludePath(.{ .cwd_relative = "/usr/local/opt/jpeg-turbo/include" });
            exe.addObjectFile(.{ .cwd_relative = "/usr/local/opt/jpeg-turbo/lib/libturbojpeg.a" });
        }
    } else if (target.result.os.tag == .linux) {
        // Linux: static link from system path
        exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        if (target.result.cpu.arch == .aarch64) {
            exe.addObjectFile(.{ .cwd_relative = "/usr/lib/aarch64-linux-gnu/libturbojpeg.a" });
        } else {
            exe.addObjectFile(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libturbojpeg.a" });
        }
    }

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

/// Read version from package.json (single source of truth)
fn getVersionFromPackageJson(b: *std.Build) ?[]const u8 {
    const package_json = b.build_root.handle.openFile("package.json", .{}) catch return null;
    defer package_json.close();

    var buf: [4096]u8 = undefined;
    const len = package_json.readAll(&buf) catch return null;
    const content = buf[0..len];

    // Find "version": "x.y.z"
    const marker = "\"version\":";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const quote1 = std.mem.indexOfPos(u8, content, start + marker.len, "\"") orelse return null;
    const quote2 = std.mem.indexOfPos(u8, content, quote1 + 1, "\"") orelse return null;

    return b.allocator.dupe(u8, content[quote1 + 1 .. quote2]) catch null;
}
