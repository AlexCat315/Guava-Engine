const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const camera = @import("../../../interaction/camera.zig");
const layout = @import("../../layout.zig");

pub fn drawRenderSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .render_settings, "render_settings_popup");
    var open = state.render_settings_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.render_settings_open = open;
    defer gui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    gui.text(state.text(.camera));
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

    gui.separator();
    gui.text(state.text(.perspective_view));
    switch (drawButtonRow3(state.text(.perspective_view), state.text(.top_view), state.text(.side_view), 92.0)) {
        .first => camera.setViewPreset(state, layer_context, .perspective),
        .second => camera.setViewPreset(state, layer_context, .top),
        .third => camera.setViewPreset(state, layer_context, .side),
        .none => {},
    }

    gui.separator();
    gui.text(state.text(.render_mode));
    switch (drawButtonRow3(state.text(.textured), state.text(.wireframe), state.text(.unlit), 92.0)) {
        .first => state.viewport_render_mode = .textured,
        .second => state.viewport_render_mode = .wireframe,
        .third => state.viewport_render_mode = .unlit,
        .none => {},
    }

    gui.separator();
    gui.text("Path Tracer");

    // Quality preset combo
    drawPtQualityPresetCombo(state);

    var pt_samples: i32 = @intCast(state.viewport_path_trace_samples);
    if (gui.dragInt("##pt_samples", &pt_samples, 1.0, 1, 64)) {
        state.viewport_path_trace_samples = @intCast(std.math.clamp(pt_samples, 1, 64));
    }
    var pt_samples_buf: [32]u8 = undefined;
    const pt_samples_text = try std.fmt.bufPrint(&pt_samples_buf, "{d}", .{state.viewport_path_trace_samples});
    gui.labelText("Samples", pt_samples_text);

    var pt_bounces: i32 = @intCast(state.viewport_path_trace_bounces);
    if (gui.dragInt("##pt_bounces", &pt_bounces, 1.0, 1, 8)) {
        state.viewport_path_trace_bounces = @intCast(std.math.clamp(pt_bounces, 1, 8));
    }
    var pt_bounces_buf: [32]u8 = undefined;
    const pt_bounces_text = try std.fmt.bufPrint(&pt_bounces_buf, "{d}", .{state.viewport_path_trace_bounces});
    gui.labelText("Bounces", pt_bounces_text);

    var pt_scale = state.viewport_path_trace_resolution_scale;
    if (gui.dragFloat("##pt_resolution_scale", &pt_scale, 0.01, 0.25, 1.0)) {
        state.viewport_path_trace_resolution_scale = std.math.clamp(pt_scale, 0.25, 1.0);
    }
    var pt_scale_buf: [32]u8 = undefined;
    const pt_scale_text = try std.fmt.bufPrint(&pt_scale_buf, "{d:.2}x", .{state.viewport_path_trace_resolution_scale});
    gui.labelText("Resolution", pt_scale_text);

    gui.separator();
    _ = gui.checkbox(state.text(.show_grid), &state.viewport_show_grid);
    _ = gui.checkbox(state.text(.show_bones), &state.viewport_show_bones);
    _ = gui.checkbox(state.text(.show_collision), &state.viewport_show_collision);

    gui.separator();
    gui.text(state.text(.coordinate_space));
    switch (drawButtonRow2(state.text(.local_space), state.text(.world_space), 112.0)) {
        .first => state.transform_space = .local,
        .second => state.transform_space = .world,
        .third => {},
        .none => {},
    }

    gui.separator();
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    gui.labelText(state.text(.viewport_size), viewport_text);
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
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    return .none;
}

fn drawButtonRow3(first: []const u8, second: []const u8, third: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(3, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    layout.advanceResponsiveRow(2, columns);
    if (gui.buttonEx(third, width, 0.0)) {
        return .third;
    }
    return .none;
}

const PtQualityPreset = enum {
    preview,
    low,
    medium,
    high,
    ultra,
};

fn ptQualityPresetLabel(preset: PtQualityPreset) []const u8 {
    return switch (preset) {
        .preview => "Preview",
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .ultra => "Ultra",
    };
}

fn detectCurrentPtPreset(state: *const EditorState) ?PtQualityPreset {
    const s = state.viewport_path_trace_samples;
    const b = state.viewport_path_trace_bounces;
    const r = state.viewport_path_trace_resolution_scale;
    if (s == 1 and b == 1 and r == 0.5) return .preview;
    if (s == 4 and b == 2 and r == 0.75) return .low;
    if (s == 8 and b == 3 and r == 1.0) return .medium;
    if (s == 16 and b == 4 and r == 1.0) return .high;
    if (s == 32 and b == 6 and r == 1.0) return .ultra;
    return null;
}

fn applyPtPreset(state: *EditorState, preset: PtQualityPreset) void {
    switch (preset) {
        .preview => {
            state.viewport_path_trace_samples = 1;
            state.viewport_path_trace_bounces = 1;
            state.viewport_path_trace_resolution_scale = 0.5;
        },
        .low => {
            state.viewport_path_trace_samples = 4;
            state.viewport_path_trace_bounces = 2;
            state.viewport_path_trace_resolution_scale = 0.75;
        },
        .medium => {
            state.viewport_path_trace_samples = 8;
            state.viewport_path_trace_bounces = 3;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
        .high => {
            state.viewport_path_trace_samples = 16;
            state.viewport_path_trace_bounces = 4;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
        .ultra => {
            state.viewport_path_trace_samples = 32;
            state.viewport_path_trace_bounces = 6;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
    }
}

fn drawPtQualityPresetCombo(state: *EditorState) void {
    const current = detectCurrentPtPreset(state);
    const preview_label = if (current) |p| ptQualityPresetLabel(p) else "Custom";
    if (!gui.beginCombo("Quality##pt_quality", preview_label)) {
        return;
    }
    defer gui.endCombo();

    const presets = [_]PtQualityPreset{ .preview, .low, .medium, .high, .ultra };
    for (presets) |preset| {
        const selected = if (current) |c| c == preset else false;
        if (gui.selectable(ptQualityPresetLabel(preset), selected, false, 0.0, 0.0)) {
            applyPtPreset(state, preset);
        }
    }
}
