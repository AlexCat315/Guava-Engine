const std = @import("std");
const engine = @import("guava");
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const scene_hierarchy = @import("windows/scene_hierarchy.zig");
const inspector = @import("windows/inspector.zig");
const place_actors = @import("windows/place_actors.zig");
const content_browser = @import("../assets/browser.zig");
const menu_bar = @import("menu_bar.zig");
const render_settings = @import("windows/render_settings.zig");
const settings = @import("windows/settings.zig");
const ui_icons = @import("icons.zig");
const layout = @import("layout.zig");
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
    _ = engine.ui.ImGui.inputTextWithHint("##viewport_hierarchy_filter", state.text(.hierarchy_filter), state.hierarchy_filter_buffer[0..]);
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
        _ = engine.ui.ImGui.inputTextWithHint("##viewport_hierarchy_filter_compact", state.text(.hierarchy_filter), state.hierarchy_filter_buffer[0..]);
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
        _ = engine.ui.ImGui.inputTextWithHint("##viewport_hierarchy_filter_narrow", state.text(.hierarchy_filter), state.hierarchy_filter_buffer[0..]);
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
    state.viewport_overlay_hovered = false;

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
        try handleViewportAssetDropTargets(state, layer_context);
        try drawViewportOverlayControlsWindow(state, layer_context);
        try drawViewportPlaybackOverlayWindow(state, layer_context);
        drawViewportViewCube(state, layer_context);
    } else {
        engine.ui.ImGui.text(state.text(.viewport_target_is_not_ready_yet));
    }
}

pub fn drawStatsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .stats, "stats_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

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
    const window_width = @as(f32, @floatFromInt(layer_context.window.logical_width));
    const height = 38.0;
    engine.ui.ImGui.setNextWindowPos(.{ 0.0, @as(f32, @floatFromInt(layer_context.window.logical_height)) - height });
    engine.ui.ImGui.setNextWindowSize(.{ window_width, height });
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

    var compact_path_buffer: [160]u8 = undefined;
    const compact_path = compactStatusPath(
        &compact_path_buffer,
        selected_path,
        statusPathCharacterBudget(window_width),
    );

    var metrics_buffer: [320]u8 = undefined;
    var metrics_stream = std.io.fixedBufferStream(&metrics_buffer);
    try buildStatusMetricsText(
        metrics_stream.writer(),
        state,
        selection_count,
        fps,
        save_status,
        backend_text,
        memory_text,
        window_width,
    );
    const metrics_text = metrics_stream.getWritten();

    var context_buffer: [384]u8 = undefined;
    var context_stream = std.io.fixedBufferStream(&context_buffer);
    try buildStatusContextText(
        context_stream.writer(),
        state,
        compact_path,
        camera_text,
        mode_text,
        space_text,
        window_width,
    );
    const context_text = context_stream.getWritten();

    engine.ui.ImGui.pushStyleVarVec2(.item_spacing, .{ 8.0, 0.0 });
    defer engine.ui.ImGui.popStyleVar(1);
    engine.ui.ImGui.setCursorPos(.{ 0.0, 3.0 });
    if (engine.ui.ImGui.beginTable("status_bar_layout", 2)) {
        defer engine.ui.ImGui.endTable();
        engine.ui.ImGui.tableSetupColumn("##status_context", true, if (window_width >= 1280.0) 0.62 else 0.56);
        engine.ui.ImGui.tableSetupColumn("##status_metrics", true, if (window_width >= 1280.0) 0.38 else 0.44);
        engine.ui.ImGui.tableNextRow();
        engine.ui.ImGui.tableNextColumn();
        engine.ui.ImGui.alignTextToFramePadding();
        engine.ui.ImGui.text(context_text);
        engine.ui.ImGui.tableNextColumn();
        engine.ui.ImGui.alignTextToFramePadding();
        engine.ui.ImGui.text(metrics_text);
    }
}

