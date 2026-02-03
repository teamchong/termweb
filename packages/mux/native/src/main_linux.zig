// Linux-specific mux server
// Uses PTY terminal instead of libghostty

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("ws_server.zig");
const http = @import("http_server.zig");
const PtyTerminal = @import("pty_terminal.zig").Terminal;

// Global state for callbacks
var global_terminal: ?*PtyTerminal = null;
var global_connections: std.ArrayListUnmanaged(*ws.Connection) = .{};
var global_allocator: std.mem.Allocator = undefined;
var global_mutex: std.Thread.Mutex = .{};

fn onConnect(conn: *ws.Connection) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_connections.append(global_allocator, conn) catch {};
    std.debug.print("Client connected\n", .{});
}

fn onMessage(conn: *ws.Connection, data: []u8, is_binary: bool) void {
    _ = conn;
    _ = is_binary;

    // Forward input to terminal
    if (global_terminal) |terminal| {
        terminal.write(data) catch {};
    }
}

fn onDisconnect(conn: *ws.Connection) void {
    global_mutex.lock();
    defer global_mutex.unlock();

    for (global_connections.items, 0..) |c, i| {
        if (c == conn) {
            _ = global_connections.swapRemove(i);
            break;
        }
    }
    std.debug.print("Client disconnected\n", .{});
}

fn broadcastToClients(data: []const u8) void {
    global_mutex.lock();
    defer global_mutex.unlock();

    for (global_connections.items) |conn| {
        conn.sendBinary(data) catch {};
    }
}

fn terminalOutputThread() void {
    var buf: [4096]u8 = undefined;

    while (true) {
        if (global_terminal) |terminal| {
            // Read from PTY (non-blocking)
            const n = terminal.readRaw(&buf) catch |err| {
                std.debug.print("Terminal read error: {}\n", .{err});
                break;
            };

            if (n > 0) {
                // Send to all connected clients
                broadcastToClients(buf[0..n]);
            } else {
                // No data available, sleep briefly
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        } else {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    global_allocator = allocator;
    defer global_connections.deinit(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var http_port: u16 = 8080;
    var ws_port: u16 = 8081;

    // Parse args
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                http_port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
                ws_port = http_port + 1;
                i += 1;
            }
        }
    }

    std.debug.print("termweb-mux (Linux) starting...\n", .{});

    // Initialize terminal (80 cols x 24 rows, 800x600 pixels)
    const terminal = try PtyTerminal.init(allocator, 800, 600);
    defer terminal.deinit();
    global_terminal = terminal;

    // Start HTTP server
    var http_server = try http.HttpServer.init(allocator, "0.0.0.0", http_port, null);
    defer http_server.deinit();

    // Start WebSocket server
    var ws_server = try ws.Server.init(allocator, "0.0.0.0", ws_port);
    defer ws_server.deinit();
    ws_server.setCallbacks(onConnect, onMessage, onDisconnect);

    std.debug.print("Server running:\n", .{});
    std.debug.print("  HTTP:      http://localhost:{}\n", .{http_port});
    std.debug.print("  WebSocket: ws://localhost:{}\n", .{ws_port});
    std.debug.print("Press Ctrl+C to stop\n", .{});

    // Start HTTP server thread
    const http_thread = try std.Thread.spawn(.{}, http.HttpServer.run, .{http_server});
    _ = http_thread;

    // Start WebSocket server thread
    const ws_thread = try std.Thread.spawn(.{}, ws.Server.run, .{ws_server});
    _ = ws_thread;

    // Start terminal output thread
    const output_thread = try std.Thread.spawn(.{}, terminalOutputThread, .{});
    _ = output_thread;

    // Main loop - tick terminal
    while (true) {
        try terminal.tick();
        std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 FPS
    }
}
