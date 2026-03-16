const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const camera = @import("../../interaction/camera.zig");

pub fn drawRenderSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .render_settings, "render_settings_popup");
    _ = engine.ui.ImGui.beginWindowFlags(title, engine.ui.ImGui.WindowFlags.no_docking);
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.text(state.text(.camera));
    if (engine.ui.ImGui.buttonEx(state.text(.editor_camera_mode), 140.0, 0.0) and !state.editor_camera_active) {
        camera.toggleCameraMode(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.scene_camera_mode), 140.0, 0.0) and state.editor_camera_active) {
        camera.toggleCameraMode(state, layer_context);
    }

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.perspective_view));
    if (engine.ui.ImGui.buttonEx(state.text(.perspective_view), 140.0, 0.0)) {
        camera.setViewPreset(state, layer_context, .perspective);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.top_view), 120.0, 0.0)) {
        camera.setViewPreset(state, layer_context, .top);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.side_view), 120.0, 0.0)) {
        camera.setViewPreset(state, layer_context, .side);
    }

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.render_mode));
    if (engine.ui.ImGui.buttonEx(state.text(.textured), 140.0, 0.0)) {
        state.viewport_render_mode = .textured;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.wireframe), 140.0, 0.0)) {
        state.viewport_render_mode = .wireframe;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.unlit), 120.0, 0.0)) {
        state.viewport_render_mode = .unlit;
    }

    engine.ui.ImGui.separator();
    _ = engine.ui.ImGui.checkbox(state.text(.show_grid), &state.viewport_show_grid);
    _ = engine.ui.ImGui.checkbox(state.text(.show_bones), &state.viewport_show_bones);
    _ = engine.ui.ImGui.checkbox(state.text(.show_collision), &state.viewport_show_collision);

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.coordinate_space));
    if (engine.ui.ImGui.buttonEx(state.text(.local_space), 140.0, 0.0)) {
        state.transform_space = .local;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.world_space), 140.0, 0.0)) {
        state.transform_space = .world;
    }

    engine.ui.ImGui.separator();
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    engine.ui.ImGui.labelText(state.text(.viewport_size), viewport_text);
}
