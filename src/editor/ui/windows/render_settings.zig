const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const camera = @import("../../interaction/camera.zig");
const layout = @import("../layout.zig");

pub fn drawRenderSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .render_settings, "render_settings_popup");
    var open = state.render_settings_open;
    _ = engine.ui.ImGui.beginWindowFlagsOpen(title, &open, engine.ui.ImGui.WindowFlags.no_docking);
    state.render_settings_open = open;
    defer engine.ui.ImGui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    engine.ui.ImGui.text(state.text(.camera));
    switch (drawButtonRow2(state.text(.editor_camera_mode), state.text(.scene_camera_mode), 112.0)) {
        .first => if (!state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        },
        .second => if (state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        },
        .third => {},
        .none => {},
    }

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.perspective_view));
    switch (drawButtonRow3(state.text(.perspective_view), state.text(.top_view), state.text(.side_view), 92.0)) {
        .first => camera.setViewPreset(state, layer_context, .perspective),
        .second => camera.setViewPreset(state, layer_context, .top),
        .third => camera.setViewPreset(state, layer_context, .side),
        .none => {},
    }

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.render_mode));
    switch (drawButtonRow3(state.text(.textured), state.text(.wireframe), state.text(.unlit), 92.0)) {
        .first => state.viewport_render_mode = .textured,
        .second => state.viewport_render_mode = .wireframe,
        .third => state.viewport_render_mode = .unlit,
        .none => {},
    }

    engine.ui.ImGui.separator();
    _ = engine.ui.ImGui.checkbox(state.text(.show_grid), &state.viewport_show_grid);
    _ = engine.ui.ImGui.checkbox(state.text(.show_bones), &state.viewport_show_bones);
    _ = engine.ui.ImGui.checkbox(state.text(.show_collision), &state.viewport_show_collision);

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.exposure));
    _ = engine.ui.ImGui.checkbox(state.text(.manual_exposure), &state.viewport_exposure_enabled);
    var exposure_value = state.viewport_exposure;
    if (engine.ui.ImGui.dragFloat("##viewport_exposure", &exposure_value, 0.01, 0.1, 8.0)) {
        state.viewport_exposure = exposure_value;
    }
    var exposure_buffer: [32]u8 = undefined;
    const exposure_text = try std.fmt.bufPrint(&exposure_buffer, "{d:.2}x", .{state.viewport_exposure});
    engine.ui.ImGui.labelText(state.text(.exposure), exposure_text);

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.bloom));
    _ = engine.ui.ImGui.checkbox(state.text(.enable_bloom), &state.viewport_bloom_enabled);
    var bloom_threshold = state.viewport_bloom_threshold;
    if (engine.ui.ImGui.dragFloat("##viewport_bloom_threshold", &bloom_threshold, 0.01, 0.1, 8.0)) {
        state.viewport_bloom_threshold = bloom_threshold;
    }
    var bloom_threshold_buffer: [32]u8 = undefined;
    const bloom_threshold_text = try std.fmt.bufPrint(&bloom_threshold_buffer, "{d:.2}", .{state.viewport_bloom_threshold});
    engine.ui.ImGui.labelText(state.text(.bloom_threshold), bloom_threshold_text);
    var bloom_intensity = state.viewport_bloom_intensity;
    if (engine.ui.ImGui.dragFloat("##viewport_bloom_intensity", &bloom_intensity, 0.01, 0.0, 4.0)) {
        state.viewport_bloom_intensity = bloom_intensity;
    }
    var bloom_intensity_buffer: [32]u8 = undefined;
    const bloom_intensity_text = try std.fmt.bufPrint(&bloom_intensity_buffer, "{d:.2}x", .{state.viewport_bloom_intensity});
    engine.ui.ImGui.labelText(state.text(.bloom_intensity), bloom_intensity_text);

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.color_grading));
    _ = engine.ui.ImGui.checkbox(state.text(.enable_color_grading), &state.viewport_color_grading_enabled);
    var color_grading_saturation = state.viewport_color_grading_saturation;
    if (engine.ui.ImGui.dragFloat("##viewport_color_grading_saturation", &color_grading_saturation, 0.01, 0.0, 2.0)) {
        state.viewport_color_grading_saturation = color_grading_saturation;
    }
    var saturation_buffer: [32]u8 = undefined;
    const saturation_text = try std.fmt.bufPrint(&saturation_buffer, "{d:.2}x", .{state.viewport_color_grading_saturation});
    engine.ui.ImGui.labelText(state.text(.saturation), saturation_text);
    var color_grading_contrast = state.viewport_color_grading_contrast;
    if (engine.ui.ImGui.dragFloat("##viewport_color_grading_contrast", &color_grading_contrast, 0.01, 0.5, 2.0)) {
        state.viewport_color_grading_contrast = color_grading_contrast;
    }
    var contrast_buffer: [32]u8 = undefined;
    const contrast_text = try std.fmt.bufPrint(&contrast_buffer, "{d:.2}x", .{state.viewport_color_grading_contrast});
    engine.ui.ImGui.labelText(state.text(.contrast), contrast_text);
    var color_grading_gamma = state.viewport_color_grading_gamma;
    if (engine.ui.ImGui.dragFloat("##viewport_color_grading_gamma", &color_grading_gamma, 0.01, 0.5, 2.0)) {
        state.viewport_color_grading_gamma = color_grading_gamma;
    }
    var gamma_buffer: [32]u8 = undefined;
    const gamma_text = try std.fmt.bufPrint(&gamma_buffer, "{d:.2}x", .{state.viewport_color_grading_gamma});
    engine.ui.ImGui.labelText(state.text(.gamma), gamma_text);

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text(state.text(.coordinate_space));
    switch (drawButtonRow2(state.text(.local_space), state.text(.world_space), 112.0)) {
        .first => state.transform_space = .local,
        .second => state.transform_space = .world,
        .third => {},
        .none => {},
    }

    engine.ui.ImGui.separator();
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    engine.ui.ImGui.labelText(state.text(.viewport_size), viewport_text);
}

const ButtonRowResult = enum {
    none,
    first,
    second,
    third,
};

fn drawButtonRow2(first: []const u8, second: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(2, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (engine.ui.ImGui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (engine.ui.ImGui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    return .none;
}

fn drawButtonRow3(first: []const u8, second: []const u8, third: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(3, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (engine.ui.ImGui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (engine.ui.ImGui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    layout.advanceResponsiveRow(2, columns);
    if (engine.ui.ImGui.buttonEx(third, width, 0.0)) {
        return .third;
    }
    return .none;
}
