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

fn setPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext, playback_state: PlaybackState) void {
    state.playback_state = playback_state;
    layer_context.playback_controller.setState(playback_state);
}

fn stepPlayback(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.playback_state = .paused;
    layer_context.playback_controller.requestStep();
}

fn syncPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.playback_state = layer_context.playback_controller.state;
}

fn drawViewportToolbarStrip(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const width = engine.ui.ImGui.contentRegionAvail()[0];
    engine.ui.ImGui.pushStyleVarVec2(.item_spacing, .{ 6.0, 6.0 });
    defer engine.ui.ImGui.popStyleVar(1);

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

    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.dummy(8.0, 1.0);
    engine.ui.ImGui.sameLine();

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "toolbar_run",
        ui_icons.paths.toolbar.play,
        if (state.playback_state == .playing) activePlayPalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .playing);
    }
    engine.ui.ImGui.sameLine();
    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "toolbar_pause",
        ui_icons.paths.toolbar.pause,
        if (state.playback_state == .paused) activePausePalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .paused);
    }
    engine.ui.ImGui.sameLine();
    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "toolbar_step",
        ui_icons.paths.toolbar.step,
        stepPlaybackPalette(),
    )) {
        stepPlayback(state, layer_context);
    }

    if (width >= 980.0) {
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.perspective_view), false)) {
            camera.setViewPreset(state, layer_context, .perspective);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.top_view), false)) {
            camera.setViewPreset(state, layer_context, .top);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.side_view), false)) {
            camera.setViewPreset(state, layer_context, .side);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.textured), state.viewport_render_mode == .textured)) {
            state.viewport_render_mode = .textured;
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.wireframe), state.viewport_render_mode == .wireframe)) {
            state.viewport_render_mode = .wireframe;
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.unlit), state.viewport_render_mode == .unlit)) {
            state.viewport_render_mode = .unlit;
        }
    } else {
        engine.ui.ImGui.dummy(0.0, 6.0);
        if (drawToolbarChipButton(state.text(.perspective_view), false)) {
            camera.setViewPreset(state, layer_context, .perspective);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.top_view), false)) {
            camera.setViewPreset(state, layer_context, .top);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.side_view), false)) {
            camera.setViewPreset(state, layer_context, .side);
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.textured), state.viewport_render_mode == .textured)) {
            state.viewport_render_mode = .textured;
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.wireframe), state.viewport_render_mode == .wireframe)) {
            state.viewport_render_mode = .wireframe;
        }
        engine.ui.ImGui.sameLine();
        if (drawToolbarChipButton(state.text(.unlit), state.viewport_render_mode == .unlit)) {
            state.viewport_render_mode = .unlit;
        }
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    if (drawToolbarChipButton(state.text(.show_grid), state.viewport_show_grid)) {
        state.viewport_show_grid = !state.viewport_show_grid;
    }
    engine.ui.ImGui.sameLine();
    if (drawToolbarChipButton(state.text(.show_bones), state.viewport_show_bones)) {
        state.viewport_show_bones = !state.viewport_show_bones;
    }
    engine.ui.ImGui.sameLine();
    if (drawToolbarChipButton(state.text(.show_collision), state.viewport_show_collision)) {
        state.viewport_show_collision = !state.viewport_show_collision;
    }

    if (width >= 860.0) {
        const filter_width = std.math.clamp(width * 0.18, 148.0, 228.0);
        const category_width = 72.0;
        const space_width = 72.0;
        const options_width = 28.0 + 10.0 + filter_width + 8.0 + category_width + 8.0 + space_width;
        engine.ui.ImGui.sameLine();
        engine.ui.ImGui.dummy(@max(engine.ui.ImGui.contentRegionAvail()[0] - options_width, 10.0), 1.0);
        engine.ui.ImGui.sameLine();
        try drawViewportToolbarOptions(state, layer_context, filter_width, category_width, space_width);
        return;
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    try drawViewportToolbarOptionsCompact(state, layer_context, width);
}

