const std = @import("std");
const cdp = @import("../src/chrome/cdp_client.zig");
const screenshot = @import("../src/chrome/screenshot.zig");

const Asset = struct {
    name: []const u8,
    html_path: []const u8,
    width: u32,
    height: u32,
    // Placeholders to replace in HTML
    theme: []const u8, // "" (dark) or "light"
    state: []const u8, // "", "hover", "active", "disabled", "loading"
};

const base_assets = [_]struct {
    name: []const u8,
    html: []const u8,
    width: u32,
    height: u32,
    states: []const []const u8,
}{
    // Navigation buttons
    .{ .name = "back", .html = "components/back.html", .width = 32, .height = 32, .states = &.{ "", "hover", "active", "disabled" } },
    .{ .name = "forward", .html = "components/forward.html", .width = 32, .height = 32, .states = &.{ "", "hover", "active", "disabled" } },
    .{ .name = "refresh", .html = "components/refresh.html", .width = 32, .height = 32, .states = &.{ "", "hover", "active", "loading" } },
    .{ .name = "close", .html = "components/close.html", .width = 32, .height = 32, .states = &.{ "", "hover", "active" } },
    // Bars (generated at multiple widths)
    .{ .name = "tabbar", .html = "tabbar.html", .width = 1280, .height = 40, .states = &.{""} },
    .{ .name = "statusbar", .html = "statusbar.html", .width = 1280, .height = 24, .states = &.{""} },
};

const themes = [_][]const u8{ "", "light" };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cwd = std.fs.cwd();
    const ui_html_dir = try cwd.realpathAlloc(allocator, "ui/html");
    defer allocator.free(ui_html_dir);

    std.debug.print("=== UI Asset Generator ===\n", .{});
    std.debug.print("HTML source: {s}\n\n", .{ui_html_dir});

    // Launch Chrome
    std.debug.print("Launching Chrome...\n", .{});
    var chrome = std.process.Child.init(&.{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "--headless=new",
        "--disable-gpu",
        "--remote-debugging-port=9223", // Use different port for build tool
        "--window-size=1920,1080",
    }, allocator);
    chrome.spawn() catch |err| {
        std.debug.print("Failed to launch Chrome: {}\n", .{err});
        std.debug.print("Please ensure Google Chrome is installed\n", .{});
        return;
    };
    defer {
        _ = chrome.kill() catch {};
    }

    // Wait for Chrome to start
    std.time.sleep(2 * std.time.ns_per_s);

    // Connect to Chrome
    std.debug.print("Connecting to Chrome DevTools...\n", .{});
    var client = cdp.CdpClient.init(allocator) catch |err| {
        std.debug.print("Failed to connect to Chrome: {}\n", .{err});
        return;
    };
    defer client.deinit();

    // Enable Page domain for navigation
    _ = client.sendCommand("Page.enable", null) catch |err| {
        std.debug.print("Failed to enable Page domain: {}\n", .{err});
        return;
    };

    var generated_count: usize = 0;

    // Generate assets for each theme
    for (themes) |theme| {
        const theme_dir = if (theme.len > 0) theme else "dark";
        std.debug.print("\nGenerating {s} theme assets...\n", .{theme_dir});

        // Create theme output directory
        const out_dir = try std.fmt.allocPrint(allocator, "assets/{s}", .{theme_dir});
        defer allocator.free(out_dir);
        cwd.makePath(out_dir) catch {};

        // Generate each asset
        for (base_assets) |asset| {
            for (asset.states) |state| {
                const state_suffix = if (state.len > 0) state else "normal";
                const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.png", .{ asset.name, state_suffix });
                defer allocator.free(filename);

                const html_path = try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ ui_html_dir, asset.html });
                defer allocator.free(html_path);

                std.debug.print("  {s}/{s}...", .{ theme_dir, filename });

                // Set viewport (DPR=1 for asset generation)
                screenshot.setViewport(&client, allocator, asset.width, asset.height, 1) catch |err| {
                    std.debug.print(" FAILED (viewport): {}\n", .{err});
                    continue;
                };

                // Navigate to HTML file
                const nav_params = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{html_path});
                defer allocator.free(nav_params);

                _ = client.sendCommand("Page.navigate", nav_params) catch |err| {
                    std.debug.print(" FAILED (navigate): {}\n", .{err});
                    continue;
                };

                std.time.sleep(500 * std.time.ns_per_ms);

                // Inject theme and state classes
                const theme_class = if (theme.len > 0) theme else "";
                const state_class = state;
                const js_code = try std.fmt.allocPrint(allocator,
                    \\document.documentElement.className = '{s}';
                    \\var btn = document.querySelector('.glass-btn');
                    \\if (btn) btn.className = 'glass-btn {s}';
                , .{ theme_class, state_class });
                defer allocator.free(js_code);

                const js_escaped = try escapeJsonString(allocator, js_code);
                defer allocator.free(js_escaped);

                const js_params = try std.fmt.allocPrint(allocator, "{{\"expression\":\"{s}\"}}", .{js_escaped});
                defer allocator.free(js_params);

                _ = client.sendCommand("Runtime.evaluate", js_params) catch {};

                std.time.sleep(100 * std.time.ns_per_ms);

                // Capture screenshot with transparent background
                const cap_params = "{\"format\":\"png\",\"captureBeyondViewport\":false}";
                const result = client.sendCommand("Page.captureScreenshot", cap_params) catch |err| {
                    std.debug.print(" FAILED (capture): {}\n", .{err});
                    continue;
                };
                defer allocator.free(result);

                // Extract base64 data
                if (std.mem.indexOf(u8, result, "\"data\":\"")) |data_start| {
                    const data_value_start = data_start + "\"data\":\"".len;
                    if (std.mem.indexOfPos(u8, result, data_value_start, "\"")) |data_end| {
                        const base64_data = result[data_value_start..data_end];

                        // Decode and save
                        const decoded = try std.base64.standard.Decoder.calcSizeForSlice(base64_data);
                        const png_data = try allocator.alloc(u8, decoded);
                        defer allocator.free(png_data);

                        _ = std.base64.standard.Decoder.decode(png_data, base64_data) catch |err| {
                            std.debug.print(" FAILED (decode): {}\n", .{err});
                            continue;
                        };

                        // Write to file
                        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, filename });
                        defer allocator.free(out_path);

                        const file = cwd.createFile(out_path, .{}) catch |err| {
                            std.debug.print(" FAILED (write): {}\n", .{err});
                            continue;
                        };
                        defer file.close();
                        file.writeAll(png_data) catch |err| {
                            std.debug.print(" FAILED (write): {}\n", .{err});
                            continue;
                        };

                        std.debug.print(" OK ({d} bytes)\n", .{png_data.len});
                        generated_count += 1;
                    }
                } else {
                    std.debug.print(" FAILED (no data)\n", .{});
                }
            }
        }
    }

    std.debug.print("\n=== Done ===\n", .{});
    std.debug.print("Generated {d} assets\n", .{generated_count});
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }
    return result.toOwnedSlice();
}
