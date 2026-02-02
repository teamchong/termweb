const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Option to skip NAPI build (for CI where we only need CLI binary)
    const skip_napi = b.option(bool, "skip-napi", "Skip building NAPI module") orelse false;

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
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/stb_truetype.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/nanosvg.c"),
        .flags = &.{ "-O2", "-fno-strict-aliasing" },
    });
    exe.addIncludePath(b.path("src/vendor"));

    // libdeflate for zlib compression (Kitty graphics)
    exe.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/deflate_compress.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/zlib_compress.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/adler32.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    exe.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/utils.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    // CPU features: use arm/ for ARM, x86/ for x86
    if (target.result.cpu.arch == .aarch64) {
        exe.addCSourceFile(.{
            .file = b.path("vendor/libdeflate/lib/arm/cpu_features.c"),
            .flags = &.{"-O2"},
        });
    } else {
        exe.addCSourceFile(.{
            .file = b.path("vendor/libdeflate/lib/x86/cpu_features.c"),
            .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
        });
    }
    exe.addIncludePath(b.path("vendor/libdeflate"));

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
        // Linux: use -fPIC build from /usr/local (built from source)
        if (target.result.cpu.arch == .aarch64) {
            exe.addIncludePath(.{ .cwd_relative = "/usr/local/aarch64-linux-gnu/include" });
            exe.addObjectFile(.{ .cwd_relative = "/usr/local/aarch64-linux-gnu/lib/libturbojpeg.a" });
        } else {
            exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            exe.addObjectFile(.{ .cwd_relative = "/usr/local/lib/libturbojpeg.a" });
        }
    }

    exe.linkLibC();

    // Add vendor imports
    exe.root_module.addImport("json", json_mod);
    exe.root_module.addImport("websocket", websocket_mod);

    b.installArtifact(exe);

    // NAPI shared library for Node.js (skip in CI with -Dskip-napi=true)
    if (!skip_napi) {
    const napi = b.addLibrary(.{
        .name = "termweb",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/napi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Embed version
    napi.root_module.addOptions("build_options", version_option);

    // Add C libraries
    napi.addCSourceFile(.{
        .file = b.path("src/vendor/stb_image.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    napi.addCSourceFile(.{
        .file = b.path("src/vendor/stb_truetype.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    napi.addCSourceFile(.{
        .file = b.path("src/vendor/nanosvg.c"),
        .flags = &.{ "-O2", "-fno-strict-aliasing" },
    });
    napi.addIncludePath(b.path("src/vendor"));

    // libdeflate for zlib compression (Kitty graphics)
    napi.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/deflate_compress.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    napi.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/zlib_compress.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    napi.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/adler32.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    napi.addCSourceFile(.{
        .file = b.path("vendor/libdeflate/lib/utils.c"),
        .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
    });
    // CPU features: use arm/ for ARM, x86/ for x86
    if (target.result.cpu.arch == .aarch64) {
        napi.addCSourceFile(.{
            .file = b.path("vendor/libdeflate/lib/arm/cpu_features.c"),
            .flags = &.{"-O2"},
        });
    } else {
        napi.addCSourceFile(.{
            .file = b.path("vendor/libdeflate/lib/x86/cpu_features.c"),
            .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
        });
    }
    napi.addIncludePath(b.path("vendor/libdeflate"));

    // libjpeg-turbo
    if (target.result.os.tag == .macos) {
        if (target.result.cpu.arch == .aarch64) {
            napi.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/jpeg-turbo/include" });
            napi.addObjectFile(.{ .cwd_relative = "/opt/homebrew/opt/jpeg-turbo/lib/libturbojpeg.a" });
        } else {
            napi.addIncludePath(.{ .cwd_relative = "/usr/local/opt/jpeg-turbo/include" });
            napi.addObjectFile(.{ .cwd_relative = "/usr/local/opt/jpeg-turbo/lib/libturbojpeg.a" });
        }
    } else if (target.result.os.tag == .linux) {
        // Linux: use -fPIC build from /usr/local (built from source)
        if (target.result.cpu.arch == .aarch64) {
            napi.addIncludePath(.{ .cwd_relative = "/usr/local/aarch64-linux-gnu/include" });
            napi.addObjectFile(.{ .cwd_relative = "/usr/local/aarch64-linux-gnu/lib/libturbojpeg.a" });
        } else {
            napi.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            napi.addObjectFile(.{ .cwd_relative = "/usr/local/lib/libturbojpeg.a" });
        }
    }

    napi.linkLibC();
    napi.root_module.addImport("json", json_mod);
    napi.root_module.addImport("websocket", websocket_mod);

    // Allow undefined NAPI symbols (provided by Node.js at runtime)
    napi.linker_allow_shlib_undefined = true;

    // Install as .node file
    const napi_install = b.addInstallArtifact(napi, .{
        .dest_sub_path = "termweb.node",
    });
    b.getInstallStep().dependOn(&napi_install.step);
    }

    // =========================================================================
    // Mux server (cross-platform with libghostty)
    // - macOS: libghostty + VideoToolbox + IOSurface
    // - Linux: libghostty + VA-API/software encoding
    // =========================================================================
    if (target.result.os.tag == .macos or target.result.os.tag == .linux) {
        const mux = b.addExecutable(.{
            .name = ".termweb-mux", // Hidden binary, accessed via "termweb mux"
            .root_module = b.createModule(.{
                .root_source_file = b.path("packages/mux/native/src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Link pre-built libghostty (both platforms)
        mux.addObjectFile(b.path("vendor/libs/libghostty.a"));
        mux.addIncludePath(b.path("vendor/ghostty/include"));

        // Platform-specific dependencies
        if (target.result.os.tag == .macos) {
            // macOS frameworks required by libghostty and VideoToolbox
            mux.linkFramework("Foundation");
            mux.linkFramework("CoreFoundation");
            mux.linkFramework("CoreGraphics");
            mux.linkFramework("CoreText");
            mux.linkFramework("CoreVideo");
            mux.linkFramework("QuartzCore");
            mux.linkFramework("IOSurface");
            mux.linkFramework("Metal");
            mux.linkFramework("MetalKit");
            mux.linkFramework("Carbon");
            mux.linkFramework("AppKit");
            mux.linkFramework("VideoToolbox");
            mux.linkFramework("CoreMedia");
            mux.linkFramework("Accelerate");
            mux.linkLibCpp();
        } else {
            // Linux: link vendored static libraries (built from Ghostty)
            mux.addObjectFile(b.path("vendor/libs/libsimdutf.a"));
            mux.addObjectFile(b.path("vendor/libs/libglslang.a"));
            mux.addObjectFile(b.path("vendor/libs/libspirv_cross.a"));
            mux.addObjectFile(b.path("vendor/libs/libhighway.a"));
            mux.addObjectFile(b.path("vendor/libs/liboniguruma.a"));
            mux.addObjectFile(b.path("vendor/libs/libharfbuzz.a"));
            mux.addObjectFile(b.path("vendor/libs/libfreetype.a"));
            mux.addObjectFile(b.path("vendor/libs/libfontconfig.a"));
            mux.addObjectFile(b.path("vendor/libs/libutfcpp.a"));
            mux.addObjectFile(b.path("vendor/libs/libpng.a"));
            mux.addObjectFile(b.path("vendor/libs/libz.a"));
            mux.addObjectFile(b.path("vendor/libs/libdcimgui.a"));
            mux.addObjectFile(b.path("vendor/libs/libxml2.a"));
            // VA-API for hardware H.264 encoding (Intel/AMD/NVIDIA GPUs)
            mux.linkSystemLibrary("va");
            mux.linkSystemLibrary("va-drm");
            // Compile glad for OpenGL function loading
            mux.addCSourceFile(.{
                .file = b.path("vendor/ghostty/vendor/glad/src/gl.c"),
                .flags = &.{"-O2"},
            });
            mux.addIncludePath(b.path("vendor/ghostty/vendor/glad/include"));
            // EGL and GL are loaded dynamically at runtime by egl_headless.zig
            mux.linkLibCpp();
        }

        // Websocket module (cross-platform)
        mux.root_module.addImport("websocket", websocket_mod);

        // SIMD mask module (cross-platform)
        const mux_simd_mod = b.createModule(.{
            .root_source_file = b.path("src/simd/mask.zig"),
            .target = target,
            .optimize = optimize,
        });
        mux.root_module.addImport("simd_mask", mux_simd_mod);

        // Shared memory module (for Linux IPC)
        const mux_shm_mod = b.createModule(.{
            .root_source_file = b.path("src/simd/shared_memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        mux.root_module.addImport("shared_memory", mux_shm_mod);


        // libdeflate (cross-platform)
        const libdeflate_flags = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64)
            &[_][]const u8{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" }
        else
            &[_][]const u8{"-O2"};

        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/deflate_compress.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/deflate_decompress.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/zlib_compress.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/zlib_decompress.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/adler32.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/crc32.c"), .flags = libdeflate_flags });
        mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/utils.c"), .flags = libdeflate_flags });

        // CPU features (platform-specific)
        if (target.result.os.tag == .macos or target.result.cpu.arch == .aarch64) {
            mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/arm/cpu_features.c"), .flags = &.{"-O2"} });
        } else {
            mux.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/x86/cpu_features.c"), .flags = libdeflate_flags });
        }
        mux.addIncludePath(b.path("vendor/libdeflate"));

        // xxHash (cross-platform)
        mux.addIncludePath(b.path("vendor/xxhash"));
        mux.addCSourceFile(.{ .file = b.path("vendor/xxhash/xxhash.c"), .flags = &.{"-O2"} });

        // Web assets module - client.js is built by Makefile's mux-web target
        // (Makefile touches assets.zig to force zig to re-embed on changes)
        const web_assets = b.createModule(.{
            .root_source_file = b.path("packages/mux/web/assets.zig"),
        });
        mux.root_module.addImport("web_assets", web_assets);

        mux.linkLibC();
        b.installArtifact(mux);

        // Mux run step
        const mux_run = b.addRunArtifact(mux);
        mux_run.step.dependOn(b.getInstallStep());
        if (b.args) |args| mux_run.addArgs(args);
        const mux_step = b.step("mux", "Run termweb-mux server");
        mux_step.dependOn(&mux_run.step);
    }

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
