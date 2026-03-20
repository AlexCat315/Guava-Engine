const std = @import("std");
const engine = @import("guava");
const sdl = engine.platform.sdl.c;
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
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
const material_editor = @import("windows/material_editor.zig");
const ui_icons = @import("icons.zig");
const layout = @import("layout.zig");
const PlaybackState = @import("../core/state.zig").PlaybackState;
const HierarchyCategory = @import("../core/state.zig").HierarchyCategory;
const viewport_log = std.log.scoped(.viewport_input);

var g_last_viewport_hovered: ?bool = null;
var g_last_viewport_overlay_hovered: ?bool = null;
var g_last_viewport_has_image: ?bool = null;

fn drawToolbarIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    active: bool,
) !bool {
    const accent_tint = [4]u8{ 34, 197, 94, 255 };
    const idle_tint = [4]u8{ 153, 153, 163, 255 };
    const clicked = try ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        20.0,
        if (active) accent_tint else idle_tint,
        if (active) ui_icons.palettes.toolbar_accent else ui_icons.palettes.toolbar_idle,
    );
    if (engine.ui.ImGui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }
    return clicked;
}

fn drawOverlayIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    active: bool,
) !bool {
    const active_tint = [4]u8{ 34, 197, 94, 255 };
    const idle_tint = [4]u8{ 153, 153, 163, 255 };
    const clicked = try ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        16.0,
        if (active) active_tint else idle_tint,
        if (active) ui_icons.palettes.toolbar_accent else ui_icons.palettes.toolbar_idle,
    );
    if (engine.ui.ImGui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }
    return clicked;
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
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.select_tool));
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_move", ui_icons.paths.toolbar.move, state.manipulation_mode == .translate)) {
        try manipulation.beginManipulation(state, layer_context, .translate);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.move_tool));
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_rotate", ui_icons.paths.toolbar.rotate, state.manipulation_mode == .rotate)) {
        try manipulation.beginManipulation(state, layer_context, .rotate);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.rotate_tool));
    }
    engine.ui.ImGui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_scale", ui_icons.paths.toolbar.scale, state.manipulation_mode == .scale)) {
        try manipulation.beginManipulation(state, layer_context, .scale);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.scale_tool));
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
    space_width: f32, // Kept for signature compatibility
) !void {
    _ = space_width;
    const is_manipulating = state.manipulation_mode != .none;

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
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.render_settings));
    }
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(filter_width);
    _ = engine.ui.ImGui.inputTextWithHint("##viewport_hierarchy_filter", state.text(.hierarchy_filter), state.hierarchy_filter_buffer[0..]);
    if (is_manipulating) {
        engine.ui.ImGui.pushStyleVarFloat(.alpha, 0.5);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), category_width, 0.0)) {
        state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
    }
    if (is_manipulating) {
        engine.ui.ImGui.popStyleVar(1);
    }
    engine.ui.ImGui.sameLine();
    // Global/Local toggle - now uses icons instead of text
    const transform_icon_path = switch (state.transform_space) {
        .local => ui_icons.paths.toolbar.transform_local,
        .world => ui_icons.paths.toolbar.transform_global,
    };
    const is_world = state.transform_space == .world;
    if (try drawToolbarIconButton(state, layer_context, "toolbar_transform_space", transform_icon_path, is_world)) {
        state.transform_space = switch (state.transform_space) {
            .local => .world,
            .world => .local,
        };
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(if (is_world) state.text(.world_space) else state.text(.local_space));
    }
}

