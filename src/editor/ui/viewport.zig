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
const menu_bar = @import("menu_bar.zig");
const render_settings = @import("windows/render_settings.zig");
const settings = @import("windows/settings.zig");
const ui_icons = @import("icons.zig");
const PlaybackState = @import("../core/state.zig").PlaybackState;
const HierarchyCategory = @import("../core/state.zig").HierarchyCategory;

fn drawToolbarIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    active: bool,
) !bool {
    return ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        20.0,
        .{ 235, 239, 245, 255 },
        if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle,
    );
}

fn drawPlaybackButton(label: []const u8, width: f32, palette: [3][4]f32) bool {
    engine.ui.ImGui.pushStyleColor(.button, palette[0]);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette[1]);
    engine.ui.ImGui.pushStyleColor(.button_active, palette[2]);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, 10.0);
    defer {
        engine.ui.ImGui.popStyleVar(1);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.buttonEx(label, width, 30.0);
}

fn setPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext, playback_state: PlaybackState) void {
    state.playback_state = playback_state;
    layer_context.playback_controller.setState(playback_state);
}

fn stepPlayback(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.playback_state = .paused;
    layer_context.playback_controller.requestStep();
}

pub fn drawGlobalToolbarWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .global_toolbar, "global_toolbar_panel");
    _ = engine.ui.ImGui.beginWindowFlags(title, engine.ui.ImGui.WindowFlags.no_title_bar | engine.ui.ImGui.WindowFlags.no_collapse | engine.ui.ImGui.WindowFlags.no_scrollbar);
    defer engine.ui.ImGui.endWindow();

    state.playback_state = layer_context.playback_controller.state;

    if (try drawToolbarIconButton(state, layer_context, "toolbar_select", ui_icons.paths.toolbar.select, state.manipulation_mode == .none)) {
        try manipulation.selectTool(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_move", ui_icons.paths.toolbar.move, state.manipulation_mode == .translate)) {
        try manipulation.beginManipulation(state, layer_context, .translate);
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_rotate", ui_icons.paths.toolbar.rotate, state.manipulation_mode == .rotate)) {
        try manipulation.beginManipulation(state, layer_context, .rotate);
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_scale", ui_icons.paths.toolbar.scale, state.manipulation_mode == .scale)) {
        try manipulation.beginManipulation(state, layer_context, .scale);
    }

    const center_group_width: f32 = 398.0;
    const right_group_width: f32 = 430.0;
    const center_leading_gap = @max((engine.ui.ImGui.contentRegionAvail()[0] - center_group_width - right_group_width) * 0.5, 16.0);
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.dummy(center_leading_gap, 1.0);
    engine.ui.ImGui.sameLine();

    const playing_palette = if (state.playback_state == .playing)
        [3][4]f32{
            .{ 0.20, 0.59, 0.31, 1.0 },
            .{ 0.24, 0.68, 0.36, 1.0 },
            .{ 0.17, 0.50, 0.26, 1.0 },
        }
    else
        [3][4]f32{
            .{ 0.16, 0.42, 0.23, 1.0 },
            .{ 0.19, 0.49, 0.27, 1.0 },
            .{ 0.13, 0.34, 0.18, 1.0 },
        };
    var run_label_buffer: [32]u8 = undefined;
    const run_label = try std.fmt.bufPrint(&run_label_buffer, "▶ {s}", .{state.text(.run)});
    if (drawPlaybackButton(run_label, 124.0, playing_palette)) {
        setPlaybackState(state, layer_context, .playing);
    }
    engine.ui.ImGui.sameLine();
    const paused_palette = if (state.playback_state == .paused)
        [3][4]f32{
            .{ 0.69, 0.42, 0.17, 1.0 },
            .{ 0.79, 0.49, 0.21, 1.0 },
            .{ 0.56, 0.33, 0.13, 1.0 },
        }
    else
        [3][4]f32{
            .{ 0.48, 0.31, 0.14, 1.0 },
            .{ 0.57, 0.37, 0.17, 1.0 },
            .{ 0.39, 0.24, 0.10, 1.0 },
        };
    var pause_label_buffer: [32]u8 = undefined;
    const pause_label = try std.fmt.bufPrint(&pause_label_buffer, "⏸ {s}", .{state.text(.pause)});
    if (drawPlaybackButton(pause_label, 124.0, paused_palette)) {
        setPlaybackState(state, layer_context, .paused);
    }
    engine.ui.ImGui.sameLine();
    var step_label_buffer: [32]u8 = undefined;
    const step_label = try std.fmt.bufPrint(&step_label_buffer, "⏭ {s}", .{state.text(.step)});
    if (drawPlaybackButton(step_label, 124.0, .{
        .{ 0.29, 0.32, 0.37, 1.0 },
        .{ 0.34, 0.38, 0.44, 1.0 },
        .{ 0.23, 0.26, 0.30, 1.0 },
    })) {
        stepPlayback(state, layer_context);
    }

    const right_gap = @max(engine.ui.ImGui.contentRegionAvail()[0] - right_group_width, 16.0);
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.dummy(right_gap, 1.0);
    engine.ui.ImGui.sameLine();

    if (try ui_icons.drawIconButton(
        state,
        layer_context,
        "toolbar_settings",
        ui_icons.paths.toolbar.settings,
        20.0,
        .{ 235, 239, 245, 255 },
        if (state.render_settings_open) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle,
    )) {
        state.render_settings_open = !state.render_settings_open;
    }
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(176.0);
    _ = engine.ui.ImGui.inputText(state.text(.hierarchy_filter), state.hierarchy_filter_buffer[0..]);
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), 102.0, 0.0)) {
        state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(
        switch (state.transform_space) {
            .local => state.text(.local_space),
            .world => state.text(.world_space),
        },
        88.0,
        0.0,
    )) {
        state.transform_space = switch (state.transform_space) {
            .local => .world,
            .world => .local,
        };
    }
}