fn buildStatusMetricsText(
    writer: anytype,
    state: *const EditorState,
    selection_count: usize,
    fps: f32,
    save_status: []const u8,
    backend_text: []const u8,
    memory_text: []const u8,
    window_width: f32,
) !void {
    var first = true;

    var selection_buffer: [24]u8 = undefined;
    const selection_text = try std.fmt.bufPrint(&selection_buffer, "{d}", .{selection_count});
    try appendStatusSegment(writer, &first, state.text(.selection_count), selection_text);

    var fps_buffer: [32]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
    try appendStatusSegment(writer, &first, state.text(.fps), fps_text);

    try appendStatusSegment(writer, &first, state.text(.save_status), save_status);
    if (window_width >= 980.0) {
        try appendStatusSegment(writer, &first, state.text(.backend), backend_text);
    }
    if (window_width >= 1180.0) {
        try appendStatusSegment(writer, &first, state.text(.memory), memory_text);
    }
}

fn buildStatusContextText(
    writer: anytype,
    state: *const EditorState,
    selected_path: []const u8,
    camera_text: []const u8,
    mode_text: []const u8,
    space_text: []const u8,
    window_width: f32,
) !void {
    var first = true;
    try appendStatusSegment(writer, &first, state.text(.selected_path), selected_path);
    if (window_width >= 820.0) {
        try appendStatusSegment(writer, &first, state.text(.camera), camera_text);
    }
    if (window_width >= 980.0) {
        try appendStatusSegment(writer, &first, state.text(.mode), mode_text);
    }
    if (window_width >= 1120.0) {
        try appendStatusSegment(writer, &first, state.text(.coordinate_space), space_text);
    }
}

fn appendStatusSegment(writer: anytype, first: *bool, label: []const u8, value: []const u8) !void {
    if (!first.*) {
        try writer.writeAll("  |  ");
    }
    first.* = false;
    try writer.print("{s}: {s}", .{ label, value });
}

fn statusPathCharacterBudget(window_width: f32) usize {
    if (window_width < 720.0) return 18;
    if (window_width < 960.0) return 28;
    if (window_width < 1280.0) return 42;
    return 60;
}

fn compactStatusPath(buffer: []u8, path: []const u8, max_chars: usize) []const u8 {
    if (path.len <= max_chars or buffer.len == 0) {
        return path;
    }

    const clamped_chars = @max(max_chars, 4);
    const tail_len = @min(path.len, clamped_chars - 3);
    const written = std.fmt.bufPrint(buffer, "...{s}", .{path[path.len - tail_len ..]}) catch return path;
    return written;
}

pub fn handleViewportSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;
    if (!state.viewport_has_image or !state.viewport_hovered or state.viewport_overlay_hovered or !input.wasMousePressed(.left) or input.modifiers.alt) {
        return;
    }
    if (viewportPixelUnderMouse(state, layer_context)) |pixel| {
        try layer_context.renderer.requestSelectionReadback(
            pixel[0],
            pixel[1],
            if (input.modifiers.shift or input.modifiers.ctrl or input.modifiers.super) .toggle else .replace,
        );
    }
}

pub fn drawEditorUi(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    syncViewportState(state, layer_context);
    try applyPendingViewportAssetDrop(state, layer_context);
    syncPlaybackState(state, layer_context);
    try menu_bar.drawMenuBar(state, layer_context);
    try drawViewportWindow(state, layer_context);
    try drawStatusBarWindow(state, layer_context);
    try scene_hierarchy.drawSceneWindow(state, layer_context);
    try place_actors.drawPlaceActorsWindow(state, layer_context);
    try inspector.drawInspectorWindow(state, layer_context);
    try content_browser.drawContentBrowser(state, layer_context);
    if (state.render_settings_open) {
        try render_settings.drawRenderSettingsWindow(state, layer_context);
    }
    if (state.settings_open) {
        try settings.drawSettingsWindow(state, layer_context);
    }
}

