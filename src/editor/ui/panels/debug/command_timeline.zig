const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const history = @import("../../../actions/history.zig");
const ui_icons = @import("../../icons.zig");

/// 在底部面板内绘制命令时间线内容（无窗口边框）
pub fn drawCommandTimelinePanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const total_history_commands = state.undo_stack.items.len + state.redo_stack.items.len;
    const available_entries = @min(total_history_commands, state.timeline_entries.items.len);
    const timeline_start_index = state.timeline_entries.items.len -| available_entries;
    const current_cursor = state.undo_stack.items.len;

    // 顶部工具栏：统计信息 + Hover Preview 开关
    {
        const available_w = gui.contentRegionAvail()[0];

        var summary_buffer: [160]u8 = undefined;
        const summary = try std.fmt.bufPrint(
            &summary_buffer,
            "条目: {d}   光标: {d}/{d}",
            .{ state.timeline_entries.items.len, current_cursor, total_history_commands },
        );
        gui.pushStyleColor(.text, .{ 0.55, 0.60, 0.68, 1.0 });
        gui.text(summary);
        gui.popStyleColor(1);

        if (available_w > 440.0) {
            gui.sameLine();
            gui.dummy(available_w - 440.0, 1.0);
            gui.sameLine();
        } else {
            gui.dummy(0.0, 2.0);
        }

        if (gui.checkbox("悬停预览+点击确认##timeline_hover", &state.timeline_hover_preview_confirm_mode)) {
            if (!state.timeline_hover_preview_confirm_mode) {
                state.timeline_preview_sequence = null;
                state.timeline_preview_target_cursor = null;
            }
        }
    }

    // 若有悬停目标：显示确认条
    if (state.timeline_hover_preview_confirm_mode) {
        const preview_cursor_opt = state.timeline_preview_target_cursor;
        const has_valid_preview = preview_cursor_opt != null and
            preview_cursor_opt.? > 0 and
            preview_cursor_opt.? <= available_entries and
            preview_cursor_opt.? != current_cursor;
        if (has_valid_preview) {
            const preview_cursor = preview_cursor_opt.?;
            const preview_entry = state.timeline_entries.items[timeline_start_index + preview_cursor - 1];
            var preview_buffer: [224]u8 = undefined;
            const preview_text = std.fmt.bufPrint(
                &preview_buffer,
                "预览: #{d} {s}",
                .{ preview_entry.sequence, preview_entry.label },
            ) catch "预览中...";
            gui.pushStyleColor(.text, .{ 0.80, 0.95, 1.0, 1.0 });
            gui.text(preview_text);
            gui.popStyleColor(1);
            gui.sameLine();
            gui.pushStyleColor(.button, .{ 0.13, 0.50, 0.36, 0.90 });
            gui.pushStyleColor(.button_hovered, .{ 0.15, 0.62, 0.43, 1.0 });
            gui.pushStyleColor(.button_active, .{ 0.10, 0.40, 0.28, 1.0 });
            if (gui.buttonEx("确认时间穿越##timeline_confirm", 140.0, 0.0)) {
                try history.timeTravelToCursor(state, layer_context, preview_cursor);
                state.timeline_preview_sequence = null;
                state.timeline_preview_target_cursor = null;
            }
            gui.popStyleColor(3);
        } else {
            gui.pushStyleColor(.text, .{ 0.50, 0.52, 0.56, 1.0 });
            gui.text("悬停节点以预览，再点击「确认时间穿越」。");
            gui.popStyleColor(1);
        }
    }

    gui.separator();

    if (available_entries == 0) {
        gui.dummy(0.0, 6.0);
        gui.pushStyleColor(.text, .{ 0.40, 0.42, 0.46, 1.0 });
        gui.text("暂无命令记录。创建实体、调整属性后此处将显示操作历史。");
        gui.popStyleColor(1);
        return;
    }

    // 横向节点轨道：填充剩余高度
    const lane_height = gui.contentRegionAvail()[1] - 2.0;
    if (!gui.beginChild("command_timeline_lane##bottom", 0.0, lane_height, true)) {
        return;
    }
    defer gui.endChild();

    gui.pushStyleVarVec2(.item_spacing, .{ 4.0, 0.0 });
    defer gui.popStyleVar(1);

    for (state.timeline_entries.items[timeline_start_index..], 0..) |entry, index| {
        if (index > 0) {
            gui.sameLine();
            gui.pushStyleColor(.text, .{ 0.35, 0.38, 0.44, 1.0 });
            gui.text("→");
            gui.popStyleColor(1);
            gui.sameLine();
        }

        const palette = switch (entry.source) {
            .human => ui_icons.ButtonPalette{
                .button = .{ 0.16, 0.34, 0.66, 0.88 },
                .hovered = .{ 0.20, 0.41, 0.77, 0.96 },
                .active = .{ 0.13, 0.28, 0.54, 1.0 },
            },
            .ai => ui_icons.ButtonPalette{
                .button = .{ 0.47, 0.28, 0.72, 0.88 },
                .hovered = .{ 0.56, 0.33, 0.84, 0.96 },
                .active = .{ 0.38, 0.22, 0.60, 1.0 },
            },
        };

        const node_cursor = index + 1;
        const is_current = node_cursor == current_cursor;
        const is_preview = state.timeline_hover_preview_confirm_mode and
            state.timeline_preview_target_cursor != null and
            state.timeline_preview_target_cursor.? == node_cursor and
            node_cursor != current_cursor;

        var node_label_buffer: [192]u8 = undefined;
        const node_label = std.fmt.bufPrint(
            &node_label_buffer,
            "#{d} {s}",
            .{ entry.sequence, entry.label },
        ) catch entry.label;

        gui.pushStyleColor(.button, palette.button);
        gui.pushStyleColor(.button_hovered, palette.hovered);
        gui.pushStyleColor(.button_active, palette.active);
        if (is_current) {
            gui.pushStyleColor(.text, .{ 0.98, 0.98, 0.78, 1.0 });
        } else if (is_preview) {
            gui.pushStyleColor(.text, .{ 0.80, 0.95, 1.0, 1.0 });
        }
        gui.pushStyleVarVec2(.frame_padding, .{ 10.0, 6.0 });
        gui.pushStyleVarFloat(.frame_rounding, 7.0);
        defer {
            gui.popStyleVar(2);
            gui.popStyleColor(if (is_current or is_preview) 4 else 3);
        }

        const clicked = gui.buttonEx(node_label, 0.0, 0.0);
        if (state.timeline_hover_preview_confirm_mode and gui.isItemHovered() and node_cursor != current_cursor) {
            state.timeline_preview_sequence = entry.sequence;
            state.timeline_preview_target_cursor = node_cursor;
        }

        if (clicked) {
            if (state.timeline_hover_preview_confirm_mode) {
                if (node_cursor == current_cursor) {
                    state.timeline_preview_sequence = null;
                    state.timeline_preview_target_cursor = null;
                } else {
                    state.timeline_preview_sequence = entry.sequence;
                    state.timeline_preview_target_cursor = node_cursor;
                }
            } else {
                try history.timeTravelToCursor(state, layer_context, node_cursor);
            }
        }

        if (gui.isItemHovered()) {
            var tip_buffer: [320]u8 = undefined;
            const tip_text = std.fmt.bufPrint(
                &tip_buffer,
                "[{s}] {s}\n{s}",
                .{ @tagName(entry.source), entry.command_kind, entry.detail },
            ) catch entry.detail;
            gui.setTooltip(tip_text);
        }
    }
}