fn drawViewportToolbarOptionsCompact(state: *EditorState, layer_context: *engine.core.LayerContext, width: f32) !void {
    const is_manipulating = state.manipulation_mode != .none;

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
        if (is_manipulating) {
            engine.ui.ImGui.pushStyleVarFloat(.alpha, 0.5);
        }
        if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), half_width, 0.0)) {
            state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
        }
        if (is_manipulating) {
            engine.ui.ImGui.popStyleVar(1);
        }
        engine.ui.ImGui.sameLine();
        // Global/Local toggle - now uses icons instead of text
        const transform_icon_path = switch (state.transform_space) {
            .local => ui_icons.paths.toolbar.transform_local,
            .world => ui_icons.paths.toolbar.transform_global,
        };
        if (try drawToolbarIconButton(state, layer_context, "toolbar_transform_space_compact", transform_icon_path, state.transform_space == .world)) {
            state.transform_space = switch (state.transform_space) {
                .local => .world,
                .world => .local,
            };
        }
    } else {
        if (is_manipulating) {
            engine.ui.ImGui.pushStyleVarFloat(.alpha, 0.5);
        }
        if (engine.ui.ImGui.buttonEx(hierarchyCategoryLabel(state), width, 0.0)) {
            state.hierarchy_category = nextHierarchyCategory(state.hierarchy_category);
        }
        if (is_manipulating) {
            engine.ui.ImGui.popStyleVar(1);
        }
        engine.ui.ImGui.dummy(0.0, 6.0);
        // Global/Local toggle - now uses icons instead of text
        const transform_icon_path = switch (state.transform_space) {
            .local => ui_icons.paths.toolbar.transform_local,
            .world => ui_icons.paths.toolbar.transform_global,
        };
        if (try drawToolbarIconButton(state, layer_context, "toolbar_transform_space_narrow", transform_icon_path, state.transform_space == .world)) {
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

    engine.ui.ImGui.pushStyleVarVec2(.window_padding, .{ 0.0, 0.0 });
    defer engine.ui.ImGui.popStyleVar(1);

    _ = engine.ui.ImGui.beginWindowFlags(
        title,
        engine.ui.ImGui.WindowFlags.no_collapse |
            engine.ui.ImGui.WindowFlags.no_scrollbar |
            engine.ui.ImGui.WindowFlags.no_scroll_with_mouse,
    );
    defer engine.ui.ImGui.endWindow();

    // Draw toolbar first (at top)
    try drawViewportToolbarStrip(state, layer_context);

    // Calculate remaining space for 3D viewport
    const content_size = engine.ui.ImGui.contentRegionAvail();
    state.viewport_origin = engine.ui.ImGui.cursorScreenPos();
    state.viewport_extent = .{ content_size[0], content_size[1] };
    state.viewport_focused = engine.ui.ImGui.isWindowFocused();
    if (!layer_context.input.isMouseDown(.left)) {
        state.manipulation_started_from_ui = false;
    }
    state.viewport_has_image = false;
    state.viewport_overlay_hovered = false;

    // Use ImGui mouse coordinates so hover/mouse hit-testing stays in the same space
    // as the docked viewport item on HiDPI platforms.
    var mouse_pos = effectiveViewportMousePos(layer_context);
    state.viewport_hovered = isPointInViewportRect(mouse_pos, state.viewport_origin, state.viewport_extent);

    const drawable_size = utils.viewportDrawableSize(layer_context.window, state.viewport_extent);
    try layer_context.renderer.setSceneViewportSize(drawable_size[0], drawable_size[1]);

    if (layer_context.renderer.sceneViewportTexture()) |texture| {
        const image_size = .{
            @max(state.viewport_extent[0], 8.0),
            @max(state.viewport_extent[1], 8.0),
        };
        engine.ui.ImGui.image(texture, image_size[0], image_size[1]);
        const image_min = engine.ui.ImGui.getItemRectMin();
        const image_max = engine.ui.ImGui.getItemRectMax();
        state.viewport_origin = image_min;
        state.viewport_extent = .{
            @max(image_max[0] - image_min[0], 0.0),
            @max(image_max[1] - image_min[1], 0.0),
        };
        mouse_pos = effectiveViewportMousePos(layer_context);
        state.viewport_hovered = isPointInViewportRect(mouse_pos, state.viewport_origin, state.viewport_extent);
        state.viewport_has_image = true;

        // Draw overlays (positioned absolutely, won't affect layout)
        try handleViewportAssetDropTargets(state, layer_context);
        try drawViewportOverlayControlsWindow(state, layer_context);
        try drawViewportPlaybackOverlayWindow(state, layer_context);
        try drawViewportFpsOverlayWindow(state, layer_context);
        try drawViewportDebugOverlayWindow(state, layer_context);
        try ai_collaboration.drawViewportCollaborationOverlay(state, layer_context);
        drawViewportViewCube(state, layer_context);
        logViewportStateChange(state, layer_context);
    } else {
        engine.ui.ImGui.text(state.text(.viewport_target_is_not_ready_yet));
        logViewportStateChange(state, layer_context);
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

    if (state.fps_display_mode == .status_bar) {
        var fps_buffer: [32]u8 = undefined;
        const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
        try appendStatusSegment(writer, &first, state.text(.fps), fps_text);
    }

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
    if (input.wasMousePressed(.left)) {
        state.viewport_selection_press_active = canBeginViewportSelection(state, input);
        if (state.viewport_selection_press_active) {
            state.viewport_selection_press_mouse = input.mouse_position;
            viewport_log.info("selection press candidate mouse=({d:.1},{d:.1})", .{ input.mouse_position[0], input.mouse_position[1] });
        } else {
            viewport_log.warn(
                "selection press blocked hovered={} overlay_hovered={} has_image={} alt={} manipulation_mode={s}",
                .{
                    state.viewport_hovered,
                    state.viewport_overlay_hovered,
                    state.viewport_has_image,
                    input.modifiers.alt,
                    @tagName(state.manipulation_mode),
                },
            );
        }
    }

    if (!state.viewport_selection_press_active or !input.wasMouseReleased(.left)) {
        return;
    }
    defer state.viewport_selection_press_active = false;

    if (!canBeginViewportSelection(state, input)) {
        return;
    }

    const click_delta = .{
        input.mouse_position[0] - state.viewport_selection_press_mouse[0],
        input.mouse_position[1] - state.viewport_selection_press_mouse[1],
    };
    const click_distance_sq = click_delta[0] * click_delta[0] + click_delta[1] * click_delta[1];
    if (click_distance_sq > 16.0) {
        viewport_log.info("selection cancelled as drag distance_sq={d:.3}", .{click_distance_sq});
        return;
    }

    if (viewportPixelUnderMouse(state, layer_context)) |pixel| {
        const viewport_size = layer_context.renderer.sceneViewportSize();
        if (camera.activeCameraRayFromViewportPixel(state, layer_context, pixel, viewport_size)) |ray| {
            const mode = selectionUpdateModeForInput(input);
            if (layer_context.world.raycastSurface(ray)) |hit| {
                viewport_log.info("selection hit entity={d} mode={s}", .{ hit.entity_id, @tagName(mode) });
                switch (mode) {
                    .replace => try layer_context.renderer.replaceSelection(hit.entity_id),
                    .toggle => try layer_context.renderer.toggleSelection(hit.entity_id),
                }
            } else if (mode == .replace) {
                viewport_log.info("selection miss clear", .{});
                try layer_context.renderer.replaceSelection(null);
            }
        }
    }
}

fn canBeginViewportSelection(state: *const EditorState, input: *const engine.core.InputState) bool {
    return state.viewport_has_image and
        state.viewport_hovered and
        !state.viewport_overlay_hovered and
        !input.modifiers.alt and
        state.manipulation_mode == .none;
}

fn selectionUpdateModeForInput(input: *const engine.core.InputState) engine.render.SelectionUpdateMode {
    return if (input.modifiers.shift or input.modifiers.ctrl or input.modifiers.super)
        .toggle
    else
        .replace;
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
    if (state.material_editor_open) {
        try material_editor.drawMaterialEditorWindow(state, layer_context);
    }
}

fn viewportPixelUnderMouse(state: *const EditorState, layer_context: *const engine.core.LayerContext) ?[2]u32 {
    if (state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return null;
    }

    const mouse_pos = effectiveViewportMousePos(layer_context);
    const local_x = mouse_pos[0] - state.viewport_origin[0];
    const local_y = mouse_pos[1] - state.viewport_origin[1];
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
        .exposure_enabled = state.viewport_exposure_enabled,
        .exposure = state.viewport_exposure,
        .bloom_enabled = state.viewport_bloom_enabled,
        .bloom_threshold = state.viewport_bloom_threshold,
        .bloom_intensity = state.viewport_bloom_intensity,
        .color_grading_enabled = state.viewport_color_grading_enabled,
        .color_grading_saturation = state.viewport_color_grading_saturation,
        .color_grading_contrast = state.viewport_color_grading_contrast,
        .color_grading_gamma = state.viewport_color_grading_gamma,
        .fxaa_enabled = state.viewport_fxaa_enabled,
        .lut_enabled = state.viewport_lut_enabled,
        .lut_intensity = state.viewport_lut_intensity,
        .lut_preset = state.viewport_lut_preset,
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
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, ui_icons.regular_icon_button_padding);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, ui_icons.regular_icon_button_rounding);
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
            const entry = &state.asset_entries.items[asset_index];

            switch (entry.kind) {
                .model => {
                    const spawn_transform = try calculateSpawnTransformFromPixel(state, layer_context, pending.pixel, null);
                    try history.importModelPathAt(state, layer_context, entry.path, spawn_transform);
                },
                .material => {
                    const target_entity = pending.target_entity orelse layer_context.renderer.selectedEntity() orelse return;
                    _ = try content_browser.applyMaterialAssetToEntity(state, layer_context, entry, target_entity);
                },
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
            const spawn_transform = try calculateSpawnTransformFromPixel(
                state,
                layer_context,
                pending.pixel,
                placementHalfExtentsForActorKind(actor_kind),
            );
            switch (actor_kind) {
                .empty => try history.spawnEmptyEntityAt(state, layer_context, spawn_transform),
                .camera => try history.spawnCameraEntityAt(state, layer_context, spawn_transform),
                .cube => try history.spawnPrimitiveAt(state, layer_context, .cube, spawn_transform),
                .sphere => try history.spawnPrimitiveAt(state, layer_context, .sphere, spawn_transform),
                .plane => try history.spawnPrimitiveAt(state, layer_context, .plane, spawn_transform),
                .point_light => try history.spawnPointLightAt(state, layer_context, spawn_transform),
                .spot_light => try history.spawnSpotLightAt(state, layer_context, spawn_transform),
                .directional_light => try history.spawnDirectionalLightAt(state, layer_context, spawn_transform),
                .vfx_fountain => try history.spawnVfxEntityAt(state, layer_context, .fountain, spawn_transform),
                .vfx_orbit => try history.spawnVfxEntityAt(state, layer_context, .orbit, spawn_transform),
            }
        },
    }
}

