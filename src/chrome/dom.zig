/// DOM querying module for interactive form elements.
///
/// Provides functionality to query and interact with DOM elements via
/// JavaScript injection through Chrome DevTools Protocol. Elements are
/// identified by their tag, type, position, and text content.
const std = @import("std");
const cdp = @import("cdp_client.zig");

/// InteractiveElement represents a detected form element on the page.
///
/// Elements are queried via JavaScript that returns position, type, and
/// text information. The selector field is used for element targeting
/// in subsequent interactions (focus, click, type).
///
/// Supported element types:
/// - Links: <a href="...">
/// - Buttons: <button>, <input type="submit">
/// - Text inputs: <input type="text">, <input type="password">
/// - Checkboxes: <input type="checkbox">
/// - Radio buttons: <input type="radio">
/// - Selects: <select>
/// - Textareas: <textarea>
pub const InteractiveElement = struct {
    index: usize,
    tag: []const u8,        // "a", "input", "button", "select"
    type: ?[]const u8,      // "text", "checkbox", "radio"
    text: []const u8,       // Display text
    value: []const u8,      // Current value
    href: ?[]const u8,      // For links
    x: u32,
    y: u32,                 // Position (with scroll offset)
    width: u32,
    height: u32,
    selector: []const u8,   // CSS selector

    pub fn deinit(self: *InteractiveElement, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        if (self.type) |t| allocator.free(t);
        allocator.free(self.text);
        allocator.free(self.value);
        if (self.href) |h| allocator.free(h);
        allocator.free(self.selector);
    }

    pub fn describe(self: *const InteractiveElement, buf: []u8) ![]const u8 {
        if (std.mem.eql(u8, self.tag, "a")) {
            return try std.fmt.bufPrint(buf, "Link: {s}", .{self.text});
        } else if (std.mem.eql(u8, self.tag, "input")) {
            if (self.type) |t| {
                return try std.fmt.bufPrint(buf, "Input[{s}]: {s}", .{ t, self.text });
            }
        } else if (std.mem.eql(u8, self.tag, "button")) {
            return try std.fmt.bufPrint(buf, "Button: {s}", .{self.text});
        }
        return try std.fmt.bufPrint(buf, "{s}: {s}", .{ self.tag, self.text });
    }
};

pub const FormContext = struct {
    allocator: std.mem.Allocator,
    elements: []InteractiveElement,
    current_index: usize,

    pub fn init(allocator: std.mem.Allocator) FormContext {
        return .{
            .allocator = allocator,
            .elements = &[_]InteractiveElement{},
            .current_index = 0,
        };
    }

    pub fn deinit(self: *FormContext) void {
        for (self.elements) |*elem| {
            elem.deinit(self.allocator);
        }
        self.allocator.free(self.elements);
    }

    pub fn current(self: *const FormContext) ?*const InteractiveElement {
        if (self.elements.len == 0) return null;
        return &self.elements[self.current_index];
    }

    pub fn next(self: *FormContext) void {
        if (self.elements.len == 0) return;
        self.current_index = (self.current_index + 1) % self.elements.len;
    }

    pub fn prev(self: *FormContext) void {
        if (self.elements.len == 0) return;
        if (self.current_index == 0) {
            self.current_index = self.elements.len - 1;
        } else {
            self.current_index -= 1;
        }
    }
};

/// Query all interactive elements via JavaScript
pub fn queryElements(
    client: *cdp.CdpClient,
    allocator: std.mem.Allocator,
) ![]InteractiveElement {
    const js =
        \\(function() {
        \\  const elements = [];
        \\  const nodes = document.querySelectorAll('a[href], button, input, select, textarea');
        \\  nodes.forEach((el, idx) => {
        \\    const rect = el.getBoundingClientRect();
        \\    if (rect.width === 0 || rect.height === 0) return;
        \\    elements.push({
        \\      index: idx,
        \\      tag: el.tagName.toLowerCase(),
        \\      type: el.type || null,
        \\      text: (el.textContent || el.value || el.placeholder || '').trim().substring(0, 100),
        \\      value: el.value || '',
        \\      href: el.href || null,
        \\      x: Math.round(rect.left + window.scrollX),
        \\      y: Math.round(rect.top + window.scrollY),
        \\      width: Math.round(rect.width),
        \\      height: Math.round(rect.height),
        \\      selector: el.id ? '#' + el.id : el.tagName.toLowerCase()
        \\    });
        \\  });
        \\  return elements;
        \\})()
    ;

    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{js},
    );
    defer allocator.free(params);

    // Use nav_ws - pipe is for screencast only
    const result = try client.sendNavCommand("Runtime.evaluate", params);
    defer allocator.free(result);

    return try parseElementsFromJson(allocator, result);
}

/// Parse JSON array of elements into InteractiveElement structs
fn parseElementsFromJson(allocator: std.mem.Allocator, json: []const u8) ![]InteractiveElement {
    // Use std.json.parseFromSlice to parse the response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    // Navigate to result.result.value array
    const root = parsed.value.object;
    const result_obj = root.get("result") orelse return error.InvalidResponse;
    const inner_result = result_obj.object.get("result") orelse return error.InvalidResponse;
    const elements_array = inner_result.object.get("value") orelse return error.InvalidResponse;

    if (elements_array != .array) return error.InvalidResponse;

    // Allocate element array
    var elements = try allocator.alloc(InteractiveElement, elements_array.array.items.len);
    errdefer allocator.free(elements);

    // Parse each element
    for (elements_array.array.items, 0..) |elem_val, i| {
        if (elem_val != .object) continue;
        const elem_obj = elem_val.object;

        elements[i] = InteractiveElement{
            .index = @intCast(elem_obj.get("index").?.integer),
            .tag = try allocator.dupe(u8, elem_obj.get("tag").?.string),
            .type = if (elem_obj.get("type")) |t|
                if (t == .string) try allocator.dupe(u8, t.string) else null
            else
                null,
            .text = try allocator.dupe(u8, elem_obj.get("text").?.string),
            .value = try allocator.dupe(u8, elem_obj.get("value").?.string),
            .href = if (elem_obj.get("href")) |h|
                if (h == .string) try allocator.dupe(u8, h.string) else null
            else
                null,
            .x = std.math.cast(u32, elem_obj.get("x").?.integer) orelse continue,
            .y = std.math.cast(u32, elem_obj.get("y").?.integer) orelse continue,
            .width = std.math.cast(u32, elem_obj.get("width").?.integer) orelse continue,
            .height = std.math.cast(u32, elem_obj.get("height").?.integer) orelse continue,
            .selector = try allocator.dupe(u8, elem_obj.get("selector").?.string),
        };
    }

    return elements;
}
