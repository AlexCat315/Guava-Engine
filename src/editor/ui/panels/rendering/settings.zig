const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const SettingsCategory = @import("../../../core/state.zig").SettingsCategory;
const SettingsTab = @import("../../../core/state.zig").SettingsTab;
const FpsDisplayMode = @import("../../../core/state.zig").FpsDisplayMode;
const MeshShortcutBinding = @import("../../../core/state.zig").MeshShortcutBinding;
const MeshEditShortcutConfig = @import("../../../core/state.zig").MeshEditShortcutConfig;
const preferences = @import("../../../core/preferences.zig");
const i18n = @import("../../../i18n/mod.zig");
const icon_cache = @import("../../icon_cache.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const theme = @import("../../theme.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

const settings_filter_buffer_size = @import("../../../core/state.zig").settings_filter_buffer_size;

// ── Sidebar: Collapsible section header ──────────────────────────────

fn drawSectionHeader(label: []const u8, is_open: *bool) void {
    const row_height: f32 = 24.0;
    const draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    const row_top = cursor[1];
    const avail = gui.contentRegionAvail();
    const row_width = @max(avail[0], 100.0);

    gui.dummy(row_width, row_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();
    const hovered = gui.isItemHovered();

    if (hovered) {
        draw_list.addRectFilled(
            .{ item_min[0], item_min[1] },
            .{ item_max[0], item_max[1] },
            gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.04 }),
            0.0,
            0,
        );
    }

    // Arrow ▼ or ▶
    const arrow_x = item_min[0] + 8.0;
    const arrow_y = row_top + (row_height - 12.0) * 0.5;
    const arrow_text: []const u8 = if (is_open.*) "\xE2\x96\xBC" else "\xE2\x96\xB6";
    const arrow_color = gui.getColorU32(.{ 0.60, 0.63, 0.68, 1.0 });
    draw_list.addText(.{ arrow_x, arrow_y }, arrow_color, arrow_text);

    // Section label (bold appearance via brighter color)
    const text_x = arrow_x + 16.0;
    const text_y = row_top + (row_height - 14.0) * 0.5;
    const text_color = gui.getColorU32(.{ 0.88, 0.91, 0.95, 1.0 });
    draw_list.addText(.{ text_x, text_y }, text_color, label);

    if (hovered and gui.isItemClicked()) {
        is_open.* = !is_open.*;
    }
}

// ── Sidebar: Child category item (indented) ──────────────────────────

fn drawCategoryChildItem(label: []const u8, is_selected: bool) bool {
    const row_height: f32 = 26.0;
    const rounding: f32 = 4.0;
    const draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    const row_top = cursor[1];
    const avail = gui.contentRegionAvail();
    const row_width = @max(avail[0], 100.0);

    gui.dummy(row_width, row_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();
    const hovered = gui.isItemHovered();

    if (is_selected) {
        draw_list.addRectFilled(
            .{ item_min[0] + 4.0, item_min[1] + 1.0 },
            .{ item_max[0] - 4.0, item_max[1] - 1.0 },
            gui.getColorU32(.{ 0.17, 0.33, 0.50, 0.72 }),
            rounding,
            0,
        );
    } else if (hovered) {
        draw_list.addRectFilled(
            .{ item_min[0] + 4.0, item_min[1] + 1.0 },
            .{ item_max[0] - 4.0, item_max[1] - 1.0 },
            gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.06 }),
            rounding,
            0,
        );
    }

    const indent: f32 = 28.0;
    const text_y = row_top + (row_height - 14.0) * 0.5;
    const text_color = if (is_selected)
        gui.getColorU32(.{ 0.94, 0.97, 1.0, 1.0 })
    else if (hovered)
        gui.getColorU32(.{ 0.88, 0.91, 0.95, 1.0 })
    else
        gui.getColorU32(.{ 0.72, 0.76, 0.82, 1.0 });
    draw_list.addText(.{ item_min[0] + indent, text_y }, text_color, label);

    return hovered and gui.isItemClicked();
}

// ── Sidebar: Full tree layout ────────────────────────────────────────