fn calculateSpawnTransformFromPixel(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    pixel: ?[2]u32,
    placement_half_extents: ?[3]f32,
) !engine.scene.Transform {
    if (pixel) |p| {
        const viewport_size = layer_context.renderer.sceneViewportSize();
        if (camera.activeCameraRayFromViewportPixel(state, layer_context, p, viewport_size)) |ray| {
            if (placement_half_extents) |half_extents| {
                if (try physicsAwareSpawnTransform(layer_context, ray, half_extents)) |spawn_transform| {
                    return spawn_transform;
                }
            }

            if (engine.physics.raycast(layer_context.world, .{
                .origin = ray.origin,
                .direction = ray.direction,
                .max_distance = 2048.0,
            }, .{})) |hit| {
                return .{ .translation = hit.position };
            }

            if (layer_context.world.raycastSurface(ray)) |hit| {
                return .{ .translation = hit.position };
            }

            const plane_y: f32 = 0.0;
            if (ray.direction[1] != 0.0) {
                const t = (plane_y - ray.origin[1]) / ray.direction[1];
                if (t > 0.0) {
                    const hit_point = [3]f32{
                        ray.origin[0] + ray.direction[0] * t,
                        plane_y,
                        ray.origin[2] + ray.direction[2] * t,
                    };
                    return .{ .translation = hit_point };
                }
            }
        }
    }
    return history.spawnTransform(state, layer_context);
}

