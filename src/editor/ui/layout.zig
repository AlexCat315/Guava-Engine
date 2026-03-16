const std = @import("std");
const engine = @import("guava");

pub const default_section_padding: f32 = 10.0;
pub const default_item_spacing: f32 = 8.0;
pub const default_row_spacing: f32 = 6.0;

pub fn beginSectionBody() void {
    engine.ui.ImGui.indent(default_section_padding);
}

pub fn endSectionBody() void {
    engine.ui.ImGui.unindent(default_section_padding);
}

pub fn responsiveButtonColumns(button_count: usize, min_button_width: f32) usize {
    var columns = button_count;
    while (columns > 1) : (columns -= 1) {
        const required_width =
            min_button_width * @as(f32, @floatFromInt(columns)) +
            default_item_spacing * @as(f32, @floatFromInt(columns - 1));
        if (engine.ui.ImGui.contentRegionAvail()[0] >= required_width) {
            return columns;
        }
    }
    return 1;
}

pub fn responsiveButtonWidth(columns: usize) f32 {
    const total_spacing = default_item_spacing * @as(f32, @floatFromInt(columns -| 1));
    return @max(
        (engine.ui.ImGui.contentRegionAvail()[0] - total_spacing) / @as(f32, @floatFromInt(columns)),
        1.0,
    );
}

pub fn advanceResponsiveRow(index: usize, columns: usize) void {
    if (columns == 0 or index == 0) {
        return;
    }
    if (index % columns == 0) {
        engine.ui.ImGui.dummy(0.0, default_row_spacing);
    } else {
        engine.ui.ImGui.sameLine();
    }
}

pub fn drawResponsivePropertyLabel(label: []const u8, min_control_width: f32) bool {
    const total_width = engine.ui.ImGui.contentRegionAvail()[0];
    const label_width = std.math.clamp(total_width * 0.34, 86.0, 142.0);
    engine.ui.ImGui.alignTextToFramePadding();
    engine.ui.ImGui.text(label);
    if (total_width < label_width + min_control_width) {
        return false;
    }
    engine.ui.ImGui.sameLineEx(label_width, default_item_spacing);
    return true;
}

pub fn beginInspectorPropertyTable(id: []const u8, label_width_ratio: f32) bool {
    const available_width = engine.ui.ImGui.contentRegionAvail()[0];
    const label_width = available_width * label_width_ratio;
    _ = label_width;
    return engine.ui.ImGui.beginTable(id, 2, .{}, available_width, 0.0);
}

pub fn endInspectorPropertyTable() void {
    engine.ui.ImGui.endTable();
}

pub fn drawInspectorPropertyRow(label: []const u8, label_color: ?[4]f32) void {
    engine.ui.ImGui.tableNextRow();
    engine.ui.ImGui.tableNextColumn();
    if (label_color) |color| {
        engine.ui.ImGui.pushStyleColor(.text, color);
        defer engine.ui.ImGui.popStyleColor(1);
    }
    engine.ui.ImGui.alignTextToFramePadding();
    engine.ui.ImGui.text(label);
    engine.ui.ImGui.tableNextColumn();
    engine.ui.ImGui.setNextItemWidth(-1.0);
}