fn drawSettingsCategoryTree(state: *EditorState) void {
    // Section: 常规 (General)
    drawSectionHeader(state.text(.settings_section_general), &state.settings_section_general_open);
    if (state.settings_section_general_open) {
        if (drawCategoryChildItem(state.text(.settings_general), state.settings_category == .general)) {
            state.settings_category = .general;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: 界面 (Interface)
    drawSectionHeader(state.text(.settings_section_interface), &state.settings_section_interface_open);
    if (state.settings_section_interface_open) {
        if (drawCategoryChildItem(state.text(.settings_editor), state.settings_category == .editor)) {
            state.settings_category = .editor;
        }
        if (drawCategoryChildItem(state.text(.settings_inspector), state.settings_category == .inspector)) {
            state.settings_category = .inspector;
        }
        if (drawCategoryChildItem(state.text(.settings_theme), state.settings_category == .theme)) {
            state.settings_category = .theme;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: 视口 (Viewport)
    drawSectionHeader(state.text(.settings_section_viewport), &state.settings_section_viewport_open);
    if (state.settings_section_viewport_open) {
        if (drawCategoryChildItem(state.text(.settings_rendering), state.settings_category == .rendering)) {
            state.settings_category = .rendering;
        }
        if (drawCategoryChildItem(state.text(.settings_camera), state.settings_category == .camera)) {
            state.settings_category = .camera;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: AI
    drawSectionHeader(state.text(.settings_section_ai), &state.settings_section_ai_open);
    if (state.settings_section_ai_open) {
        if (drawCategoryChildItem(state.text(.settings_assistant), state.settings_category == .assistant)) {
            state.settings_category = .assistant;
        }
    }
}

// ── Content: per-category settings ───────────────────────────────────

fn drawSettingsContentGeneral(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    gui.labelText(state.text(.language), state.languageInfo().native_name);
    const content_width = gui.contentRegionAvail()[0];
    const language_count = i18n.available_languages.len;
    const language_columns: usize = if (content_width >= 88.0 * @as(f32, @floatFromInt(language_count)) + 8.0 * @as(f32, @floatFromInt(language_count -| 1)))
        language_count
    else if (content_width >= 184.0)
        @min(language_count, 2)
    else
        1;
    const language_button_width = @max(
        (content_width - 8.0 * @as(f32, @floatFromInt(language_columns -| 1))) / @as(f32, @floatFromInt(language_columns)),
        1.0,
    );
    for (i18n.available_languages, 0..) |language, index| {
        const locale_info = i18n.locale(language);
        if (index > 0) {
            layout.advanceResponsiveRow(index, language_columns);
        }
        if (gui.buttonEx(locale_info.native_name, language_button_width, 0.0)) {
            state.language = language;
            preferences.saveEditorPreferences(state) catch |err| {
                std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
            };
        }
    }

    gui.dummy(0.0, 6.0);
    gui.separator();
    gui.dummy(0.0, 6.0);
    gui.text(state.text(.fps));
    const fps_options = [_]struct {
        label: []const u8,
        mode: FpsDisplayMode,
    }{
        .{ .label = state.text(.viewport), .mode = .viewport },
        .{ .label = state.text(.none), .mode = .none },
    };
    const fps_columns = layout.responsiveButtonColumns(fps_options.len, 92.0);
    const fps_button_width = layout.responsiveButtonWidth(fps_columns);
    for (fps_options, 0..) |option, index| {
        if (index > 0) {
            layout.advanceResponsiveRow(index, fps_columns);
        }
        if (drawSettingsChoiceButton(option.label, state.fps_display_mode == option.mode, fps_button_width)) {
            state.fps_display_mode = option.mode;
            state.fps_overlay_last_sample_time = -1.0;
            preferences.saveEditorPreferences(state) catch |err| {
                std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
            };
        }
    }

    gui.dummy(0.0, 6.0);
    var vsync_enabled = state.vsync_enabled;
    if (gui.checkbox(state.text(.vsync), &vsync_enabled)) {
        try layer_context.renderer.setVSyncEnabled(vsync_enabled);
        state.vsync_enabled = layer_context.renderer.vsyncEnabled();
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }
}

fn drawSettingsChoiceButton(label: []const u8, active: bool, width: f32) bool {
    gui.pushStyleColor(.button, if (active) .{ 0.13, 0.45, 0.28, 0.82 } else .{ 0.16, 0.17, 0.19, 0.54 });
    gui.pushStyleColor(.button_hovered, if (active) .{ 0.18, 0.55, 0.35, 0.92 } else .{ 0.21, 0.23, 0.27, 0.74 });
    gui.pushStyleColor(.button_active, if (active) .{ 0.10, 0.35, 0.22, 0.96 } else .{ 0.18, 0.20, 0.24, 0.86 });
    defer gui.popStyleColor(3);
    return gui.buttonEx(label, width, 0.0);
}

fn drawSettingsContentEditor(_: *EditorState) void {
    gui.text("Editor settings coming soon...");
}

fn drawSettingsContentInspector(_: *EditorState) void {
    gui.text("Inspector settings coming soon...");
}

fn drawSettingsContentTheme(_: *EditorState) void {
    gui.text("Theme settings coming soon...");
}

fn drawSettingsContentRendering(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] }) catch unreachable;
    gui.labelText(state.text(.viewport_size), viewport_text);

    gui.dummy(0.0, 6.0);
    gui.separator();
    gui.dummy(0.0, 6.0);

    const debug_icon = icon_cache.ensureIconTexture(state, layer_context, debug_icon_path, 28, 28, debug_icon_tint) catch return;
    gui.text("SVG icon preview");
    gui.image(debug_icon, 28.0, 28.0);
}

fn drawSettingsContentCamera(_: *EditorState) void {
    gui.text("Camera settings coming soon...");
}

const mesh_shortcut_keys = [_]engine.core.InputKey{
    .e,
    .i,
    .b,
    .r,
    .m,
    .d,
    .p,
    .n,
    .period,
    .f,
    .q,
    .w,
    .a,
    .s,
    .g,
    .t,
    .x,
    .y,
    .z,
    .one,
    .two,
    .three,
    .tab,
    .delete,
    .backspace,
};

fn shortcutKeyLabel(key: engine.core.InputKey) []const u8 {
    return switch (key) {
        .tab => "Tab",
        .delete => "Delete",
        .backspace => "Backspace",
        .one => "1",
        .two => "2",
        .three => "3",
        .period => ".",
        else => @tagName(key),
    };
}

fn drawShortcutBindingControl(id: []const u8, binding: *MeshShortcutBinding) bool {
    var changed = false;
    if (gui.beginCombo(id, shortcutKeyLabel(binding.key))) {
        defer gui.endCombo();
        for (mesh_shortcut_keys) |candidate| {
            const selected = binding.key == candidate;
            if (gui.selectable(shortcutKeyLabel(candidate), selected, false, 0.0, 0.0)) {
                binding.key = candidate;
                changed = true;
            }
        }
    }
    return changed;
}

fn drawShortcutModifierToggle(id: []const u8, value: *bool) bool {
    return gui.checkbox(id, value);
}

fn drawShortcutRow(action_label: []const u8, id_suffix: []const u8, binding: *MeshShortcutBinding) bool {
    var changed = false;
    gui.tableNextRow();

    gui.tableNextColumn();
    gui.text(action_label);

    gui.tableNextColumn();
    var key_id_buf: [64]u8 = undefined;
    const key_id = std.fmt.bufPrint(&key_id_buf, "##key_{s}", .{id_suffix}) catch "##key_fallback";
    changed = drawShortcutBindingControl(key_id, binding) or changed;

    gui.tableNextColumn();
    var ctrl_id_buf: [64]u8 = undefined;
    const ctrl_id = std.fmt.bufPrint(&ctrl_id_buf, "##ctrl_{s}", .{id_suffix}) catch "##ctrl_fallback";
    changed = drawShortcutModifierToggle(ctrl_id, &binding.ctrl) or changed;

    gui.tableNextColumn();
    var shift_id_buf: [64]u8 = undefined;
    const shift_id = std.fmt.bufPrint(&shift_id_buf, "##shift_{s}", .{id_suffix}) catch "##shift_fallback";
    changed = drawShortcutModifierToggle(shift_id, &binding.shift) or changed;

    gui.tableNextColumn();
    var alt_id_buf: [64]u8 = undefined;
    const alt_id = std.fmt.bufPrint(&alt_id_buf, "##alt_{s}", .{id_suffix}) catch "##alt_fallback";
    changed = drawShortcutModifierToggle(alt_id, &binding.alt) or changed;

    return changed;
}

fn drawSettingsContentShortcuts(state: *EditorState) void {
    gui.text("Mesh Edit Modal Controls");
    gui.dummy(0.0, 4.0);

    var drag_sensitivity = state.mesh_modal_drag_sensitivity;
    if (gui.sliderFloat("Mouse Drag Sensitivity", &drag_sensitivity, 0.0005, 0.05)) {
        state.mesh_modal_drag_sensitivity = drag_sensitivity;
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    var fine_scale = state.mesh_modal_fine_scale;
    if (gui.sliderFloat("Shift Fine Scale", &fine_scale, 0.05, 1.0)) {
        state.mesh_modal_fine_scale = fine_scale;
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    gui.text("Mesh Edit Shortcuts");
    gui.textWrapped("These bindings are live. Changes are applied immediately and persisted to editor preferences.");
    gui.dummy(0.0, 6.0);

    var changed = false;
    if (gui.beginTable("##mesh_edit_shortcuts_table", 5)) {
        defer gui.endTable();
        gui.tableSetupColumn("Action", true, 0.0);
        gui.tableSetupColumn("Key", false, 120.0);
        gui.tableSetupColumn("Ctrl", false, 56.0);
        gui.tableSetupColumn("Shift", false, 56.0);
        gui.tableSetupColumn("Alt", false, 56.0);
        gui.tableHeadersRow();

        changed = drawShortcutRow("Extrude", "extrude", &state.mesh_edit_shortcuts.extrude) or changed;
        changed = drawShortcutRow("Inset", "inset", &state.mesh_edit_shortcuts.inset) or changed;
        changed = drawShortcutRow("Bevel", "bevel", &state.mesh_edit_shortcuts.bevel) or changed;
        changed = drawShortcutRow("Loop Cut", "loop_cut", &state.mesh_edit_shortcuts.loop_cut) or changed;
        changed = drawShortcutRow("Merge", "merge", &state.mesh_edit_shortcuts.merge) or changed;
        changed = drawShortcutRow("Duplicate Faces", "duplicate", &state.mesh_edit_shortcuts.duplicate) or changed;
        changed = drawShortcutRow("Separate Faces", "separate", &state.mesh_edit_shortcuts.separate) or changed;
        changed = drawShortcutRow("Recalculate Normals", "recalc_normals", &state.mesh_edit_shortcuts.recalc_normals) or changed;
        changed = drawShortcutRow("Pivot To Selection", "pivot_to_selection", &state.mesh_edit_shortcuts.pivot_to_selection) or changed;
    }

    gui.dummy(0.0, 6.0);
    if (gui.buttonEx("Reset Mesh Edit Shortcuts", 0.0, 0.0)) {
        state.mesh_edit_shortcuts = MeshEditShortcutConfig{};
        changed = true;
    }

    if (changed) {
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);
    gui.text("Modal Controls");
    gui.labelText("Mouse", "Adjust value (Loop Cut: cursor position maps to slide factor)");
    gui.labelText("Shift", "Fine adjustment while dragging");
    gui.labelText("LMB", "Confirm modal operation");
    gui.labelText("RMB / Esc", "Cancel and revert modal operation");
}

fn drawSettingsContentAssistant(_: *EditorState) void {
    gui.text("AI Assistant settings coming soon...");
}

fn drawSettingsContentForCategory(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    switch (state.settings_category) {
        .general => try drawSettingsContentGeneral(state, layer_context),
        .interface => drawSettingsContentEditor(state),
        .editor => drawSettingsContentEditor(state),
        .inspector => drawSettingsContentInspector(state),
        .theme => drawSettingsContentTheme(state),
        .viewport => drawSettingsContentRendering(state, layer_context),
        .rendering => drawSettingsContentRendering(state, layer_context),
        .camera => drawSettingsContentCamera(state),
        .shortcuts => drawSettingsContentShortcuts(state),
        .ai => drawSettingsContentAssistant(state),
        .assistant => drawSettingsContentAssistant(state),
        .advanced => {
            if (state.settings_advanced_mode) {
                gui.text("Advanced settings enabled.");
            } else {
                gui.text("Enable advanced mode to see more settings.");
            }
        },
    }
}

// ── Main window ──────────────────────────────────────────────────────

pub fn drawSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .settings, "settings_popup");
    var open = state.settings_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.settings_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("settings_popup");

    gui.pushStyleVarFloat(.frame_rounding, 4.0);
    gui.pushStyleVarVec2(.item_spacing, .{ 8.0, 4.0 });
    defer gui.popStyleVar(2);

    // ── Top tabs: 常规 | 快捷键 ──────────────────────────────────────
    if (gui.beginTabBar("##settings_tabs")) {
        defer gui.endTabBar();

        if (gui.beginTabItem(state.text(.settings_general))) {
            state.settings_tab = .general;
            gui.endTabItem();
        }
        if (gui.beginTabItem(state.text(.settings_shortcuts))) {
            state.settings_tab = .shortcuts;
            gui.endTabItem();
        }
    }

    // ── Search bar + advanced toggle (full width) ────────────────────
    {
        const search_avail = gui.contentRegionAvail()[0];
        const toggle_width: f32 = 120.0;
        const search_width = @max(search_avail - toggle_width - 16.0, 100.0);
        gui.pushStyleColor(.frame_bg, .{ 0.12, 0.13, 0.15, 0.65 });
        gui.setNextItemWidth(search_width);
        _ = gui.inputTextWithHint("##settings_filter", state.text(.settings_filter), state.settings_filter_buffer[0..settings_filter_buffer_size]);
        gui.popStyleColor(1);
        gui.sameLineEx(0.0, 8.0);
        _ = gui.checkbox(state.text(.settings_advanced), &state.settings_advanced_mode);
    }

    gui.dummy(0.0, 2.0);

    if (state.settings_tab == .shortcuts) {
        // Shortcuts tab: direct content, no sidebar
        layout.beginSectionBody();
        defer layout.endSectionBody();
        drawSettingsContentShortcuts(state);
        return;
    }

    // ── Body: sidebar tree + separator + content ─────────────────────
    const avail = gui.contentRegionAvail();
    const sidebar_width: f32 = 180.0;
    const separator_width: f32 = 1.0;
    const content_width = @max(avail[0] - sidebar_width - separator_width - 16.0, 100.0);
    const body_height = @max(avail[1], 100.0);

    // Left sidebar (scrollable collapsible tree)
    gui.pushStyleColor(.child_bg, .{ 0.08, 0.09, 0.10, 0.70 });
    gui.pushStyleVarVec2(.window_padding, .{ 0.0, 4.0 });
    _ = gui.beginChild("##settings_sidebar", sidebar_width, body_height, false);
    gui.popStyleVar(1);
    gui.popStyleColor(1);
    drawSettingsCategoryTree(state);
    gui.endChild();

    gui.sameLineEx(0.0, 0.0);

    // Vertical separator line
    {
        const draw_list = gui.getWindowDrawList();
        const cursor = gui.cursorScreenPos();
        draw_list.addLine(
            .{ cursor[0], cursor[1] },
            .{ cursor[0], cursor[1] + body_height },
            gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.08 }),
            separator_width,
        );
    }
    gui.dummy(separator_width + 8.0, body_height);
    gui.sameLineEx(0.0, 8.0);

    // Right content area (scrollable)
    _ = gui.beginChild("##settings_content", content_width, body_height, false);
    layout.beginSectionBody();
    defer layout.endSectionBody();
    defer gui.endChild();

    try drawSettingsContentForCategory(state, layer_context);
}
