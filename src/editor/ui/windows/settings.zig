const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const i18n = @import("../../i18n/mod.zig");
const icon_cache = @import("../icon_cache.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

pub fn drawSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .settings, "settings_popup");
    var open = state.settings_open;
    _ = engine.ui.ImGui.beginWindowFlagsOpen(title, &open, engine.ui.ImGui.WindowFlags.no_docking);
    state.settings_open = open;
    defer engine.ui.ImGui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    engine.ui.ImGui.labelText(state.text(.language), state.languageInfo().native_name);
    const content_width = engine.ui.ImGui.contentRegionAvail()[0];
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
        if (engine.ui.ImGui.buttonEx(locale_info.native_name, language_button_width, 0.0)) {
            state.language = language;
        }
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    if (engine.ui.ImGui.buttonEx(state.text(.reset_dock_layout), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
        layout.resetDockLayout(state);
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    engine.ui.ImGui.separator();
    engine.ui.ImGui.dummy(0.0, 6.0);
    engine.ui.ImGui.text(state.text(.layout_templates));
    _ = engine.ui.ImGui.inputTextWithHint(
        "##layout_template_name",
        state.text(.template_name),
        state.layout_template_name_buffer[0..],
    );
    if (engine.ui.ImGui.buttonEx(state.text(.save_as_template), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
        const template_name = std.mem.sliceTo(state.layout_template_name_buffer[0..], 0);
        if (try layout.saveUserLayoutTemplate(state, template_name)) {
            @memset(state.layout_template_name_buffer[0..], 0);
        }
    }

    try layout.ensureLayoutTemplatesLoaded(state);
    if (state.layout_templates.items.len == 0) {
        engine.ui.ImGui.textWrapped(state.text(.no_saved_layout_templates));
    } else {
        for (state.layout_templates.items, 0..) |entry, index| {
            engine.ui.ImGui.pushIdU64(index);
            defer engine.ui.ImGui.popId();

            engine.ui.ImGui.text(entry.name);
            engine.ui.ImGui.sameLineEx(160.0, 10.0);

            var load_label_buffer: [96]u8 = undefined;
            const load_label = try std.fmt.bufPrint(&load_label_buffer, "{s}##load_template_{d}", .{ state.text(.load_template), index });
            if (engine.ui.ImGui.buttonEx(load_label, 92.0, 0.0)) {
                _ = layout.loadUserLayoutTemplate(state, entry.path);
            }
            engine.ui.ImGui.sameLine();

            var delete_label_buffer: [96]u8 = undefined;
            const delete_label = try std.fmt.bufPrint(&delete_label_buffer, "{s}##delete_template_{d}", .{ state.text(.delete_template), index });
            if (engine.ui.ImGui.buttonEx(delete_label, 92.0, 0.0)) {
                _ = try layout.deleteUserLayoutTemplate(state, index);
                break;
            }
        }
    }

    const debug_icon = try icon_cache.ensureIconTexture(state, layer_context, debug_icon_path, 28, 28, debug_icon_tint);
    engine.ui.ImGui.text("SVG icon preview");
    engine.ui.ImGui.image(debug_icon, 28.0, 28.0);

    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    engine.ui.ImGui.labelText(state.text(.viewport_size), viewport_text);
    engine.ui.ImGui.textWrapped(state.text(.the_dock_layout_uses_stable_panel_ids_now_so_language_switching_no_longer_breaks_docking));
}