fn placementHalfExtentsForActorKind(actor_kind: state_mod.PlaceActorKind) ?[3]f32 {
    return switch (actor_kind) {
        .cube, .sphere => .{ 0.5, 0.5, 0.5 },
        .plane => .{ 0.5, 0.05, 0.5 },
        .empty, .camera, .point_light, .spot_light, .directional_light, .vfx_fountain, .vfx_orbit => .{ 0.25, 0.25, 0.25 },
    };
}

fn physicsAwareSpawnTransform(
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    half_extents: [3]f32,
) !?engine.scene.Transform {
    const surface_hit = engine.physics.raycast(layer_context.world, .{
        .origin = ray.origin,
        .direction = ray.direction,
        .max_distance = 2048.0,
    }, .{}) orelse return null;

    const sweep_start = vec3.add(ray.origin, vec3.scale(ray.direction, 0.05));
    const sweep_distance = @max(surface_hit.distance - 0.05, 0.0) + vec3.length(half_extents) + 0.5;
    const sweep_bounds = engine.physics.aabbFromCenterHalfExtents(sweep_start, half_extents);
    const sweep_hit = engine.physics.sweepAabb(
        layer_context.world,
        sweep_bounds,
        vec3.scale(ray.direction, sweep_distance),
        .{},
    ) orelse return .{ .translation = surface_hit.position };

    const candidate_translation = vec3.add(sweep_start, vec3.scale(ray.direction, sweep_hit.distance));
    const candidate_bounds = engine.physics.aabbFromCenterHalfExtents(candidate_translation, half_extents);
    const overlaps = try engine.physics.overlapAabb(
        layer_context.world,
        layer_context.world.allocator,
        candidate_bounds,
        .{ .exclude_entity = sweep_hit.entity_id },
    );
    defer layer_context.world.allocator.free(overlaps);

    if (overlaps.len != 0) {
        return .{ .translation = surface_hit.position };
    }

    return .{ .translation = candidate_translation };
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
        return;
    }
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_material_drag_payload, &asset_index)) {
        if (viewportPixelUnderMouse(state, layer_context)) |pixel| {
            try layer_context.renderer.requestSelectionReadback(pixel[0], pixel[1], .replace);
            state.pending_viewport_drop = .{
                .source_kind = .asset,
                .asset_index = @as(usize, @intCast(asset_index)),
                .pixel = pixel,
            };
        }
        return;
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
    const view_popup_id = "viewport_view_popup";
    const render_popup_id = "viewport_render_popup";
    const overlay_popup_id = "viewport_overlay_popup";
    const view_popup_open = engine.ui.ImGui.isPopupOpen(view_popup_id);
    const render_popup_open = engine.ui.ImGui.isPopupOpen(render_popup_id);
    const overlay_popup_open = engine.ui.ImGui.isPopupOpen(overlay_popup_id);

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
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.pushStyleVarVec2(.item_spacing, .{ 6.0, 4.0 });
    defer engine.ui.ImGui.popStyleVar(1);

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_view", currentViewPresetIcon(state), view_popup_open)) {
        engine.ui.ImGui.openPopup(view_popup_id);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.view_presets));
    }
    if (engine.ui.ImGui.beginPopup(view_popup_id)) {
        defer engine.ui.ImGui.endPopup();
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

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_render", currentRenderModeIcon(state), render_popup_open)) {
        engine.ui.ImGui.openPopup(render_popup_id);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.render_modes));
    }
    if (engine.ui.ImGui.beginPopup(render_popup_id)) {
        defer engine.ui.ImGui.endPopup();
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

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_options", ui_icons.paths.toolbar.overlay, overlay_popup_open)) {
        engine.ui.ImGui.openPopup(overlay_popup_id);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.overlay_options));
    }
    if (engine.ui.ImGui.beginPopup(overlay_popup_id)) {
        defer engine.ui.ImGui.endPopup();
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

    // Note: Transform tools and transform space are now in the toolbar strip above the viewport
    // Only snap buttons remain in overlay

    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_translate", ui_icons.paths.toolbar.snap_translate, state.translation_snap_enabled)) {
        state.translation_snap_enabled = !state.translation_snap_enabled;
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.translation_snap));
    }
    engine.ui.ImGui.sameLine();
    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_rotate", ui_icons.paths.toolbar.snap_rotate, state.rotation_snap_enabled)) {
        state.rotation_snap_enabled = !state.rotation_snap_enabled;
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.rotation_snap));
    }
    engine.ui.ImGui.sameLine();
    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_scale", ui_icons.paths.toolbar.snap_scale, state.scale_snap_enabled)) {
        state.scale_snap_enabled = !state.scale_snap_enabled;
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.scale_snap));
    }

    // Show camera speed indicator when shift is held
    if (layer_context.input.modifiers.shift) {
        engine.ui.ImGui.sameLine();
        engine.ui.ImGui.text("3x");
    }

    if (view_popup_open or render_popup_open or overlay_popup_open) {
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
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    // 检查鼠标是否在UI上按下，设置标志防止事件穿透
    const input = layer_context.input;
    const mouse_pressed_on_ui = engine.ui.ImGui.isItemHovered() and input.wasMousePressed(.left);
    if (mouse_pressed_on_ui) {
        state.manipulation_started_from_ui = true;
    }

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_play",
        ui_icons.paths.toolbar.play,
        if (state.playback_state == .playing) activePlayPalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .playing);
    }
    if (engine.ui.ImGui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;

    engine.ui.ImGui.sameLine();
    const mouse_pressed_on_ui2 = engine.ui.ImGui.isItemHovered() and input.wasMousePressed(.left);
    if (mouse_pressed_on_ui2) {
        state.manipulation_started_from_ui = true;
    }

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_pause",
        ui_icons.paths.toolbar.pause,
        if (state.playback_state == .paused) activePausePalette() else idlePlaybackPalette(),
    )) {
        setPlaybackState(state, layer_context, .paused);
    }
    if (engine.ui.ImGui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;

    engine.ui.ImGui.sameLine();
    const mouse_pressed_on_ui3 = engine.ui.ImGui.isItemHovered() and input.wasMousePressed(.left);
    if (mouse_pressed_on_ui3) {
        state.manipulation_started_from_ui = true;
    }

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_step",
        ui_icons.paths.toolbar.step,
        stepPlaybackPalette(),
    )) {
        stepPlayback(state, layer_context);
    }
    if (engine.ui.ImGui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;
}

