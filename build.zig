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

    // SIMD mask module (shared between termweb and mux)
    const simd_mask_mod = b.createModule(.{
        .root_source_file = b.path("src/simd/mask.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared memory module (shared between termweb and mux)
    const shared_memory_mod = b.createModule(.{
        .root_source_file = b.path("src/simd/shared_memory.zig"),
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

    // Add C libraries (stb_image excluded on macOS/Linux - libghostty already has it)
    if (target.result.os.tag != .macos and target.result.os.tag != .linux) {
        exe.addCSourceFile(.{
            .file = b.path("src/vendor/stb_image.c"),
            .flags = &.{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" },
        });
    }
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
    exe.root_module.addImport("simd_mask", simd_mask_mod);

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
    napi.root_module.addImport("simd_mask", simd_mask_mod);

    // Allow undefined NAPI symbols (provided by Node.js at runtime)
    napi.linker_allow_shlib_undefined = true;

    // Install as .node file
    const napi_install = b.addInstallArtifact(napi, .{
        .dest_sub_path = "termweb.node",
    });
    b.getInstallStep().dependOn(&napi_install.step);
    }

    // =========================================================================
    // Mux module (cross-platform with libghostty)
    // Integrated into main termweb binary as "termweb mux" subcommand
    // - macOS: libghostty + VideoToolbox + IOSurface
    // - Linux: libghostty + VA-API/software encoding
    // =========================================================================
    if (target.result.os.tag == .macos or target.result.os.tag == .linux) {
        // Create mux module for import into main exe
        const mux_mod = b.createModule(.{
            .root_source_file = b.path("packages/mux/native/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        // Add include paths for @cImport in mux module
        mux_mod.addIncludePath(b.path("vendor/libdeflate"));
        mux_mod.addIncludePath(b.path("vendor/ghostty/include"));

        // Web assets module
        const web_assets = b.createModule(.{
            .root_source_file = b.path("packages/mux/web/assets.zig"),
        });
        mux_mod.addImport("web_assets", web_assets);

        // Shared modules
        mux_mod.addImport("websocket", websocket_mod);
        mux_mod.addImport("simd_mask", simd_mask_mod);
        mux_mod.addImport("shared_memory", shared_memory_mod);

        // Add mux module to main exe
        exe.root_module.addImport("mux", mux_mod);

        // Link pre-built libghostty (platform and architecture specific)
        const libghostty_path = blk: {
            const os = target.result.os.tag;
            const arch = target.result.cpu.arch;
            if (os == .macos) {
                break :blk switch (arch) {
                    .aarch64 => "vendor/libs/darwin-arm64/libghostty.a",
                    .x86_64 => "vendor/libs/darwin-x86_64/libghostty.a",
                    else => @panic("Unsupported macOS architecture"),
                };
            } else {
                break :blk switch (arch) {
                    .x86_64 => "vendor/libs/linux-x86_64/libghostty.a",
                    .aarch64 => "vendor/libs/linux-aarch64/libghostty.a",
                    else => @panic("Unsupported Linux architecture"),
                };
            }
        };
        exe.addObjectFile(b.path(libghostty_path));
        exe.addIncludePath(b.path("vendor/ghostty/include"));

        // Platform-specific dependencies for mux
        if (target.result.os.tag == .macos) {
            // macOS frameworks required by libghostty and VideoToolbox
            exe.linkFramework("Foundation");
            exe.linkFramework("CoreFoundation");
            exe.linkFramework("CoreGraphics");
            exe.linkFramework("CoreText");
            exe.linkFramework("CoreVideo");
            exe.linkFramework("QuartzCore");
            exe.linkFramework("IOSurface");
            exe.linkFramework("Metal");
            exe.linkFramework("MetalKit");
            exe.linkFramework("Carbon");
            exe.linkFramework("AppKit");
            exe.linkFramework("VideoToolbox");
            exe.linkFramework("CoreMedia");
            exe.linkFramework("Accelerate");
            exe.linkLibCpp();
        } else {
            // Linux: link vendored static libraries (built from Ghostty)
            exe.addObjectFile(b.path("vendor/libs/libsimdutf.a"));
            exe.addObjectFile(b.path("vendor/libs/libglslang.a"));
            exe.addObjectFile(b.path("vendor/libs/libspirv_cross.a"));
            exe.addObjectFile(b.path("vendor/libs/libhighway.a"));
            exe.addObjectFile(b.path("vendor/libs/liboniguruma.a"));
            exe.addObjectFile(b.path("vendor/libs/libharfbuzz.a"));
            exe.addObjectFile(b.path("vendor/libs/libfreetype.a"));
            exe.addObjectFile(b.path("vendor/libs/libfontconfig.a"));
            exe.addObjectFile(b.path("vendor/libs/libutfcpp.a"));
            exe.addObjectFile(b.path("vendor/libs/libpng.a"));
            exe.addObjectFile(b.path("vendor/libs/libz.a"));
            exe.addObjectFile(b.path("vendor/libs/libdcimgui.a"));
            exe.addObjectFile(b.path("vendor/libs/libxml2.a"));
            // VA-API for hardware H.264 encoding (Intel/AMD/NVIDIA GPUs)
            exe.linkSystemLibrary("va");
            exe.linkSystemLibrary("va-drm");
            // Compile glad for OpenGL function loading
            exe.addCSourceFile(.{
                .file = b.path("vendor/ghostty/vendor/glad/src/gl.c"),
                .flags = &.{"-O2"},
            });
            exe.addIncludePath(b.path("vendor/ghostty/vendor/glad/include"));
            exe.linkLibCpp();
        }

        // libdeflate for mux (cross-platform) - note: termweb already has some, add missing ones
        const libdeflate_flags_mux = if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64)
            &[_][]const u8{ "-O2", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_AVX512VNNI=1", "-DLIBDEFLATE_ASSEMBLER_DOES_NOT_SUPPORT_VPCLMULQDQ=1" }
        else
            &[_][]const u8{"-O2"};

        exe.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/deflate_decompress.c"), .flags = libdeflate_flags_mux });
        exe.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/zlib_decompress.c"), .flags = libdeflate_flags_mux });
        exe.addCSourceFile(.{ .file = b.path("vendor/libdeflate/lib/crc32.c"), .flags = libdeflate_flags_mux });

        // xxHash (cross-platform)
        exe.addIncludePath(b.path("vendor/xxhash"));
        exe.addCSourceFile(.{ .file = b.path("vendor/xxhash/xxhash.c"), .flags = &.{"-O2"} });

        // zstd for WebSocket compression (faster than deflate)
        const zstd_flags = &[_][]const u8{ "-O2", "-DZSTD_DISABLE_ASM" };
        // Common sources (including xxhash which is part of zstd)
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/debug.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/entropy_common.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/error_private.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/fse_decompress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/pool.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/threading.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/zstd_common.c"), .flags = zstd_flags });
        // zstd uses its own xxhash implementation with ZSTD_ prefix
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/common/xxhash.c"), .flags = zstd_flags });
        // Compress sources
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/fse_compress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/hist.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/huf_compress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_compress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_compress_literals.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_compress_sequences.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_compress_superblock.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_double_fast.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_fast.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_lazy.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_ldm.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_opt.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstd_preSplit.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/compress/zstdmt_compress.c"), .flags = zstd_flags });
        // Decompress sources
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/decompress/huf_decompress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/decompress/zstd_ddict.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/decompress/zstd_decompress.c"), .flags = zstd_flags });
        exe.addCSourceFile(.{ .file = b.path("vendor/zstd/lib/decompress/zstd_decompress_block.c"), .flags = zstd_flags });
        // Include path for zstd
        exe.addIncludePath(b.path("vendor/zstd/lib"));
        mux_mod.addIncludePath(b.path("vendor/zstd/lib"));

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