pub fn drawViewportWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport, "viewport_panel");
    _ = engine.ui.ImGui.beginWindowFlags(
        title,
        engine.ui.ImGui.WindowFlags.no_title_bar | engine.ui.ImGui.WindowFlags.no_collapse | engine.ui.ImGui.WindowFlags.no_scrollbar,
    );
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
        try drawViewportOverlayControls(state, layer_context);
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

pub fn drawStatusBarWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const height = 30.0;
    engine.ui.ImGui.setNextWindowPos(.{ 0.0, @as(f32, @floatFromInt(layer_context.window.logical_height)) - height });
    engine.ui.ImGui.setNextWindowSize(.{ @as(f32, @floatFromInt(layer_context.window.logical_width)), height });
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .status_bar, "status_bar_panel");
    _ = engine.ui.ImGui.beginWindowFlags(
        title,
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_collapse |
            engine.ui.ImGui.WindowFlags.no_scrollbar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_docking,
    );
    defer engine.ui.ImGui.endWindow();

    const fps = if (layer_context.delta_seconds > 0.0001) 1.0 / layer_context.delta_seconds else 0.0;
    const selection_count = layer_context.renderer.selectedEntities().len;
    const save_status = if (history.hasUnsavedChanges(state)) state.text(.unsaved) else state.text(.saved);
    const mode_text = switch (state.manipulation_mode) {
        .none => state.text(.select),
        .translate => state.text(.move),
        .rotate => state.text(.rotate),
        .scale => state.text(.scale),
    };
    const camera_text = if (state.editor_camera_active) state.text(.editor_camera_mode) else state.text(.scene_camera_mode);
    const space_text = switch (state.transform_space) {
        .local => state.text(.local_space),
        .world => state.text(.world_space),
    };
    const backend_text = engine.render.graphicsApiName(layer_context.renderer.backendApi());
    const memory_mb = @as(f32, @floatFromInt(utils.estimatedWorldMemoryBytes(layer_context.world))) / (1024.0 * 1024.0);

    var path_buffer: [320]u8 = undefined;
    const selected_path = if (layer_context.renderer.selectedEntity()) |selected|
        utils.entityPath(&path_buffer, layer_context.world, selected) catch "/"
    else
        "/";

    var status_buffer: [768]u8 = undefined;
    const status_text = try std.fmt.bufPrint(
        &status_buffer,
        "{s}: {d}    {s}: {d:.1}    {s}: {s}    {s}: {d:.1} MB    {s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}",
        .{
            state.text(.selection_count),
            selection_count,
            state.text(.fps),
            fps,
            state.text(.backend),
            backend_text,
            state.text(.memory),
            memory_mb,
            state.text(.selected_path),
            selected_path,
            state.text(.save_status),
            save_status,
            state.text(.camera),
            camera_text,
            state.text(.mode),
            mode_text,
            state.text(.coordinate_space),
            space_text,
        },
    );
    engine.ui.ImGui.text(status_text);
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
    syncViewportState(state, layer_context);
    try menu_bar.drawMenuBar(state, layer_context);
    try drawGlobalToolbarWindow(state, layer_context);
    try drawViewportWindow(state, layer_context);
    try drawStatusBarWindow(state, layer_context);
    try scene_hierarchy.drawSceneWindow(state, layer_context);
    try inspector.drawInspectorWindow(state, layer_context);
    try content_browser.drawContentBrowser(state, layer_context);
    if (state.render_settings_open) {
        try render_settings.drawRenderSettingsWindow(state, layer_context);
    }
    if (state.settings_open) {
        try settings.drawSettingsWindow(state, layer_context);
    }
}

fn syncViewportState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    layer_context.renderer.setEditorViewportState(.{
        .render_mode = switch (state.viewport_render_mode) {
            .textured => .textured,
            .wireframe => .wireframe,
            .unlit => .unlit,
        },
        .show_grid = state.viewport_show_grid,
        .show_bones = state.viewport_show_bones,
        .show_collision = state.viewport_show_collision,
    });
}