fn logViewportStateChange(state: *const EditorState, layer_context: *const engine.core.LayerContext) void {
    if (g_last_viewport_hovered == null or
        g_last_viewport_hovered.? != state.viewport_hovered or
        g_last_viewport_overlay_hovered == null or
        g_last_viewport_overlay_hovered.? != state.viewport_overlay_hovered or
        g_last_viewport_has_image == null or
        g_last_viewport_has_image.? != state.viewport_has_image)
    {
        const mouse_pos = effectiveViewportMousePos(layer_context);
        viewport_log.info(
            "viewport state hovered={} overlay_hovered={} has_image={} mouse=({d:.1},{d:.1}) origin=({d:.1},{d:.1}) extent=({d:.1},{d:.1})",
            .{
                state.viewport_hovered,
                state.viewport_overlay_hovered,
                state.viewport_has_image,
                mouse_pos[0],
                mouse_pos[1],
                state.viewport_origin[0],
                state.viewport_origin[1],
                state.viewport_extent[0],
                state.viewport_extent[1],
            },
        );
        g_last_viewport_hovered = state.viewport_hovered;
        g_last_viewport_overlay_hovered = state.viewport_overlay_hovered;
        g_last_viewport_has_image = state.viewport_has_image;
    }
}

fn effectiveViewportMousePos(layer_context: *const engine.core.LayerContext) [2]f32 {
    const imgui_mouse_pos = engine.ui.ImGui.mousePos();
    const invalid_imgui_mouse = !std.math.isFinite(imgui_mouse_pos[0]) or
        !std.math.isFinite(imgui_mouse_pos[1]) or
        imgui_mouse_pos[0] <= -std.math.floatMax(f32) * 0.5 or
        imgui_mouse_pos[1] <= -std.math.floatMax(f32) * 0.5;
    return if (invalid_imgui_mouse) layer_context.input.mouse_position else imgui_mouse_pos;
}