fn viewportPixelUnderMouse(state: *const EditorState, layer_context: *const engine.core.LayerContext) ?[2]u32 {
    if (state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return null;
    }

    const input = layer_context.input;
    const local_x = input.mouse_position[0] - state.viewport_origin[0];
    const local_y = input.mouse_position[1] - state.viewport_origin[1];
    if (local_x < 0.0 or local_y < 0.0 or local_x > state.viewport_extent[0] or local_y > state.viewport_extent[1]) {
        return null;
    }

    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0) {
        return null;
    }

    const normalized_x = std.math.clamp(local_x / state.viewport_extent[0], 0.0, 1.0);
    const normalized_y = std.math.clamp(local_y / state.viewport_extent[1], 0.0, 1.0);
    return .{
        @as(u32, @intFromFloat(std.math.clamp(
            normalized_x * @as(f32, @floatFromInt(viewport_size[0])),
            0.0,
            @as(f32, @floatFromInt(viewport_size[0] - 1)),
        ))),
        @as(u32, @intFromFloat(std.math.clamp(
            normalized_y * @as(f32, @floatFromInt(viewport_size[1])),
            0.0,
            @as(f32, @floatFromInt(viewport_size[1] - 1)),
        ))),
    };
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

fn applyPendingViewportAssetDrop(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const pending = state.pending_viewport_drop orelse return;
    defer state.pending_viewport_drop = null;

    switch (pending.source_kind) {
        .asset => {
            const asset_index = pending.asset_index orelse return;
            if (asset_index >= state.asset_entries.items.len) {
                return;
            }
            const entry = state.asset_entries.items[asset_index];

            switch (entry.kind) {
                .model => try history.importModelPath(state, layer_context, entry.path),
                .texture => {
                    const target_entity = pending.target_entity orelse layer_context.renderer.selectedEntity() orelse return;
                    const entity = layer_context.world.getEntity(target_entity) orelse return;
                    if (entity.material == null) {
                        try inspector.addMaterialComponent(state, layer_context, entity);
                    }
                    const texture_handle = try inspector.importTextureAsset(state, layer_context, entry.id, entry.path);
                    if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
                        material_resource.base_color_texture = texture_handle;
                        if (entity.material) |*material_component| {
                            material_component.handle = inspector.materialHandleForEntity(state, entity);
                        }
                        try history.captureSnapshot(state, layer_context);
                    }
                },
                else => {},
            }
        },
        .place_actor => {
            const actor_kind = pending.actor_kind orelse return;
            const spawn_transform = try calculateSpawnTransformFromPixel(state, layer_context, pending.pixel);
            switch (actor_kind) {
                .empty => try history.spawnEmptyEntityAt(state, layer_context, spawn_transform),
                .camera => try history.spawnCameraEntityAt(state, layer_context, spawn_transform),
                .cube => try history.spawnPrimitiveAt(state, layer_context, .cube, spawn_transform),
                .sphere => try history.spawnPrimitiveAt(state, layer_context, .sphere, spawn_transform),
                .plane => try history.spawnPrimitiveAt(state, layer_context, .plane, spawn_transform),
                .point_light => try history.spawnPointLightAt(state, layer_context, spawn_transform),
                .spot_light => try history.spawnSpotLightAt(state, layer_context, spawn_transform),
                .directional_light => try history.spawnDirectionalLightAt(state, layer_context, spawn_transform),
            }
        },
    }
}