fn drawViewportToolbarOptions(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    filter_width: f32,
    category_width: f32,
    space_width: f32,
) !void {
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
    engine.ui.ImGui.setNextItemWidth(filter_width);
    _ = engine.ui.ImGui.inputText("##viewport_hierarchy_filter", state.hierarchy_filter_buffer[0..]);
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), category_width, 0.0)) {
        state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(
        switch (state.transform_space) {
            .local => state.text(.local_space),
            .world => state.text(.world_space),
        },
        space_width,
        0.0,
    )) {
        state.transform_space = switch (state.transform_space) {
            .local => .world,
            .world => .local,
        };
    }
}

fn drawViewportToolbarOptionsCompact(state: *EditorState, layer_context: *engine.core.LayerContext, width: f32) !void {
    if (width >= 260.0) {
        if (try ui_icons.drawIconButton(
            state,
            layer_context,
            "toolbar_settings_compact",
            ui_icons.paths.toolbar.settings,
            20.0,
            .{ 235, 239, 245, 255 },
            if (state.render_settings_open) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle,
        )) {
            state.render_settings_open = !state.render_settings_open;
        }
        engine.ui.ImGui.sameLine();
        engine.ui.ImGui.setNextItemWidth(@max(width - 38.0, 120.0));
        _ = engine.ui.ImGui.inputText("##viewport_hierarchy_filter_compact", state.hierarchy_filter_buffer[0..]);
    } else {
        if (try ui_icons.drawIconButton(
            state,
            layer_context,
            "toolbar_settings_compact",
            ui_icons.paths.toolbar.settings,
            20.0,
            .{ 235, 239, 245, 255 },
            if (state.render_settings_open) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle,
        )) {
            state.render_settings_open = !state.render_settings_open;
        }
        engine.ui.ImGui.dummy(0.0, 6.0);
        engine.ui.ImGui.setNextItemWidth(-1.0);
        _ = engine.ui.ImGui.inputText("##viewport_hierarchy_filter_narrow", state.hierarchy_filter_buffer[0..]);
    }

    engine.ui.ImGui.dummy(0.0, 6.0);
    if (width >= 184.0) {
        const half_width = @max((width - 8.0) * 0.5, 88.0);
        if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), half_width, 0.0)) {
            state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.buttonEx(
            switch (state.transform_space) {
                .local => state.text(.local_space),
                .world => state.text(.world_space),
            },
            half_width,
            0.0,
        )) {
            state.transform_space = switch (state.transform_space) {
                .local => .world,
                .world => .local,
            };
        }
    } else {
        if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), width, 0.0)) {
            state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
        }
        engine.ui.ImGui.dummy(0.0, 6.0);
        if (engine.ui.ImGui.buttonEx(
            switch (state.transform_space) {
                .local => state.text(.local_space),
                .world => state.text(.world_space),
            },
            width,
            0.0,
        )) {
            state.transform_space = switch (state.transform_space) {
                .local => .world,
                .world => .local,
            };
        }
    }
}