fn isPointInViewportRect(point: [2]f32, origin: [2]f32, extent: [2]f32) bool {
    return point[0] >= origin[0] and
        point[0] <= origin[0] + extent[0] and
        point[1] >= origin[1] and
        point[1] <= origin[1] + extent[1];
}

fn drawViewportFpsOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.fps_display_mode != .viewport) {
        return;
    }

    const fps = if (layer_context.delta_seconds > 0.0001) 1.0 / layer_context.delta_seconds else 0.0;
    var fps_buffer: [64]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{s}: {d:.1}", .{ state.text(.fps), fps });
    const overlay_margin = 14.0;
    const overlay_y = state.viewport_origin[1] + @max(
        state.viewport_extent[1] - engine.ui.ImGui.frameHeight() - 22.0,
        viewportOverlayTopInset() + 56.0,
    );

    engine.ui.ImGui.pushStyleVarVec2(.window_padding, .{ 10.0, 6.0 });
    defer engine.ui.ImGui.popStyleVar(1);
    engine.ui.ImGui.setNextWindowPos(.{
        state.viewport_origin[0] + overlay_margin,
        overlay_y,
    });
    engine.ui.ImGui.setNextWindowBgAlpha(0.72);
    _ = engine.ui.ImGui.beginWindowFlags(
        "##viewport_fps_overlay",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_docking |
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    engine.ui.ImGui.text(fps_text);
}

