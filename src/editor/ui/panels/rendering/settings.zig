const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const SettingsCategory = @import("../../../core/state.zig").SettingsCategory;
const FpsDisplayMode = @import("../../../core/state.zig").FpsDisplayMode;
const i18n = @import("../../../i18n/mod.zig");
const icon_cache = @import("../../icon_cache.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

const settings_filter_buffer_size = @import("../../../core/state.zig").settings_filter_buffer_size;

fn drawSettingsCategoryList(state: *EditorState) void {
    const categories = [_]struct {
        id: SettingsCategory,
        label: []const u8,
    }{
        .{ .id = .general, .label = state.text(.settings_general) },
        .{ .id = .interface, .label = state.text(.settings_interface) },
        .{ .id = .editor, .label = state.text(.settings_editor) },
        .{ .id = .viewport, .label = state.text(.settings_viewport) },
        .{ .id = .shortcuts, .label = state.text(.settings_shortcuts) },
        .{ .id = .ai, .label = state.text(.settings_ai) },
    };

    for (categories) |category| {
        const is_selected = state.settings_category == category.id;
        gui.pushStyleColor(.button, if (is_selected) .{ 0.13, 0.45, 0.28, 0.82 } else .{ 0.0, 0.0, 0.0, 0.0 });
        gui.pushStyleColor(.button_hovered, if (is_selected) .{ 0.18, 0.55, 0.35, 0.92 } else .{ 0.20, 0.22, 0.25, 0.65 });
        gui.pushStyleColor(.button_active, if (is_selected) .{ 0.10, 0.35, 0.22, 0.96 } else .{ 0.15, 0.16, 0.18, 0.75 });
        defer gui.popStyleColor(3);

        if (gui.buttonEx(category.label, -1.0, 0.0)) {
            state.settings_category = category.id;
        }
    }
}

fn drawSettingsContentGeneral(state: *EditorState) void {
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
        }
    }

    gui.dummy(0.0, 6.0);
    _ = gui.checkbox(state.text(.viewport_debug_overlay), &state.viewport_debug_overlay);
}

fn drawSettingsChoiceButton(label: []const u8, active: bool, width: f32) bool {
    gui.pushStyleColor(.button, if (active) .{ 0.13, 0.45, 0.28, 0.82 } else .{ 0.16, 0.17, 0.19, 0.54 });
    gui.pushStyleColor(.button_hovered, if (active) .{ 0.18, 0.55, 0.35, 0.92 } else .{ 0.21, 0.23, 0.27, 0.74 });
    gui.pushStyleColor(.button_active, if (active) .{ 0.10, 0.35, 0.22, 0.96 } else .{ 0.18, 0.20, 0.24, 0.86 });
    defer gui.popStyleColor(3);
    return gui.buttonEx(label, width, 0.0);
}

fn drawSettingsContentInterface(_: *EditorState) void {
    gui.text("Interface settings coming soon...");
}

fn drawSettingsContentEditor(_: *EditorState) void {
    gui.text("Editor settings coming soon...");
}

fn drawSettingsContentViewport(state: *EditorState, layer_context: *engine.core.LayerContext) void {
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

fn drawSettingsContentShortcuts(_: *EditorState) void {
    gui.text("Shortcuts settings coming soon...");
}

fn drawSettingsContentAi(_: *EditorState) void {
    gui.text("AI settings coming soon...");
}

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

    // Row 0: Top toolbar (search + advanced) spanning all columns
    if (gui.beginTable("##settings_main", 2)) {
        defer gui.endTable();

        // Column 0: Left navigation sidebar
        gui.tableSetupColumn("##sidebar", false, 160.0);
        // Column 1: Right content area
        gui.tableSetupColumn("##content", true, 1.0);

        // ── Top bar row ──────────────────────────────────────────────
        gui.tableNextRow();
        gui.tableNextColumn();

        // Search input in sidebar column
        gui.pushStyleColor(.frame_bg, .{ 0.12, 0.13, 0.15, 0.65 });
        _ = gui.inputTextWithHint("##settings_filter", state.text(.settings_filter), state.settings_filter_buffer[0..settings_filter_buffer_size]);
        gui.popStyleColor(1);

        gui.tableNextColumn();

        // Advanced toggle in content column
        _ = gui.checkbox(state.text(.settings_advanced), &state.settings_advanced_mode);

        // ── Body row ─────────────────────────────────────────────────
        gui.tableNextRow();
        gui.tableNextColumn();

        // Left navigation
        gui.dummy(0.0, 8.0);
        drawSettingsCategoryList(state);

        gui.tableNextColumn();

        // Right content area
        layout.beginSectionBody();
        defer layout.endSectionBody();

        switch (state.settings_category) {
            .general => drawSettingsContentGeneral(state),
            .interface => drawSettingsContentInterface(state),
            .editor => drawSettingsContentEditor(state),
            .viewport => drawSettingsContentViewport(state, layer_context),
            .shortcuts => drawSettingsContentShortcuts(state),
            .ai => drawSettingsContentAi(state),
            .advanced => {
                if (state.settings_advanced_mode) {
                    gui.text("Advanced settings enabled.");
                } else {
                    gui.text("Enable advanced mode to see more settings.");
                }
            },
        }
    }
}
