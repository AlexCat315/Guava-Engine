const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const SettingsCategory = @import("../../../core/state.zig").SettingsCategory;
const FpsDisplayMode = @import("../../../core/state.zig").FpsDisplayMode;
const preferences = @import("../../../core/preferences.zig");
const i18n = @import("../../../i18n/mod.zig");
const icon_cache = @import("../../icon_cache.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const theme = @import("../../theme.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

const settings_filter_buffer_size = @import("../../../core/state.zig").settings_filter_buffer_size;

fn drawSettingsCategoryItem(icon_texture: *const engine.rhi.Texture, label: []const u8, is_selected: bool) bool {
    const row_height: f32 = 26.0;
    const rounding: f32 = 4.0;
    const draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    const row_top = cursor[1];

    const avail = gui.contentRegionAvail();
    const row_width = avail[0];

    gui.dummy(row_width, row_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();

    const hovered = gui.isItemHovered();

    if (is_selected) {
        draw_list.addRectFilled(
            .{ item_min[0], item_min[1] + 1.0 },
            .{ item_max[0], item_max[1] - 1.0 },
            gui.getColorU32(.{ 0.16, 0.31, 0.35, 0.94 }),
            rounding,
            0,
        );
        draw_list.addRectFilled(
            .{ item_min[0], item_min[1] },
            .{ item_min[0] + 3.0, item_max[1] },
            gui.getColorU32(.{ 0.34, 0.78, 0.98, 1.0 }),
            2.0,
            0,
        );
    } else if (hovered) {
        draw_list.addRectFilled(
            .{ item_min[0], item_min[1] + 1.0 },
            .{ item_max[0], item_max[1] - 1.0 },
            gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.06 }),
            rounding,
            0,
        );
    }

    const icon_size: f32 = 16.0;
    const icon_x: f32 = item_min[0] + 8.0;
    const icon_y: f32 = row_top + (row_height - icon_size) * 0.5;
    gui.setCursorScreenPos(.{ icon_x, icon_y });
    gui.image(icon_texture, icon_size, icon_size);

    const text_x = icon_x + icon_size + 6.0;
    const text_y = row_top + (row_height - 14.0) * 0.5;
    const text_color = if (is_selected)
        gui.getColorU32(.{ 0.94, 0.97, 1.0, 1.0 })
    else if (hovered)
        gui.getColorU32(.{ 0.90, 0.93, 0.97, 1.0 })
    else
        gui.getColorU32(.{ 0.82, 0.86, 0.92, 1.0 });
    draw_list.addText(.{ text_x, text_y }, text_color, label);

    return hovered and gui.isMouseDoubleClicked(.left) == false and gui.isMouseDragging(.left) == false;
}

fn drawSettingsCategoryList(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const general_icon = ui_icons.paths.hierarchy.object;
    const interface_icon = ui_icons.paths.hierarchy.object;
    const editor_icon = ui_icons.paths.hierarchy.object;
    const viewport_icon = ui_icons.paths.hierarchy.camera;
    const shortcuts_icon = ui_icons.paths.hierarchy.object;
    const ai_icon = ui_icons.paths.hierarchy.vfx;
    const icon_tint = theme.Palette.hierarchy.active_icon;

    const categories = [_]struct {
        id: SettingsCategory,
        label: []const u8,
        icon_path: []const u8,
    }{
        .{ .id = .general, .label = state.text(.settings_general), .icon_path = general_icon },
        .{ .id = .interface, .label = state.text(.settings_interface), .icon_path = interface_icon },
        .{ .id = .editor, .label = state.text(.settings_editor), .icon_path = editor_icon },
        .{ .id = .viewport, .label = state.text(.settings_viewport), .icon_path = viewport_icon },
        .{ .id = .shortcuts, .label = state.text(.settings_shortcuts), .icon_path = shortcuts_icon },
        .{ .id = .ai, .label = state.text(.settings_ai), .icon_path = ai_icon },
    };

    for (categories) |category| {
        const is_selected = state.settings_category == category.id;
        const icon_texture = icon_cache.ensureIconTexture(
            state,
            layer_context,
            category.icon_path,
            16,
            16,
            icon_tint,
        ) catch continue;
        if (drawSettingsCategoryItem(icon_texture, category.label, is_selected)) {
            state.settings_category = category.id;
        }
    }
}

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
        drawSettingsCategoryList(state, layer_context);

        gui.tableNextColumn();

        // Right content area
        layout.beginSectionBody();
        defer layout.endSectionBody();

        switch (state.settings_category) {
            .general => try drawSettingsContentGeneral(state, layer_context),
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
