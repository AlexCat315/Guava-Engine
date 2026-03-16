const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const i18n = @import("../../i18n/mod.zig");
const icon_cache = @import("../icon_cache.zig");
const ui_icons = @import("../icons.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

pub fn drawSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .settings, "settings_popup");
    _ = engine.ui.ImGui.beginWindowFlags(title, engine.ui.ImGui.WindowFlags.no_docking);
    defer engine.ui.ImGui.endWindow();

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
            if (index % language_columns == 0) {
                engine.ui.ImGui.dummy(0.0, 6.0);
            } else {
                engine.ui.ImGui.sameLine();
            }
        }
        if (engine.ui.ImGui.buttonEx(locale_info.native_name, language_button_width, 0.0)) {
            state.language = language;
        }
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    if (engine.ui.ImGui.buttonEx(state.text(.reset_dock_layout), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
        engine.ui.ImGui.resetDefaultLayout();
        state.dock_layout_initialized = true;
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
