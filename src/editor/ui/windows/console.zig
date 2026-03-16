const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;

const max_entries = 256;
const max_scope_len = 48;
const max_message_len = 384;

pub const Entry = struct {
    level: std.log.Level,
    scope_len: usize = 0,
    message_len: usize = 0,
    scope: [max_scope_len]u8 = [_]u8{0} ** max_scope_len,
    message: [max_message_len]u8 = [_]u8{0} ** max_message_len,

    pub fn scopeText(self: *const Entry) []const u8 {
        return self.scope[0..self.scope_len];
    }

    pub fn messageText(self: *const Entry) []const u8 {
        return self.message[0..self.message_len];
    }
};

var g_mutex: std.Thread.Mutex = .{};
var g_entries: [max_entries]Entry = undefined;
var g_entry_count: usize = 0;
var g_entry_cursor: usize = 0;

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var scope_buffer: [max_scope_len]u8 = undefined;
    const scope_text = std.fmt.bufPrint(&scope_buffer, "{s}", .{@tagName(scope)}) catch "default";

    var message_buffer: [max_message_len]u8 = undefined;
    const message_text = std.fmt.bufPrint(&message_buffer, format, args) catch "log formatting failed";

    appendEntry(message_level, scope_text, message_text);

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.print("[{s}] {s}: {s}\n", .{ levelLabel(message_level), scope_text, message_text }) catch {};
    stderr.flush() catch {};
}

pub fn clear() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_entry_count = 0;
    g_entry_cursor = 0;
}

pub fn snapshot(buffer: []Entry) usize {
    g_mutex.lock();
    defer g_mutex.unlock();

    const count = @min(buffer.len, g_entry_count);
    if (count == 0) {
        return 0;
    }

    const start = if (g_entry_count < max_entries) 0 else g_entry_cursor;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        buffer[index] = g_entries[(start + index) % max_entries];
    }
    return count;
}

pub fn drawConsolePanel(state: *EditorState) !void {
    const width = engine.ui.ImGui.contentRegionAvail()[0];
    const clear_width = if (width >= 520.0) 82.0 else width;
    if (engine.ui.ImGui.buttonEx(state.text(.clear), clear_width, 0.0)) {
        clear();
    }
    if (width >= 520.0) {
        engine.ui.ImGui.sameLine();
    }

    const toggle_columns: usize = if (width >= 520.0)
        5
    else if (width >= 320.0)
        2
    else
        1;
    var toggle_index: usize = 0;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = engine.ui.ImGui.checkbox(state.text(.errors), &state.console_show_errors);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = engine.ui.ImGui.checkbox(state.text(.warnings), &state.console_show_warnings);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = engine.ui.ImGui.checkbox(state.text(.info), &state.console_show_info);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = engine.ui.ImGui.checkbox(state.text(.debug), &state.console_show_debug);
    toggle_index += 1;
    beginResponsiveToggle(toggle_index, toggle_columns);
    _ = engine.ui.ImGui.checkbox(state.text(.auto_scroll), &state.console_auto_scroll);
    engine.ui.ImGui.separator();

    _ = engine.ui.ImGui.beginChild("console_messages", 0.0, 0.0, true);
    defer engine.ui.ImGui.endChild();

    var snapshot_entries: [max_entries]Entry = undefined;
    const count = snapshot(snapshot_entries[0..]);
    for (snapshot_entries[0..count]) |entry| {
        if (!shouldDisplayEntry(state, entry.level)) {
            continue;
        }

        engine.ui.ImGui.pushStyleColor(.text, levelColor(entry.level));
        defer engine.ui.ImGui.popStyleColor(1);

        var line_buffer: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "[{s}] {s}: {s}",
            .{ levelLabel(entry.level), entry.scopeText(), entry.messageText() },
        );
        engine.ui.ImGui.textWrapped(line);
    }

    if (state.console_auto_scroll) {
        engine.ui.ImGui.setScrollHereY(1.0);
    }
}

fn beginResponsiveToggle(index: usize, columns: usize) void {
    if (index == 0 or columns == 0) {
        return;
    }
    if (index % columns == 0) {
        engine.ui.ImGui.dummy(0.0, 4.0);
    } else {
        engine.ui.ImGui.sameLine();
    }
}

fn appendEntry(level: std.log.Level, scope: []const u8, message: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    const slot = if (g_entry_count < max_entries) blk: {
        const value = g_entry_count;
        g_entry_count += 1;
        break :blk value;
    } else blk: {
        const value = g_entry_cursor;
        g_entry_cursor = (g_entry_cursor + 1) % max_entries;
        break :blk value;
    };

    var entry = Entry{ .level = level };
    entry.scope_len = @min(scope.len, entry.scope.len);
    entry.message_len = @min(message.len, entry.message.len);
    @memcpy(entry.scope[0..entry.scope_len], scope[0..entry.scope_len]);
    @memcpy(entry.message[0..entry.message_len], message[0..entry.message_len]);
    g_entries[slot] = entry;
}

fn shouldDisplayEntry(state: *const EditorState, level: std.log.Level) bool {
    return switch (level) {
        .err => state.console_show_errors,
        .warn => state.console_show_warnings,
        .info => state.console_show_info,
        .debug => state.console_show_debug,
    };
}

fn levelColor(level: std.log.Level) [4]f32 {
    return switch (level) {
        .err => .{ 0.96, 0.42, 0.37, 1.0 },
        .warn => .{ 0.98, 0.78, 0.36, 1.0 },
        .info => .{ 0.74, 0.84, 0.97, 1.0 },
        .debug => .{ 0.66, 0.70, 0.76, 1.0 },
    };
}

fn levelLabel(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERR",
        .warn => "WRN",
        .info => "INF",
        .debug => "DBG",
    };
}
