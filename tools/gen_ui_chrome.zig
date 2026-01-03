//! Generate UI assets by rendering HTML templates with Chrome headless
//! Run with: zig build run-gen-ui

const std = @import("std");
const cdp = @import("../src/chrome/cdp_client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== UI Asset Generator ===\n", .{});

    // Get absolute path to ui/html
    const cwd = std.fs.cwd();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try cwd.realpath("ui/html", &path_buf);
    std.debug.print("HTML templates: {s}\n", .{abs_path});

    // Launch Chrome headless
    std.debug.print("Launching Chrome...\n", .{});
    var chrome = std.process.Child.init(&.{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "--headless=new",
        "--disable-gpu",
        "--remote-debugging-port=9333",
        "--window-size=64,64",
    }, allocator);
    try chrome.spawn();
    defer _ = chrome.kill() catch {};

    std.time.sleep(2 * std.time.ns_per_s);

    // Connect via CDP
    std.debug.print("Connecting to Chrome...\n", .{});
    var client = try cdp.CdpClient.initWithPort(allocator, 9333);
    defer client.deinit();

    _ = try client.sendCommand("Page.enable", null);

    const components = [_]struct {
        name: []const u8,
        html: []const u8,
        width: u32,
        height: u32,
        states: []const []const u8,
    }{
        .{ .name = "back", .html = "components/back.html", .width = 32, .height = 32, .states = &.{ "normal", "hover", "active", "disabled" } },
        .{ .name = "forward", .html = "components/forward.html", .width = 32, .height = 32, .states = &.{ "normal", "hover", "active", "disabled" } },
        .{ .name = "refresh", .html = "components/refresh.html", .width = 32, .height = 32, .states = &.{ "normal", "hover", "active", "loading" } },
        .{ .name = "close", .html = "components/close.html", .width = 32, .height = 32, .states = &.{ "normal", "hover", "active" } },
    };

    const themes = [_][]const u8{ "dark", "light" };

    for (themes) |theme| {
        std.debug.print("\nGenerating {s} theme...\n", .{theme});
        const out_dir = try std.fmt.allocPrint(allocator, "src/ui/assets/{s}", .{theme});
        defer allocator.free(out_dir);
        cwd.makePath(out_dir) catch {};

        for (components) |comp| {
            for (comp.states) |state| {
                const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.png", .{ comp.name, state });
                defer allocator.free(filename);

                const html_url = try std.fmt.allocPrint(allocator, "file://{s}/{s}", .{ abs_path, comp.html });
                defer allocator.free(html_url);

                std.debug.print("  {s}...", .{filename});

                // Set viewport
                const vp_params = try std.fmt.allocPrint(allocator,
                    \\{{"width":{d},"height":{d},"deviceScaleFactor":2,"mobile":false}}
                , .{ comp.width, comp.height });
                defer allocator.free(vp_params);
                const vp_result = try client.sendCommand("Emulation.setDeviceMetricsOverride", vp_params);
                allocator.free(vp_result);

                // Navigate
                const nav_params = try std.fmt.allocPrint(allocator,
                    \\{{"url":"{s}"}}
                , .{html_url});
                defer allocator.free(nav_params);
                const nav_result = try client.sendCommand("Page.navigate", nav_params);
                allocator.free(nav_result);

                std.time.sleep(300 * std.time.ns_per_ms);

                // Inject theme and state
                const theme_class = if (std.mem.eql(u8, theme, "light")) "light" else "";
                const js = try std.fmt.allocPrint(allocator,
                    \\document.documentElement.className = '{s}';
                    \\var btn = document.querySelector('.glass-btn');
                    \\if (btn) btn.className = 'glass-btn {s}';
                , .{ theme_class, state });
                defer allocator.free(js);

                var escaped = std.ArrayList(u8).init(allocator);
                defer escaped.deinit();
                for (js) |c| {
                    switch (c) {
                        '\n' => try escaped.appendSlice("\\n"),
                        '\'' => try escaped.appendSlice("\\'"),
                        '\\' => try escaped.appendSlice("\\\\"),
                        else => try escaped.append(c),
                    }
                }

                const js_params = try std.fmt.allocPrint(allocator,
                    \\{{"expression":"{s}"}}
                , .{escaped.items});
                defer allocator.free(js_params);
                const js_result = try client.sendCommand("Runtime.evaluate", js_params);
                allocator.free(js_result);

                std.time.sleep(100 * std.time.ns_per_ms);

                // Screenshot
                const ss_result = try client.sendCommand("Page.captureScreenshot",
                    \\{"format":"png","captureBeyondViewport":false}
                );
                defer allocator.free(ss_result);

                // Extract base64 data
                if (std.mem.indexOf(u8, ss_result, "\"data\":\"")) |start| {
                    const data_start = start + 8;
                    if (std.mem.indexOfPos(u8, ss_result, data_start, "\"")) |end| {
                        const b64 = ss_result[data_start..end];
                        const decoded_size = try std.base64.standard.Decoder.calcSizeForSlice(b64);
                        const png = try allocator.alloc(u8, decoded_size);
                        defer allocator.free(png);
                        try std.base64.standard.Decoder.decode(png, b64);

                        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, filename });
                        defer allocator.free(out_path);
                        const file = try cwd.createFile(out_path, .{});
                        defer file.close();
                        try file.writeAll(png);

                        std.debug.print(" OK ({d} bytes)\n", .{png.len});
                    }
                } else {
                    std.debug.print(" FAILED\n", .{});
                }
            }
        }
    }

    std.debug.print("\nDone!\n", .{});
}
