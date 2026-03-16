const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const i18n = @import("../../i18n/mod.zig");

pub fn drawSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .settings, "settings_popup");
    _ = engine.ui.ImGui.beginWindowFlags(title, engine.ui.ImGui.WindowFlags.no_docking);
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.labelText(state.text(.language), state.languageInfo().native_name);
    for (i18n.available_languages, 0..) |language, index| {
        const locale_info = i18n.locale(language);
        if (engine.ui.ImGui.button(locale_info.native_name)) {
            state.language = language;
        }
        if (index + 1 < i18n.available_languages.len) {
            engine.ui.ImGui.sameLine();
        }
    }

    if (engine.ui.ImGui.button(state.text(.reset_dock_layout))) {
        engine.ui.ImGui.resetDefaultLayout();
        state.dock_layout_initialized = true;
    }

    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    engine.ui.ImGui.labelText(state.text(.viewport_size), viewport_text);
    engine.ui.ImGui.text(state.text(.the_dock_layout_uses_stable_panel_ids_now_so_language_switching_no_longer_breaks_docking));
}
