const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const scene_hierarchy = @import("windows/scene_hierarchy.zig");
const inspector = @import("windows/inspector.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const menu_bar = @import("menu_bar.zig");
const settings = @import("windows/settings.zig");

pub fn drawViewportToolbar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport_toolbar, "viewport_toolbar_panel");
    _ = engine.ui.ImGui.beginWindowFlags(title, engine.ui.ImGui.WindowFlags.no_title_bar | engine.ui.ImGui.WindowFlags.no_collapse | engine.ui.ImGui.WindowFlags.no_scrollbar);
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.labelText(state.text(.camera), if (state.editor_camera_active) state.text(.editor_camera_mode) else state.text(.scene_camera_mode));
    var mode_buffer: [32]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buffer, "{s}", .{
        switch (state.manipulation_mode) {
            .none => state.text(.idle),
            .translate => state.text(.move),
            .rotate => state.text(.rotate),
            .scale => state.text(.scale),
        },
    });
    engine.ui.ImGui.labelText(state.text(.mode), mode_text);

    if (engine.ui.ImGui.button(state.text(.toggle_camera))) {
        camera.toggleCameraMode(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.focus))) {
        camera.focusSelection(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.move))) {
        try manipulation.beginManipulation(state, layer_context, .translate);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.rotate))) {
        try manipulation.beginManipulation(state, layer_context, .rotate);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.scale))) {
        try manipulation.beginManipulation(state, layer_context, .scale);
    }

    if (engine.ui.ImGui.button(state.text(.empty))) {
        try history.spawnEmptyEntity(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.camera))) {
        try history.spawnCameraEntity(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.cube))) {
        try history.spawnPrimitive(state, layer_context, .cube);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.sphere))) {
        try history.spawnPrimitive(state, layer_context, .sphere);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.light))) {
        try history.spawnPointLight(state, layer_context);
    }

    if (content_browser.selectedAsset(state)) |entry| {
        engine.ui.ImGui.labelText(state.text(.asset), entry.name);
        if ((entry.kind == .model or entry.kind == .scene) and engine.ui.ImGui.button(state.text(.instantiate_slash_load))) {
            try content_browser.instantiateSelectedAsset(state, layer_context);
        }
    } else {
        engine.ui.ImGui.text(state.text(.select_a_model_or_scene_in_content_browser_to_instantiate_slash_load_it));
    }
}

pub fn drawViewportWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport, "viewport_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    const content_size = engine.ui.ImGui.contentRegionAvail();
    state.viewport_origin = engine.ui.ImGui.cursorScreenPos();
    state.viewport_extent = .{
        @max(content_size[0], 0.0),
        @max(content_size[1], 0.0),
    };
    state.viewport_hovered = false;
    state.viewport_focused = engine.ui.ImGui.isWindowFocused();
    state.viewport_has_image = false;

    const drawable_size = utils.viewportDrawableSize(layer_context.window, state.viewport_extent);
    try layer_context.renderer.setSceneViewportSize(drawable_size[0], drawable_size[1]);

    if (layer_context.renderer.sceneViewportTexture()) |texture| {
        const image_size = .{
            @max(state.viewport_extent[0], 8.0),
            @max(state.viewport_extent[1], 8.0),
        };
        engine.ui.ImGui.image(texture, image_size[0], image_size[1]);
        state.viewport_hovered = engine.ui.ImGui.isItemHovered();
        state.viewport_has_image = true;
    } else {
        engine.ui.ImGui.text(state.text(.viewport_target_is_not_ready_yet));
    }
}

