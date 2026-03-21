const std = @import("std");
const engine = @import("guava");
const layout = @import("../layout.zig");

const ScriptResource = engine.assets.ScriptResource;
const ScriptLanguage = engine.script.ScriptLanguage;

pub const ScriptEditorState = struct {
    allocator: std.mem.Allocator,
    selected_script_handle: ?engine.handles.ScriptHandle = null,
    source_buffer: std.ArrayList(u8),
    original_source: []const u8 = "",
    is_modified: bool = false,
    cursor_line: usize = 1,
    cursor_column: usize = 1,
    selection_start: usize = 0,
    selection_end: usize = 0,
    find_buffer: [256]u8 = [_]u8{0} ** 256,
    replace_buffer: [256]u8 = [_]u8{0} ** 256,
    show_find_panel: bool = false,
    show_console: bool = true,
    console_output: std.ArrayList(u8),
    breakpoints: std.ArrayList(usize),
    current_debug_line: ?usize = null,
    is_debugging: bool = false,
    auto_save_enabled: bool = true,
    tab_size: usize = 4,
    show_line_numbers: bool = true,
    word_wrap: bool = false,

    pub fn init(allocator: std.mem.Allocator) ScriptEditorState {
        return .{
            .allocator = allocator,
            .source_buffer = std.ArrayList(u8).init(allocator),
            .console_output = std.ArrayList(u8).init(allocator),
            .breakpoints = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *ScriptEditorState) void {
        self.source_buffer.deinit();
        self.console_output.deinit();
        self.breakpoints.deinit();
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        self.* = undefined;
    }

    pub fn loadScript(self: *ScriptEditorState, resource: *const ScriptResource) !void {
        if (self.original_source.len > 0) {
            self.allocator.free(self.original_source);
        }
        self.original_source = try self.allocator.dupe(u8, resource.source);
        try self.source_buffer.resize(resource.source.len);
        @memcpy(self.source_buffer.items, resource.source);
        self.is_modified = false;
        self.cursor_line = 1;
        self.cursor_column = 1;
    }

    pub fn getSource(self: *const ScriptEditorState) []const u8 {
        return self.source_buffer.items;
    }

    pub fn insertText(self: *ScriptEditorState, pos: usize, text: []const u8) !void {
        try self.source_buffer.insertSlice(pos, text);
        self.is_modified = true;
    }

    pub fn deleteRange(self: *ScriptEditorState, start: usize, end: usize) void {
        if (start >= end or end > self.source_buffer.items.len) return;
        _ = self.source_buffer.orderedRemove(start);
        self.is_modified = true;
    }

    pub fn toggleBreakpoint(self: *ScriptEditorState, line: usize) !void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp == line) {
                _ = self.breakpoints.orderedRemove(i);
                return;
            }
        }
        try self.breakpoints.append(line);
    }

    pub fn hasBreakpoint(self: *const ScriptEditorState, line: usize) bool {
        for (self.breakpoints.items) |bp| {
            if (bp == line) return true;
        }
        return false;
    }

    pub fn appendConsole(self: *ScriptEditorState, text: []const u8) !void {
        try self.console_output.appendSlice(text);
        try self.console_output.append('\n');
    }

    pub fn clearConsole(self: *ScriptEditorState) void {
        self.console_output.clearRetainingCapacity();
    }
};

pub fn drawScriptEditor(
    state: *engine.AppState,
    layer_context: *engine.LayerContext,
    editor_state: *ScriptEditorState,
) void {
    _ = layer_context;

    if (engine.ui.ImGui.begin("Script Editor")) {
        defer engine.ui.ImGui.end();

        drawScriptToolbar(state, editor_state);

        engine.ui.ImGui.separator();

        const content_region = engine.ui.ImGui.contentRegionAvail();
        const editor_height = if (editor_state.show_console) content_region[1] * 0.7 else content_region[1];

        drawScriptSourceArea(state, editor_state, editor_height);

        if (editor_state.show_console) {
            engine.ui.ImGui.separator();
            drawConsolePanel(editor_state);
        }
    }
}

fn drawScriptToolbar(state: *engine.AppState, editor_state: *ScriptEditorState) void {
    _ = state;

    if (engine.ui.ImGui.button("New")) {
        editor_state.source_buffer.clearRetainingCapacity();
        editor_state.is_modified = false;
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Open")) {
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Save")) {
        editor_state.is_modified = false;
    }
    engine.ui.ImGui.sameLine();

    if (editor_state.is_modified) {
        engine.ui.ImGui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "*");
        engine.ui.ImGui.sameLine();
    }

    engine.ui.ImGui.text("Language:");
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.text("Zig");

    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.dummy(20.0, 1.0);
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Find")) {
        editor_state.show_find_panel = !editor_state.show_find_panel;
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button(if (editor_state.show_console) "Hide Console" else "Show Console")) {
        editor_state.show_console = !editor_state.show_console;
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button(if (editor_state.is_debugging) "Stop" else "Debug")) {
        editor_state.is_debugging = !editor_state.is_debugging;
    }
}

