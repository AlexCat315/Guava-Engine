const std = @import("std");
const EditorState = @import("../../../core/state.zig").EditorState;

pub fn buildStatusMetricsText(
    writer: anytype,
    state: *const EditorState,
    selection_count: usize,
    fps: f32,
    save_status: []const u8,
    backend_text: []const u8,
    memory_text: []const u8,
    window_width: f32,
) !void {
    var first = true;

    var selection_buffer: [24]u8 = undefined;
    const selection_text = try std.fmt.bufPrint(&selection_buffer, "{d}", .{selection_count});
    try appendStatusSegment(writer, &first, state.text(.selection_count), selection_text);

    if (state.fps_display_mode == .status_bar) {
        var fps_buffer: [32]u8 = undefined;
        const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
        try appendStatusSegment(writer, &first, state.text(.fps), fps_text);
    }

    try appendStatusSegment(writer, &first, state.text(.save_status), save_status);
    if (window_width >= 980.0) {
        try appendStatusSegment(writer, &first, state.text(.backend), backend_text);
    }
    if (window_width >= 1180.0) {
        try appendStatusSegment(writer, &first, state.text(.memory), memory_text);
    }
}

pub fn buildStatusContextText(
    writer: anytype,
    state: *const EditorState,
    selected_path: []const u8,
    camera_text: []const u8,
    mode_text: []const u8,
    space_text: []const u8,
    window_width: f32,
) !void {
    var first = true;
    try appendStatusSegment(writer, &first, state.text(.selected_path), selected_path);
    if (window_width >= 820.0) {
        try appendStatusSegment(writer, &first, state.text(.camera), camera_text);
    }
    if (window_width >= 980.0) {
        try appendStatusSegment(writer, &first, state.text(.mode), mode_text);
    }
    if (window_width >= 1120.0) {
        try appendStatusSegment(writer, &first, state.text(.coordinate_space), space_text);
    }
}

pub fn statusPathCharacterBudget(window_width: f32) usize {
    if (window_width < 720.0) return 18;
    if (window_width < 960.0) return 28;
    if (window_width < 1280.0) return 42;
    return 60;
}

pub fn compactStatusPath(buffer: []u8, path: []const u8, max_chars: usize) []const u8 {
    if (path.len <= max_chars or buffer.len == 0) {
        return path;
    }

    const clamped_chars = @max(max_chars, 4);
    const tail_len = @min(path.len, clamped_chars - 3);
    const written = std.fmt.bufPrint(buffer, "...{s}", .{path[path.len - tail_len ..]}) catch return path;
    return written;
}

fn appendStatusSegment(writer: anytype, first: *bool, label: []const u8, value: []const u8) !void {
    if (!first.*) {
        try writer.writeAll("  |  ");
    }
    first.* = false;
    try writer.print("{s}: {s}", .{ label, value });
}