pub fn drawStatsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .stats, "stats_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    const runtime = layer_context.renderer.runtimeInfo();
    const summary = layer_context.world.summary();
    const fps = if (layer_context.delta_seconds > 0.0001) 1.0 / layer_context.delta_seconds else 0.0;

    var fps_buffer: [64]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
    engine.ui.ImGui.labelText(state.text(.fps), fps_text);
    engine.ui.ImGui.labelText(state.text(.backend), engine.render.graphicsApiName(layer_context.renderer.backendApi()));
    engine.ui.ImGui.labelText(state.text(.device), runtime.deviceName());

    var draw_size_buffer: [64]u8 = undefined;
    const draw_size_text = try std.fmt.bufPrint(
        &draw_size_buffer,
        "{d} x {d}",
        .{ runtime.drawable_width, runtime.drawable_height },
    );
    engine.ui.ImGui.labelText(state.text(.drawable), draw_size_text);

    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_size_buffer: [64]u8 = undefined;
    const viewport_size_text = try std.fmt.bufPrint(
        &viewport_size_buffer,
        "{d} x {d}",
        .{ viewport_size[0], viewport_size[1] },
    );
    engine.ui.ImGui.labelText(state.text(.viewport), viewport_size_text);

    var entities_buffer: [32]u8 = undefined;
    const entities_text = try std.fmt.bufPrint(&entities_buffer, "{d}", .{summary.entity_count});
    engine.ui.ImGui.labelText(state.text(.entities), entities_text);

    var meshes_buffer: [32]u8 = undefined;
    const meshes_text = try std.fmt.bufPrint(&meshes_buffer, "{d}", .{summary.mesh_count});
    engine.ui.ImGui.labelText(state.text(.meshes), meshes_text);

    var lights_buffer: [32]u8 = undefined;
    const lights_text = try std.fmt.bufPrint(&lights_buffer, "{d}", .{summary.light_count});
    engine.ui.ImGui.labelText(state.text(.lights), lights_text);

    var cameras_buffer: [32]u8 = undefined;
    const cameras_text = try std.fmt.bufPrint(&cameras_buffer, "{d}", .{summary.camera_count});
    engine.ui.ImGui.labelText(state.text(.cameras), cameras_text);
}

pub fn handleViewportSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;
    if (!state.viewport_has_image or !state.viewport_hovered or !input.wasMousePressed(.left) or input.modifiers.alt) {
        return;
    }
    if (state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return;
    }

    const local_x = input.mouse_position[0] - state.viewport_origin[0];
    const local_y = input.mouse_position[1] - state.viewport_origin[1];
    if (local_x < 0.0 or local_y < 0.0 or local_x > state.viewport_extent[0] or local_y > state.viewport_extent[1]) {
        return;
    }

    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0) {
        return;
    }

    const normalized_x = std.math.clamp(local_x / state.viewport_extent[0], 0.0, 1.0);
    const normalized_y = std.math.clamp(local_y / state.viewport_extent[1], 0.0, 1.0);
    const pixel_x = @as(u32, @intFromFloat(std.math.clamp(
        normalized_x * @as(f32, @floatFromInt(viewport_size[0])),
        0.0,
        @as(f32, @floatFromInt(viewport_size[0] - 1)),
    )));
    const pixel_y = @as(u32, @intFromFloat(std.math.clamp(
        normalized_y * @as(f32, @floatFromInt(viewport_size[1])),
        0.0,
        @as(f32, @floatFromInt(viewport_size[1] - 1)),
    )));

    try layer_context.renderer.requestSelectionReadback(
        pixel_x,
        pixel_y,
        if (input.modifiers.shift or input.modifiers.ctrl or input.modifiers.super) .toggle else .replace,
    );
}

pub fn drawEditorUi(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try menu_bar.drawMenuBar(state, layer_context);
    try drawViewportToolbar(state, layer_context);
    try drawViewportWindow(state, layer_context);
    try drawStatsWindow(state, layer_context);
    try scene_hierarchy.drawSceneWindow(state, layer_context);
    try inspector.drawInspectorWindow(state, layer_context);
    try content_browser.drawContentBrowser(state, layer_context);
    try asset_preview.drawAssetPreviewWindow(state, layer_context);
    if (state.settings_open) {
        try settings.drawSettingsWindow(state, layer_context);
    }
}