fn drawViewportOverlayControls(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const window_size = engine.ui.ImGui.windowSize();

    engine.ui.ImGui.setCursorPos(.{ 18.0, 14.0 });
    if (drawOverlayActionButton(state.text(.perspective_view), 88.0)) {
        camera.setViewPreset(state, layer_context, .perspective);
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayActionButton(state.text(.top_view), 58.0)) {
        camera.setViewPreset(state, layer_context, .top);
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayActionButton(state.text(.side_view), 58.0)) {
        camera.setViewPreset(state, layer_context, .side);
    }

    engine.ui.ImGui.setCursorPos(.{ 18.0, 48.0 });
    if (drawOverlayToggleButton(state.text(.textured), state.viewport_render_mode == .textured, 82.0)) {
        state.viewport_render_mode = .textured;
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayToggleButton(state.text(.wireframe), state.viewport_render_mode == .wireframe, 82.0)) {
        state.viewport_render_mode = .wireframe;
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayToggleButton(state.text(.unlit), state.viewport_render_mode == .unlit, 74.0)) {
        state.viewport_render_mode = .unlit;
    }

    engine.ui.ImGui.setCursorPos(.{ 18.0, 82.0 });
    if (drawOverlayToggleButton(state.text(.show_grid), state.viewport_show_grid, 74.0)) {
        state.viewport_show_grid = !state.viewport_show_grid;
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayToggleButton(state.text(.show_bones), state.viewport_show_bones, 84.0)) {
        state.viewport_show_bones = !state.viewport_show_bones;
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayToggleButton(state.text(.show_collision), state.viewport_show_collision, 96.0)) {
        state.viewport_show_collision = !state.viewport_show_collision;
    }

    try drawNavigationGizmo(state, layer_context, window_size[0]);
}

fn drawNavigationGizmo(state: *EditorState, layer_context: *engine.core.LayerContext, window_width: f32) !void {
    const button = 24.0;
    const gap = 4.0;
    const right = @max(window_width - 108.0, 16.0);
    const top = 16.0;

    engine.ui.ImGui.setCursorPos(.{ right + button, top });
    if (drawOverlayNavButton("+Y", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, -1.0, 0.0 });
    }

    engine.ui.ImGui.setCursorPos(.{ right, top + button + gap });
    if (drawOverlayNavButton("-X", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ 1.0, 0.0, 0.0 });
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayNavButton("+Z", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 0.0, -1.0 });
    }
    engine.ui.ImGui.sameLine();
    if (drawOverlayNavButton("+X", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ -1.0, 0.0, 0.0 });
    }

    engine.ui.ImGui.setCursorPos(.{ right + button, top + (button + gap) * 2.0 });
    if (drawOverlayNavButton("-Y", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 1.0, 0.0 });
    }

    engine.ui.ImGui.setCursorPos(.{ right + button, top + (button + gap) * 3.0 });
    if (drawOverlayNavButton("-Z", button)) {
        camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 0.0, 1.0 });
    }
}

fn drawOverlayActionButton(label: []const u8, width: f32) bool {
    return drawOverlayButton(label, false, width, 26.0);
}

fn drawOverlayToggleButton(label: []const u8, active: bool, width: f32) bool {
    return drawOverlayButton(label, active, width, 26.0);
}

fn drawOverlayNavButton(label: []const u8, size: f32) bool {
    return drawOverlayButton(label, false, size, size);
}

fn drawOverlayButton(label: []const u8, active: bool, width: f32, height: f32) bool {
    const palette = if (active)
        [3][4]f32{
            .{ 0.25, 0.43, 0.66, 0.86 },
            .{ 0.30, 0.50, 0.74, 0.94 },
            .{ 0.22, 0.37, 0.56, 0.98 },
        }
    else
        [3][4]f32{
            .{ 0.20, 0.20, 0.21, 0.40 },
            .{ 0.24, 0.25, 0.27, 0.58 },
            .{ 0.28, 0.29, 0.31, 0.70 },
        };
    engine.ui.ImGui.pushStyleColor(.button, palette[0]);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette[1]);
    engine.ui.ImGui.pushStyleColor(.button_active, palette[2]);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, 13.0);
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, .{ 10.0, 5.0 });
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.buttonEx(label, width, height);
}

fn hierarchyCategoryLabel(state: *const EditorState) []const u8 {
    return switch (state.hierarchy_category) {
        .all => state.text(.all),
        .cameras => state.text(.cameras),
        .lights => state.text(.lights),
        .geometry => state.text(.geometry),
        .objects => state.text(.objects),
    };
}

fn nextHierarchyCategory(category: HierarchyCategory) HierarchyCategory {
    return switch (category) {
        .all => .cameras,
        .cameras => .lights,
        .lights => .geometry,
        .geometry => .objects,
        .objects => .all,
    };
}