fn calculateSpawnTransformFromPixel(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    pixel: ?[2]u32,
) !engine.scene.Transform {
    if (pixel) |p| {
        const camera_transform = camera.activeCameraTransform(state, layer_context);
        const viewport_size = layer_context.renderer.sceneViewportSize();
        if (viewport_size[0] == 0 or viewport_size[1] == 0) {
            return history.spawnTransform(state, layer_context);
        }
        const ndc_x = (@as(f32, @floatFromInt(p[0])) / @as(f32, @floatFromInt(viewport_size[0]))) * 2.0 - 1.0;
        const ndc_y = 1.0 - (@as(f32, @floatFromInt(p[1])) / @as(f32, @floatFromInt(viewport_size[1]))) * 2.0;
        const fov_y = 1.0;
        const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));
        const tan_half_fov = @tan(fov_y * 0.5);
        const ray_dir_ndc = [3]f32{ ndc_x * tan_half_fov * aspect, ndc_y * tan_half_fov, -1.0 };
        const ray_dir = vec3.normalize(ray_dir_ndc);
        const ray_origin = camera_transform.translation;
        const plane_y: f32 = 0.0;
        if (ray_dir[1] != 0.0) {
            const t = (plane_y - ray_origin[1]) / ray_dir[1];
            if (t > 0.0) {
                const hit_point = [3]f32{
                    ray_origin[0] + ray_dir[0] * t,
                    plane_y,
                    ray_origin[2] + ray_dir[2] * t,
                };
                return .{ .translation = hit_point };
            }
        }
    }
    return history.spawnTransform(state, layer_context);
}

fn handleViewportAssetDropTargets(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var asset_index: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_model_drag_payload, &asset_index)) {
        state.pending_viewport_drop = .{
            .source_kind = .asset,
            .asset_index = @as(usize, @intCast(asset_index)),
            .pixel = viewportPixelUnderMouse(state, layer_context),
        };
        return;
    }
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &asset_index)) {
        if (viewportPixelUnderMouse(state, layer_context)) |pixel| {
            try layer_context.renderer.requestSelectionReadback(pixel[0], pixel[1], .replace);
            state.pending_viewport_drop = .{
                .source_kind = .asset,
                .asset_index = @as(usize, @intCast(asset_index)),
                .pixel = pixel,
            };
        }
    }
    var actor_kind_int: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.place_actor_drag_payload, &actor_kind_int)) {
        const actor_kind = @as(state_mod.PlaceActorKind, @enumFromInt(actor_kind_int));
        const pixel = viewportPixelUnderMouse(state, layer_context);
        state.pending_viewport_drop = .{
            .source_kind = .place_actor,
            .actor_kind = actor_kind,
            .pixel = pixel,
        };
    }
}

fn drawViewportOverlayControlsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const overlay_pos = .{
        state.viewport_origin[0] + 14.0,
        state.viewport_origin[1] + viewportOverlayTopInset(),
    };
    engine.ui.ImGui.setNextWindowPos(overlay_pos);
    engine.ui.ImGui.setNextWindowBgAlpha(0.6);
    _ = engine.ui.ImGui.beginWindowFlags(
        "##viewport_overlay_controls",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_docking |
            engine.ui.ImGui.WindowFlags.no_background |
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.pushStyleVarVec2(.item_spacing, .{ 10.0, 4.0 });
    defer engine.ui.ImGui.popStyleVar(1);

    if (engine.ui.ImGui.beginMenu("View")) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.perspective_view), null, state.viewport_view_preset == .perspective, true)) {
            camera.setViewPreset(state, layer_context, .perspective);
        }
        if (engine.ui.ImGui.menuItem(state.text(.top_view), null, state.viewport_view_preset == .top, true)) {
            camera.setViewPreset(state, layer_context, .top);
        }
        if (engine.ui.ImGui.menuItem(state.text(.side_view), null, state.viewport_view_preset == .side, true)) {
            camera.setViewPreset(state, layer_context, .side);
        }
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.beginMenu(currentRenderModeLabel(state))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.textured), null, state.viewport_render_mode == .textured, true)) {
            state.viewport_render_mode = .textured;
        }
        if (engine.ui.ImGui.menuItem(state.text(.wireframe), null, state.viewport_render_mode == .wireframe, true)) {
            state.viewport_render_mode = .wireframe;
        }
        if (engine.ui.ImGui.menuItem(state.text(.unlit), null, state.viewport_render_mode == .unlit, true)) {
            state.viewport_render_mode = .unlit;
        }
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.beginMenu("Overlay")) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.show_grid), null, state.viewport_show_grid, true)) {
            state.viewport_show_grid = !state.viewport_show_grid;
        }
        if (engine.ui.ImGui.menuItem(state.text(.show_bones), null, state.viewport_show_bones, true)) {
            state.viewport_show_bones = !state.viewport_show_bones;
        }
        if (engine.ui.ImGui.menuItem(state.text(.show_collision), null, state.viewport_show_collision, true)) {
            state.viewport_show_collision = !state.viewport_show_collision;
        }
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.beginMenu("Snap")) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.translation_snap), null, state.translation_snap_enabled, true)) {
            state.translation_snap_enabled = !state.translation_snap_enabled;
        }
        if (engine.ui.ImGui.menuItem(state.text(.rotation_snap), null, state.rotation_snap_enabled, true)) {
            state.rotation_snap_enabled = !state.rotation_snap_enabled;
        }
        if (engine.ui.ImGui.menuItem(state.text(.scale_snap), null, state.scale_snap_enabled, true)) {
            state.scale_snap_enabled = !state.scale_snap_enabled;
        }
    }

    if (engine.ui.ImGui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }
}