fn drawViewportDebugOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.viewport_debug_overlay) {
        return;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    const overlay_size = [2]f32{ 332.0, 184.0 };
    var debug_text_buffer: [512]u8 = undefined;
    const debug_text = try buildViewportDebugText(&debug_text_buffer, state, layer_context);

    engine.ui.ImGui.pushStyleVarVec2(.window_padding, .{ 10.0, 8.0 });
    defer engine.ui.ImGui.popStyleVar(1);
    engine.ui.ImGui.setNextWindowPos(.{
        state.viewport_origin[0] + @max(state.viewport_extent[0] - overlay_size[0] - 16.0, 16.0),
        state.viewport_origin[1] + @max(state.viewport_extent[1] - overlay_size[1] - 16.0, viewportOverlayTopInset() + 56.0),
    });
    engine.ui.ImGui.setNextWindowSize(overlay_size);
    engine.ui.ImGui.setNextWindowBgAlpha(0.80);
    _ = engine.ui.ImGui.beginWindowFlags(
        "##viewport_debug_overlay",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_docking,
    );
    defer engine.ui.ImGui.endWindow();

    if (engine.ui.ImGui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    engine.ui.ImGui.text(state.text(.viewport_debug_overlay));
    engine.ui.ImGui.sameLineEx(220.0, 10.0);
    if (engine.ui.ImGui.buttonEx(state.text(.copy), 92.0, 0.0)) {
        copyDebugTextToClipboard(allocator, debug_text) catch {
            std.log.err("failed to copy viewport debug text to clipboard", .{});
        };
    }
    if (engine.ui.ImGui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
    }
    engine.ui.ImGui.separator();

    const input = layer_context.input;
    const tool_text = switch (state.manipulation_mode) {
        .none => state.text(.select),
        .translate => state.text(.move),
        .rotate => state.text(.rotate),
        .scale => state.text(.scale),
    };
    const camera_text = if (state.editor_camera_active) state.text(.editor_camera_mode) else state.text(.scene_camera_mode);

    var flags_buffer: [96]u8 = undefined;
    const flags_text = try std.fmt.bufPrint(
        &flags_buffer,
        "hover={s} overlay={s} focus={s} image={s}",
        .{
            boolText(state.viewport_hovered),
            boolText(state.viewport_overlay_hovered),
            boolText(state.viewport_focused),
            boolText(state.viewport_has_image),
        },
    );
    engine.ui.ImGui.labelText("Flags", flags_text);

    var mouse_buffer: [96]u8 = undefined;
    const mouse_text = try std.fmt.bufPrint(
        &mouse_buffer,
        "pos=({d:.1}, {d:.1}) delta=({d:.1}, {d:.1})",
        .{
            input.mouse_position[0],
            input.mouse_position[1],
            input.mouse_delta[0],
            input.mouse_delta[1],
        },
    );
    engine.ui.ImGui.labelText("Mouse", mouse_text);

    var wheel_buffer: [64]u8 = undefined;
    const wheel_text = try std.fmt.bufPrint(
        &wheel_buffer,
        "now=({d:.2}, {d:.2}) last=({d:.2}, {d:.2}) n={d}",
        .{
            input.mouse_wheel[0],
            input.mouse_wheel[1],
            input.last_mouse_wheel[0],
            input.last_mouse_wheel[1],
            input.mouse_wheel_event_count,
        },
    );
    engine.ui.ImGui.labelText("Wheel", wheel_text);
    engine.ui.ImGui.labelText("Camera", camera_text);
    engine.ui.ImGui.labelText("Tool", tool_text);

    var selection_buffer: [96]u8 = undefined;
    const selection_text = try std.fmt.bufPrint(
        &selection_buffer,
        "count={d} selected={s}",
        .{
            layer_context.renderer.selectedEntities().len,
            debugSelectedEntityText(state, layer_context),
        },
    );
    engine.ui.ImGui.labelText("Selection", selection_text);

    engine.ui.ImGui.labelText("Manip", debugManipulationEntityText(state));
}

fn boolText(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn debugSelectedEntityText(state: *const EditorState, layer_context: *const engine.core.LayerContext) []const u8 {
    _ = state;
    return if (layer_context.renderer.selectedEntity()) |entity_id|
        std.fmt.bufPrint(&debug_selected_entity_buffer, "{d}", .{entity_id}) catch "-"
    else
        "-";
}

fn debugManipulationEntityText(state: *const EditorState) []const u8 {
    return if (state.manipulation_entity) |entity_id|
        std.fmt.bufPrint(&debug_manipulation_entity_buffer, "{d}", .{entity_id}) catch "-"
    else
        "-";
}

var debug_selected_entity_buffer: [32]u8 = undefined;
var debug_manipulation_entity_buffer: [32]u8 = undefined;

fn buildViewportDebugText(buffer: []u8, state: *const EditorState, layer_context: *const engine.core.LayerContext) ![]const u8 {
    const input = layer_context.input;
    const tool_text = switch (state.manipulation_mode) {
        .none => state.text(.select),
        .translate => state.text(.move),
        .rotate => state.text(.rotate),
        .scale => state.text(.scale),
    };
    const camera_text = if (state.editor_camera_active) state.text(.editor_camera_mode) else state.text(.scene_camera_mode);
    const selected_text = if (layer_context.renderer.selectedEntity()) |entity_id|
        try std.fmt.bufPrint(&debug_selected_entity_buffer, "{d}", .{entity_id})
    else
        "-";
    const manipulation_text = if (state.manipulation_entity) |entity_id|
        try std.fmt.bufPrint(&debug_manipulation_entity_buffer, "{d}", .{entity_id})
    else
        "-";
    return std.fmt.bufPrint(
        buffer,
        "flags: hover={s} overlay={s} focus={s} image={s}\nmouse: pos=({d:.1}, {d:.1}) delta=({d:.1}, {d:.1})\nwheel: now=({d:.2}, {d:.2}) last=({d:.2}, {d:.2}) n={d}\ncamera: {s}\ntool: {s}\nselection: count={d} selected={s}\nmanip: {s}",
        .{
            boolText(state.viewport_hovered),
            boolText(state.viewport_overlay_hovered),
            boolText(state.viewport_focused),
            boolText(state.viewport_has_image),
            input.mouse_position[0],
            input.mouse_position[1],
            input.mouse_delta[0],
            input.mouse_delta[1],
            input.mouse_wheel[0],
            input.mouse_wheel[1],
            input.last_mouse_wheel[0],
            input.last_mouse_wheel[1],
            input.mouse_wheel_event_count,
            camera_text,
            tool_text,
            layer_context.renderer.selectedEntities().len,
            selected_text,
            manipulation_text,
        },
    );
}

fn copyDebugTextToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    if (!sdl.SDL_SetClipboardText(text_z.ptr)) {
        return error.ClipboardUnavailable;
    }
}

fn drawViewportViewCube(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const cube_size = std.math.clamp(@min(state.viewport_extent[0], state.viewport_extent[1]) * 0.13, 72.0, 92.0);
    const cube_pos = .{
        state.viewport_origin[0] + state.viewport_extent[0] - cube_size - 20.0,
        state.viewport_origin[1] + viewportOverlayTopInset() + 6.0,
    };
    const view = camera.activeCameraViewMatrix(state, layer_context);
    const result = engine.ui.ImGui.drawViewCube(&view, cube_pos, cube_size);
    const capture_view_cube_input = result.active or
        (result.hovered and layer_context.input.isMouseDown(.left));
    if (capture_view_cube_input) {
        state.viewport_overlay_hovered = true;
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

fn currentViewPresetIcon(state: *const EditorState) []const u8 {
    return switch (state.viewport_view_preset) {
        .perspective, .custom => ui_icons.paths.viewport.perspective,
        .top => ui_icons.paths.viewport.top,
        .side => ui_icons.paths.viewport.side,
    };
}

fn currentRenderModeIcon(state: *const EditorState) []const u8 {
    return switch (state.viewport_render_mode) {
        .textured => ui_icons.paths.viewport.textured,
        .wireframe => ui_icons.paths.viewport.wireframe,
        .unlit => ui_icons.paths.viewport.unlit,
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