fn drawScriptSourceArea(state: *engine.AppState, editor_state: *ScriptEditorState, height: f32) void {
    _ = state;

    if (editor_state.show_find_panel) {
        drawFindPanel(editor_state);
        engine.ui.ImGui.separator();
    }

    if (engine.ui.ImGui.beginChild("source_area", -1.0, height, true)) {
        const line_count = countLines(editor_state.source_buffer.items);
        var line_buf: [16]u8 = undefined;

        const line_num_width = if (editor_state.show_line_numbers) 40.0 else 0.0;
        _ = line_num_width;

        for (1..line_count + 1) |line_num| {
            const is_breakpoint = editor_state.hasBreakpoint(line_num);
            const is_current_debug = editor_state.current_debug_line != null and editor_state.current_debug_line.? == line_num;

            if (editor_state.show_line_numbers) {
                engine.ui.ImGui.beginGroup();
                defer engine.ui.ImGui.endGroup();

                const line_str = std.fmt.bufPrint(&line_buf, "{d: >4}", .{line_num}) catch "";
                if (is_breakpoint) {
                    engine.ui.ImGui.pushStyleColor(.text, .{ 1.0, 0.0, 0.0, 1.0 });
                }
                engine.ui.ImGui.text(line_str);
                if (is_breakpoint) {
                    engine.ui.ImGui.popStyleColor(1);
                }
                engine.ui.ImGui.sameLine();
            }

            if (is_current_debug) {
                engine.ui.ImGui.pushStyleColor(.child_bg, .{ 0.2, 0.3, 0.5, 0.5 });
            }

            const line_text = getLine(editor_state.source_buffer.items, line_num);
            engine.ui.ImGui.textWrapped(line_text);

            if (is_current_debug) {
                engine.ui.ImGui.popStyleColor(1);
            }
        }
    }
    engine.ui.ImGui.endChild();

    if (engine.ui.ImGui.beginPopupContextWindow()) {
        if (engine.ui.ImGui.selectable("Toggle Breakpoint", false)) {
            editor_state.toggleBreakpoint(editor_state.cursor_line) catch {};
        }
        if (engine.ui.ImGui.selectable("Run to Cursor", false)) {
            editor_state.current_debug_line = editor_state.cursor_line;
        }
        engine.ui.ImGui.endPopup();
    }
}

fn drawFindPanel(editor_state: *ScriptEditorState) void {
    engine.ui.ImGui.text("Find:");
    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.inputText("##find", &editor_state.find_buffer, 256, .{}, null, null);
    engine.ui.ImGui.sameLine();

    engine.ui.ImGui.text("Replace:");
    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.inputText("##replace", &editor_state.replace_buffer, 256, .{}, null, null);
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Find Next")) {
        const find_str = std.mem.sliceTo(&editor_state.find_buffer, 0);
        if (std.mem.indexOf(u8, editor_state.source_buffer.items, find_str)) |pos| {
            _ = pos;
        }
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Replace")) {
    }
    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Replace All")) {
    }
}

fn drawConsolePanel(editor_state: *ScriptEditorState) void {
    if (engine.ui.ImGui.beginChild("console", -1.0, -1.0, true)) {
        engine.ui.ImGui.text("Console Output:");
        engine.ui.ImGui.separator();

        if (editor_state.console_output.items.len > 0) {
            engine.ui.ImGui.textWrapped(editor_state.console_output.items);
        } else {
            engine.ui.ImGui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No output");
        }
    }
    engine.ui.ImGui.endChild();

    if (engine.ui.ImGui.button("Clear")) {
        editor_state.clearConsole();
    }
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn getLine(text: []const u8, line_num: usize) []const u8 {
    if (line_num == 0) return "";

    var current_line: usize = 1;
    var line_start: usize = 0;

    for (text, 0..) |c, i| {
        if (current_line == line_num) {
            line_start = i;
            break;
        }
        if (c == '\n') {
            current_line += 1;
        }
    }

    if (current_line != line_num) return "";

    for (text[line_start..], 0..) |c, i| {
        if (c == '\n') {
            return text[line_start .. line_start + i];
        }
    }

    return text[line_start..];
}