fn drawViewportPlaybackOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const window_width = 126.0;
    engine.ui.ImGui.setNextWindowPos(.{
        state.viewport_origin[0] + @max((state.viewport_extent[0] - window_width) * 0.5, 18.0),
        state.viewport_origin[1] + 10.0,
    });
    engine.ui.ImGui.setNextWindowBgAlpha(0.6);
    _ = engine.ui.ImGui.beginWindowFlags(
        "##viewport_playback_overlay",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_docking |
            engine.ui.ImGui.WindowFlags.no_background |
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_play",
        ui_icons.paths.toolbar.play,
        if (state.playback_state == .playing) activePlayPalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .playing);
    }
    engine.ui.ImGui.sameLine();
    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_pause",
        ui_icons.paths.toolbar.pause,
        if (state.playback_state == .paused) activePausePalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .paused);
    }
    engine.ui.ImGui.sameLine();
    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_step",
        ui_icons.paths.toolbar.step,
        stepPlaybackPalette(),
    )) {
        stepPlayback(state, layer_context);
    }

    if (engine.ui.ImGui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }
}

fn drawViewportViewCube(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const cube_size = std.math.clamp(@min(state.viewport_extent[0], state.viewport_extent[1]) * 0.16, 84.0, 118.0);
    const cube_pos = .{
        state.viewport_origin[0] + state.viewport_extent[0] - cube_size - 14.0,
        state.viewport_origin[1] + viewportOverlayTopInset(),
    };
    const view = camera.activeCameraViewMatrix(state, layer_context);
    const result = engine.ui.ImGui.drawViewCube(&view, cube_pos, cube_size);
    if (result.hovered or result.active) {
        state.viewport_overlay_hovered = true;
    }
    if (result.dragging) {
        camera.orbitFromViewCubeDrag(state, layer_context, result.drag_delta);
    }
    switch (result.face) {
        .front => camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 0.0, -1.0 }),
        .back => camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 0.0, 1.0 }),
        .left => camera.lookAlongWorldAxis(state, layer_context, .{ 1.0, 0.0, 0.0 }),
        .right => camera.lookAlongWorldAxis(state, layer_context, .{ -1.0, 0.0, 0.0 }),
        .top => camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, -1.0, 0.0 }),
        .bottom => camera.lookAlongWorldAxis(state, layer_context, .{ 0.0, 1.0, 0.0 }),
        .none => {},
    }
}

fn currentRenderModeLabel(state: *const EditorState) []const u8 {
    return switch (state.viewport_render_mode) {
        .textured => state.text(.textured),
        .wireframe => state.text(.wireframe),
        .unlit => state.text(.unlit),
    };
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