pub fn drawViewportWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport, "viewport_panel");
    _ = engine.ui.ImGui.beginWindowFlags(
        title,
        engine.ui.ImGui.WindowFlags.no_collapse | engine.ui.ImGui.WindowFlags.no_scrollbar,
    );
    defer engine.ui.ImGui.endWindow();

    try drawViewportToolbarStrip(state, layer_context);
    engine.ui.ImGui.separator();

    _ = engine.ui.ImGui.beginChild("viewport_canvas", 0.0, 0.0, false);
    defer engine.ui.ImGui.endChild();

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
        try drawNavigationGizmo(state, layer_context, image_size[0]);
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
    const height = 46.0;
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
    var memory_buffer: [32]u8 = undefined;
    const memory_text = if (engine.platform.processResidentMemoryBytes()) |memory_bytes| blk: {
        const memory_mb = @as(f32, @floatFromInt(memory_bytes)) / (1024.0 * 1024.0);
        break :blk try std.fmt.bufPrint(&memory_buffer, "{d:.1} MB", .{memory_mb});
    } else "N/A";

    var path_buffer: [320]u8 = undefined;
    const selected_path = if (layer_context.renderer.selectedEntity()) |selected|
        utils.entityPath(&path_buffer, layer_context.world, selected) catch "/"
    else
        "/";

    var primary_buffer: [384]u8 = undefined;
    const primary_text = try std.fmt.bufPrint(
        &primary_buffer,
        "{s}: {d}    {s}: {d:.1}    {s}: {s}    {s}: {s}    {s}: {s}",
        .{
            state.text(.selection_count),
            selection_count,
            state.text(.fps),
            fps,
            state.text(.backend),
            backend_text,
            state.text(.memory),
            memory_text,
            state.text(.save_status),
            save_status,
        },
    );
    var secondary_buffer: [512]u8 = undefined;
    const secondary_text = try std.fmt.bufPrint(
        &secondary_buffer,
        "{s}: {s}    {s}: {s}    {s}: {s}    {s}: {s}",
        .{
            state.text(.selected_path),
            selected_path,
            state.text(.camera),
            camera_text,
            state.text(.mode),
            mode_text,
            state.text(.coordinate_space),
            space_text,
        },
    );
    engine.ui.ImGui.textWrapped(primary_text);
    engine.ui.ImGui.textWrapped(secondary_text);
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
    syncPlaybackState(state, layer_context);
    try menu_bar.drawMenuBar(state, layer_context);
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

fn viewportOverlayTopInset() f32 {
    return 14.0;
}

fn drawPlaybackToolbarIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    palette: ui_icons.ButtonPalette,
) !bool {
    const texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        path,
        14.0,
        .{ 245, 248, 252, 255 },
    );
    engine.ui.ImGui.pushStyleColor(.button, palette.button);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette.hovered);
    engine.ui.ImGui.pushStyleColor(.button_active, palette.active);
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, .{ 5.0, 5.0 });
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, 9.0);
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.imageButton(id, texture, 14.0, 14.0, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}

fn idlePlaybackPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.16, 0.18, 0.21, 0.84 },
        .hovered = .{ 0.22, 0.25, 0.29, 0.94 },
        .active = .{ 0.20, 0.23, 0.27, 0.98 },
    };
}

fn activePlayPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.18, 0.56, 0.33, 0.90 },
        .hovered = .{ 0.22, 0.65, 0.38, 0.96 },
        .active = .{ 0.15, 0.48, 0.28, 1.0 },
    };
}

fn activePausePalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.78, 0.50, 0.18, 0.90 },
        .hovered = .{ 0.87, 0.58, 0.22, 0.96 },
        .active = .{ 0.66, 0.41, 0.14, 1.0 },
    };
}

fn stepPlaybackPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.28, 0.33, 0.40, 0.88 },
        .hovered = .{ 0.34, 0.40, 0.48, 0.96 },
        .active = .{ 0.24, 0.28, 0.34, 1.0 },
    };
}

fn drawNavigationGizmo(state: *EditorState, layer_context: *engine.core.LayerContext, window_width: f32) !void {
    const button = 24.0;
    const gap = 4.0;
    const right = @max(window_width - 108.0, 16.0);
    const top = viewportOverlayTopInset() + 6.0;

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

fn drawToolbarChipButton(label: []const u8, active: bool) bool {
    const palette = if (active)
        [3][4]f32{
            .{ 0.25, 0.43, 0.66, 0.90 },
            .{ 0.30, 0.50, 0.74, 0.96 },
            .{ 0.22, 0.37, 0.56, 1.0 },
        }
    else
        [3][4]f32{
            .{ 0.20, 0.22, 0.25, 0.86 },
            .{ 0.25, 0.28, 0.33, 0.94 },
            .{ 0.18, 0.20, 0.24, 0.98 },
        };
    engine.ui.ImGui.pushStyleColor(.button, palette[0]);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette[1]);
    engine.ui.ImGui.pushStyleColor(.button_active, palette[2]);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, 8.0);
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, .{ 8.0, 4.0 });
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.buttonEx(label, 0.0, 0.0);
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
