const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const sdl = engine.platform.sdl.c;
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const scene_hierarchy = @import("panels/scene/scene_hierarchy.zig");
const inspector = @import("panels/scene/inspector.zig");
const place_actors = @import("panels/scene/place_actors.zig");
const content_browser = @import("../assets/browser.zig");
const menu_bar = @import("menu_bar.zig");
const floating_window_blocker = @import("floating_window_blocker.zig");
const render_settings = @import("panels/rendering/render_settings.zig");
const settings = @import("panels/rendering/settings.zig");
const material_editor = @import("panels/assets/material_editor.zig");
const timeline_mod = @import("../actions/command.zig");
const viewport_status = @import("panels/viewport/viewport_status.zig");
const ai_chat = @import("panels/ai/ai_chat.zig");
const ui_icons = @import("icons.zig");
const layout = @import("layout.zig");
const playback_session = @import("../core/playback_session.zig");
const viewport_log = std.log.scoped(.viewport_input);

var g_last_viewport_hovered: ?bool = null;
var g_last_viewport_overlay_hovered: ?bool = null;
var g_last_viewport_has_image: ?bool = null;

const ViewportEntityGlyph = enum {
    camera,
    directional,
    point,
    spot,
};

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
    if (gui.isItemHovered()) {
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
    if (gui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }
    return clicked;
}

fn syncPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try playback_session.sync(state, layer_context);
}

fn syncRenderOutputJob(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    switch (state.render_output_job_stage) {
        .idle => {},
        .resize_and_render => {},
        .export_pending => try exportPendingRenderOutput(state, layer_context),
        .restore_pending => {
            if (!state.play_mode_active and state.playback_state == .stopped) {
                restoreRenderOutputOverrides(state, layer_context);
            }
        },
    }
}

fn renderOutputCurrentFrameNumber(state: *const EditorState) ?u32 {
    if (!state.render_output_job_is_sequence) {
        return null;
    }
    return state.renderOutputFrameNumber(state.render_output_job_frame_index);
}

fn beginRenderOutputRestore(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (state.render_output_job_started_playback) {
        playback_session.stop(state, layer_context);
        state.render_output_job_stage = .restore_pending;
        return;
    }
    restoreRenderOutputOverrides(state, layer_context);
}

fn failRenderOutputJob(state: *EditorState, layer_context: *engine.core.LayerContext, err: anyerror) void {
    setRenderOutputStatusFmt(state, .failure, "Export failed: {s}", .{@errorName(err)});
    beginRenderOutputRestore(state, layer_context);
}

fn exportPendingRenderOutput(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const out_path = state.renderOutputResolvedPathAlloc(allocator, renderOutputCurrentFrameNumber(state)) catch |err| {
        setRenderOutputStatusFmt(state, .failure, "Output path is invalid: {s}", .{@errorName(err)});
        beginRenderOutputRestore(state, layer_context);
        return;
    };
    defer allocator.free(out_path);

    if (out_path.len == 0) {
        setRenderOutputStatusLiteral(state, .failure, "Output path is required.");
        beginRenderOutputRestore(state, layer_context);
        return;
    }

    if (state.render_output_job_is_sequence) {
        setRenderOutputStatusFmt(
            state,
            .writing,
            "Writing frame {d}/{d} -> {s}",
            .{ state.render_output_job_frame_index + 1, state.render_output_job_total_frames, out_path },
        );
    } else {
        setRenderOutputStatusFmt(state, .writing, "Writing {s}", .{out_path});
    }
    const dims = layer_context.renderer.sceneViewportSize();
    const export_result = switch (state.render_output_format) {
        .png => if (state.viewport_pipeline_mode == .path_trace)
            layer_context.renderer.exportPathTraceFramePng(
                allocator,
                layer_context.scene,
                out_path,
                .{
                    .denoise = state.render_output_path_trace_denoise,
                    .write_aov_sidecars = state.render_output_path_trace_write_aovs,
                },
            )
        else
            layer_context.renderer.exportFramePng(allocator, out_path),
        .exr => if (state.viewport_pipeline_mode == .path_trace)
            layer_context.renderer.exportPathTraceFrameExr(allocator, layer_context.scene, out_path)
        else
            layer_context.renderer.exportFrameExr(allocator, out_path),
    };

    if (export_result) {
        if (state.render_output_job_is_sequence) {
            state.render_output_job_frame_index += 1;
            if (state.render_output_job_frame_index < state.render_output_job_total_frames) {
                state.render_output_job_stage = .resize_and_render;
                setRenderOutputStatusFmt(
                    state,
                    .queued,
                    "Queued frame {d}/{d}",
                    .{ state.render_output_job_frame_index + 1, state.render_output_job_total_frames },
                );
                return;
            }

            setRenderOutputStatusFmt(
                state,
                .success,
                "Saved {d} frames at {d} x {d}",
                .{ state.render_output_job_total_frames, dims[0], dims[1] },
            );
            beginRenderOutputRestore(state, layer_context);
            return;
        }

        setRenderOutputStatusFmt(state, .success, "Saved {d} x {d} -> {s}", .{ dims[0], dims[1], out_path });
        restoreRenderOutputOverrides(state, layer_context);
    } else |err| {
        failRenderOutputJob(state, layer_context, err);
    }
}

fn restoreRenderOutputOverrides(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.viewport_path_trace_samples = state.render_output_restore_samples;
    state.viewport_path_trace_bounces = state.render_output_restore_bounces;
    state.viewport_path_trace_resolution_scale = state.render_output_restore_resolution_scale;
    state.render_output_job_is_sequence = false;
    state.render_output_job_total_frames = 1;
    state.render_output_job_frame_index = 0;
    state.render_output_job_started_playback = false;
    state.render_output_job_stage = .idle;
    layer_context.playback_controller.setFixedDelta(null);
    layer_context.renderer.resetPathTraceState();
}

fn setRenderOutputStatusLiteral(state: *EditorState, status: state_mod.RenderOutputStatus, text: []const u8) void {
    state.render_output_status = status;
    @memset(state.render_output_status_buffer[0..], 0);
    const copy_len = @min(text.len, state.render_output_status_buffer.len - 1);
    @memcpy(state.render_output_status_buffer[0..copy_len], text[0..copy_len]);
}

fn setRenderOutputStatusFmt(
    state: *EditorState,
    status: state_mod.RenderOutputStatus,
    comptime fmt: []const u8,
    args: anytype,
) void {
    state.render_output_status = status;
    @memset(state.render_output_status_buffer[0..], 0);
    _ = std.fmt.bufPrint(&state.render_output_status_buffer, fmt, args) catch {};
}

fn worldPointToViewportScreen(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    world_position: [3]f32,
) ?[2]f32 {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0 or state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return null;
    }

    const view = camera.activeCameraViewMatrix(state, layer_context);
    const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));
    const projection = engine.math.mat4.projectionForCamera(camera.activeCameraComponent(state, layer_context), aspect);
    const view_projection = engine.math.mat4.mul(projection, view);
    const clip = mulPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
    if (@abs(clip[3]) <= 0.00001 or clip[3] <= 0.0) {
        return null;
    }

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    if (ndc_x < -1.15 or ndc_x > 1.15 or ndc_y < -1.15 or ndc_y > 1.15) {
        return null;
    }

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn mulPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
}

fn viewportEntityIconPath(kind: ViewportEntityGlyph) []const u8 {
    return switch (kind) {
        .camera => ui_icons.paths.viewport_entities.camera,
        .directional => ui_icons.paths.viewport_entities.directional_light,
        .point => ui_icons.paths.viewport_entities.point_light,
        .spot => ui_icons.paths.viewport_entities.spot_light,
    };
}

fn viewportEntityIconTint(kind: ViewportEntityGlyph) [4]u8 {
    return switch (kind) {
        .camera => .{ 122, 208, 255, 255 },
        .directional => .{ 255, 212, 92, 255 },
        .point => .{ 255, 224, 116, 255 },
        .spot => .{ 132, 204, 255, 255 },
    };
}

fn viewportEntityAccent(kind: ViewportEntityGlyph) [4]f32 {
    return switch (kind) {
        .camera => .{ 0.34, 0.77, 1.0, 1.0 },
        .directional => .{ 1.0, 0.82, 0.36, 1.0 },
        .point => .{ 1.0, 0.90, 0.46, 1.0 },
        .spot => .{ 0.57, 0.82, 1.0, 1.0 },
    };
}

fn drawViewportEntityIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    size: f32,
    tint: [4]u8,
) !bool {
    const texture = try ui_icons.ensureTintedIconTexture(state, layer_context, path, size, tint);
    gui.pushStyleColor(.button, .{ 0.0, 0.0, 0.0, 0.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.0, 0.0, 0.0, 0.0 });
    gui.pushStyleColor(.button_active, .{ 0.0, 0.0, 0.0, 0.0 });
    gui.pushStyleVarVec2(.frame_padding, .{ 0.0, 0.0 });
    gui.pushStyleVarFloat(.frame_rounding, 0.0);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    return gui.imageButton(id, texture, size, size, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}

fn resolveViewportPrimarySceneCamera(state: *EditorState, layer_context: *engine.core.LayerContext) ?engine.scene.EntityId {
    if (state.scene_camera) |camera_id| {
        if (layer_context.world.hasEntity(camera_id)) {
            if (layer_context.world.getEntityConst(camera_id)) |entity| {
                if (entity.camera != null) return camera_id;
            }
        }
    }
    if (layer_context.world.primaryCameraEntity()) |camera_id| {
        if (state.editor_camera == null or camera_id != state.editor_camera.?) {
            if (layer_context.world.getEntityConst(camera_id)) |entity| {
                if (entity.camera != null) return camera_id;
            }
        }
    }
    for (layer_context.world.entities.items) |entity| {
        if (entity.camera == null) continue;
        if (state.editor_camera != null and entity.id == state.editor_camera.?) continue;
        return entity.id;
    }
    return null;
}

fn drawViewportSceneEntityIcons(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.viewport_has_image) return;

    const draw_list = gui.getWindowDrawList();
    const selected_entities = layer_context.renderer.selectedEntities();
    const input = layer_context.input;
    const primary_scene_camera = resolveViewportPrimarySceneCamera(state, layer_context);

    for (layer_context.scene.entities.items) |entity| {
        if (!entity.visible or entity.editor_only) continue;
        if (entity.camera == null and entity.light == null) continue;

        const world_transform = layer_context.scene.worldTransformConst(entity.id) orelse entity.local_transform;
        const screen_pos = worldPointToViewportScreen(state, layer_context, world_transform.translation) orelse continue;

        var is_selected = false;
        for (selected_entities) |selected_id| {
            if (selected_id == entity.id) {
                is_selected = true;
                break;
            }
        }

        const kind: ViewportEntityGlyph = if (entity.camera != null)
            .camera
        else switch (entity.light.?.kind) {
            .directional => .directional,
            .point => .point,
            .spot => .spot,
        };
        const tint = viewportEntityIconTint(kind);
        const accent = viewportEntityAccent(kind);
        const is_primary_scene_camera = entity.camera != null and primary_scene_camera != null and primary_scene_camera.? == entity.id;
        const icon_size: f32 = if (is_selected) 20.0 else 18.0;
        const halo_radius = icon_size * 0.72;

        if (is_selected) {
            draw_list.addCircleFilled(screen_pos, halo_radius + 5.0, gui.getColorU32(.{ accent[0], accent[1], accent[2], 0.18 }), 24);
        }
        if (is_primary_scene_camera) {
            draw_list.addCircleFilled(screen_pos, halo_radius + 2.5, gui.getColorU32(.{ accent[0], accent[1], accent[2], 0.24 }), 24);
        }
        draw_list.addCircleFilled(screen_pos, halo_radius, gui.getColorU32(.{ 0.05, 0.06, 0.08, 0.90 }), 24);
        draw_list.addCircleFilled(screen_pos, halo_radius - 2.0, gui.getColorU32(.{ accent[0] * 0.22, accent[1] * 0.22, accent[2] * 0.22, 0.92 }), 24);

        var button_id_buffer: [64]u8 = undefined;
        const button_id = std.fmt.bufPrint(&button_id_buffer, "viewport_entity_icon##{d}", .{entity.id}) catch continue;
        gui.setCursorScreenPos(.{ screen_pos[0] - icon_size * 0.5, screen_pos[1] - icon_size * 0.5 });
        const clicked = try drawViewportEntityIconButton(
            state,
            layer_context,
            button_id,
            viewportEntityIconPath(kind),
            icon_size,
            tint,
        );

        const hovered = gui.isItemHovered();
        if (hovered) {
            state.viewport_overlay_hovered = true;
            if (input.wasMousePressed(.left)) {
                state.manipulation_started_from_ui = true;
            }
            draw_list.addCircleFilled(screen_pos, halo_radius + 3.5, gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.10 }), 24);
            var tooltip_buffer: [320]u8 = undefined;
            const tooltip = if (entity.camera != null)
                std.fmt.bufPrint(&tooltip_buffer, "{s}\nDouble-click to look through camera", .{entity.name}) catch entity.name
            else
                std.fmt.bufPrint(&tooltip_buffer, "{s}", .{entity.name}) catch entity.name;
            gui.setTooltip(tooltip);
        }
        if (is_primary_scene_camera) {
            draw_list.addCircleFilled(
                .{ screen_pos[0] + halo_radius * 0.52, screen_pos[1] + halo_radius * 0.52 },
                3.5,
                gui.getColorU32(.{ 0.20, 0.92, 0.58, 0.98 }),
                16,
            );
        }

        if (clicked) {
            const mode = selectionUpdateModeForInput(input);
            switch (mode) {
                .replace => try layer_context.renderer.replaceSelection(entity.id),
                .toggle => try layer_context.renderer.toggleSelection(entity.id),
            }
            utils.syncInspectorNameBuffer(state, layer_context);
        }
        if (hovered and entity.camera != null and input.wasMouseDoubleClicked(.left)) {
            _ = camera.lookThroughCamera(state, layer_context, entity.id);
        }
    }
}

fn drawViewportToolbarStrip(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const width = gui.contentRegionAvail()[0];
    gui.pushStyleVarVec2(.item_spacing, .{ 6.0, 6.0 });
    defer gui.popStyleVar(1);

    if (try drawToolbarIconButton(state, layer_context, "toolbar_select", ui_icons.paths.toolbar.select, state.manipulation_mode == .none)) {
        try manipulation.selectTool(state, layer_context);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.select_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_move", ui_icons.paths.toolbar.move, state.manipulation_mode == .translate)) {
        try manipulation.beginManipulation(state, layer_context, .translate);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.move_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_rotate", ui_icons.paths.toolbar.rotate, state.manipulation_mode == .rotate)) {
        try manipulation.beginManipulation(state, layer_context, .rotate);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.rotate_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_scale", ui_icons.paths.toolbar.scale, state.manipulation_mode == .scale)) {
        try manipulation.beginManipulation(state, layer_context, .scale);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.scale_tool));
    }

    // 模式切换始终显示（不受宽度限制）
    gui.sameLine();
    try drawViewportModeZone(state, layer_context);

    // 右侧工具组：Undo Source + AI Status + AI Chat + Settings + Transform Space
    // 宽度经过压缩以允许工具栏在 ≥680px 时显示完整布局
    const undo_source_width: f32 = 96.0;
    const ai_status_width: f32 = 160.0;
    const settings_icon: f32 = 28.0;
    const transform_icon: f32 = 28.0;
    const ai_chat_icon: f32 = 28.0;

    if (width >= 680.0) {
        // 宽布局：完整显示所有元素
        const right_width = undo_source_width + 8.0 + ai_status_width + 8.0 + ai_chat_icon + 8.0 + settings_icon + 8.0 + transform_icon;
        gui.sameLine();
        gui.dummy(@max(gui.contentRegionAvail()[0] - right_width, 10.0), 1.0);
        gui.sameLine();
        drawToolbarUndoSourceChip(state);
        gui.sameLine();
        drawToolbarAiStatusCapsule(state);
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_ai_chat", ui_icons.paths.toolbar.ai_chat, state.ai_chat_open)) {
            state.ai_chat_open = !state.ai_chat_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.ai_chat));
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_settings", ui_icons.paths.toolbar.settings, state.render_settings_open)) {
            state.render_settings_open = !state.render_settings_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.render_settings));
        gui.sameLine();
        try drawTransformSpaceButton(state, layer_context, "toolbar_transform_space");
    } else if (width >= 460.0) {
        // 中等布局：省略 AI Status
        const right_width = undo_source_width + 8.0 + ai_chat_icon + 8.0 + settings_icon + 8.0 + transform_icon;
        gui.sameLine();
        gui.dummy(@max(gui.contentRegionAvail()[0] - right_width, 10.0), 1.0);
        gui.sameLine();
        drawToolbarUndoSourceChip(state);
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_ai_chat_m", ui_icons.paths.toolbar.ai_chat, state.ai_chat_open)) {
            state.ai_chat_open = !state.ai_chat_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.ai_chat));
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_settings_m", ui_icons.paths.toolbar.settings, state.render_settings_open)) {
            state.render_settings_open = !state.render_settings_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.render_settings));
        gui.sameLine();
        try drawTransformSpaceButton(state, layer_context, "toolbar_transform_space_m");
    } else {
        // 窄布局：只保留图标按钮
        const right_width = ai_chat_icon + 8.0 + settings_icon + 8.0 + transform_icon;
        gui.sameLine();
        gui.dummy(@max(gui.contentRegionAvail()[0] - right_width, 4.0), 1.0);
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_ai_chat_s", ui_icons.paths.toolbar.ai_chat, state.ai_chat_open)) {
            state.ai_chat_open = !state.ai_chat_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.ai_chat));
        gui.sameLine();
        if (try drawToolbarIconButton(state, layer_context, "toolbar_settings_s", ui_icons.paths.toolbar.settings, state.render_settings_open)) {
            state.render_settings_open = !state.render_settings_open;
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.render_settings));
        gui.sameLine();
        try drawTransformSpaceButton(state, layer_context, "toolbar_transform_space_s");
    }
}

fn drawTransformSpaceButton(state: *EditorState, layer_context: *engine.core.LayerContext, id: []const u8) !void {
    const transform_icon_path = switch (state.transform_space) {
        .local => ui_icons.paths.toolbar.transform_local,
        .world => ui_icons.paths.toolbar.transform_global,
    };
    const is_world = state.transform_space == .world;
    if (try drawToolbarIconButton(state, layer_context, id, transform_icon_path, is_world)) {
        state.transform_space = switch (state.transform_space) {
            .local => .world,
            .world => .local,
        };
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(if (is_world) state.text(.world_space) else state.text(.local_space));
    }
}

fn drawViewportModeZone(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    gui.pushStyleVarVec2(.item_spacing, .{ 4.0, 4.0 });
    defer gui.popStyleVar(1);

    const raster_active = state.viewport_pipeline_mode == .raster;
    const path_trace_active = state.viewport_pipeline_mode == .path_trace;

    if (drawModeButton("Raster##viewport_mode_raster", raster_active, 82.0)) {
        state.viewport_pipeline_mode = .raster;
    }
    gui.sameLine();
    if (drawModeButton("PathTrace##viewport_mode_pathtrace", path_trace_active, 92.0)) {
        state.viewport_pipeline_mode = .path_trace;
        state.viewport_render_mode = .textured;
        // 切换到 PathTrace 时强制同步当前场景状态并重新渲染，
        // 而 Raster 模式中的操作不会影响 PathTrace 渐进状态。
        layer_context.renderer.resetPathTraceState();
    }
}

fn drawModeButton(label: []const u8, active: bool, width: f32) bool {
    const palette = if (active)
        ui_icons.palettes.toolbar_active
    else
        ui_icons.palettes.toolbar_idle;
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    defer gui.popStyleColor(3);
    return gui.buttonEx(label, width, 0.0);
}

fn drawToolbarUndoSourceChip(state: *EditorState) void {
    const total_history_commands = state.undo_stack.items.len + state.redo_stack.items.len;
    const available_entries = @min(total_history_commands, state.timeline_entries.items.len);
    const timeline_start_index = state.timeline_entries.items.len -| available_entries;
    const cursor = state.undo_stack.items.len;
    const has_entry = cursor > 0 and available_entries > 0;
    const source = if (has_entry)
        state.timeline_entries.items[timeline_start_index + cursor - 1].source
    else
        timeline_mod.TimelineSource.human;
    const label = if (!has_entry)
        "Undo: —"
    else if (source == .ai)
        "Undo: AI"
    else
        "Undo: Human";

    gui.pushStyleColor(.button, .{ 0.16, 0.17, 0.19, 0.92 });
    gui.pushStyleColor(.button_hovered, .{ 0.16, 0.17, 0.19, 0.92 });
    gui.pushStyleColor(.button_active, .{ 0.16, 0.17, 0.19, 0.92 });
    gui.pushStyleColor(.text, source.colorRgba());
    defer gui.popStyleColor(4);
    _ = gui.buttonEx(label, 96.0, 0.0);
}

fn drawToolbarAiStatusCapsule(state: *EditorState) void {
    const store = state.ai_collaboration;
    const status = if (store) |value| value.aiStatusSnapshot() else null;
    const stage_label = if (status) |value|
        switch (value.stage) {
            .ready => "Ready",
            .analyzing_screenshot => "Analyzing Screenshot",
            .compiling_shader => "Compiling Shader",
            .waiting_approval => "Waiting Approval",
        }
    else
        "Offline";

    const detail = if (status) |value|
        if (value.detail.len > 0) value.detail.slice() else "idle"
    else
        "Bridge unavailable";

    var detail_short_buffer: [112]u8 = undefined;
    const detail_short: []const u8 = if (detail.len <= 16)
        detail
    else blk: {
        const prefix_len: usize = @min(13, detail.len);
        @memcpy(detail_short_buffer[0..prefix_len], detail[0..prefix_len]);
        detail_short_buffer[prefix_len] = '.';
        detail_short_buffer[prefix_len + 1] = '.';
        detail_short_buffer[prefix_len + 2] = '.';
        break :blk detail_short_buffer[0 .. prefix_len + 3];
    };

    var label_buffer: [192]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "AI: {s}", .{detail_short}) catch "AI";

    const bg: [4]f32 = if (store == null)
        .{ 0.32, 0.20, 0.20, 0.92 }
    else if (status != null and status.?.stage == .waiting_approval)
        .{ 0.30, 0.24, 0.45, 0.92 }
    else if (status != null and status.?.stage == .compiling_shader)
        .{ 0.30, 0.28, 0.18, 0.92 }
    else if (status != null and status.?.stage == .analyzing_screenshot)
        .{ 0.19, 0.30, 0.40, 0.92 }
    else
        .{ 0.18, 0.33, 0.25, 0.92 };

    gui.pushStyleColor(.button, bg);
    gui.pushStyleColor(.button_hovered, bg);
    gui.pushStyleColor(.button_active, bg);
    defer gui.popStyleColor(3);
    _ = gui.buttonEx(label, 160.0, 0.0);
    if (gui.isItemHovered()) {
        var tip_buffer: [448]u8 = undefined;
        const tip = std.fmt.bufPrint(&tip_buffer, "Stage: {s}\nDetail: {s}", .{ stage_label, detail }) catch detail;
        gui.setTooltip(tip);
    }
}

pub fn drawViewportWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport, "viewport_panel");

    gui.pushStyleVarVec2(.window_padding, .{ 0.0, 0.0 });
    defer gui.popStyleVar(1);

    _ = gui.beginWindowFlags(
        title,
        gui.WindowFlags.no_collapse |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_scroll_with_mouse,
    );
    defer gui.endWindow();

    // Draw toolbar first (at top)
    try drawViewportToolbarStrip(state, layer_context);

    // Calculate remaining space for 3D viewport
    const content_size = gui.contentRegionAvail();
    state.viewport_origin = gui.cursorScreenPos();
    state.viewport_extent = .{ content_size[0], content_size[1] };
    const window_hovered = gui.isWindowHovered();
    state.viewport_focused = gui.isWindowFocused();
    if (!layer_context.input.isMouseDown(.left)) {
        state.manipulation_started_from_ui = false;
    }
    state.viewport_has_image = false;
    state.viewport_overlay_hovered = false;

    // Use ImGui mouse coordinates so hover/mouse hit-testing stays in the same space
    // as the docked viewport item on HiDPI platforms.
    var mouse_pos = effectiveViewportMousePos(layer_context);
    state.viewport_hovered = window_hovered and isPointInViewportRect(mouse_pos, state.viewport_origin, state.viewport_extent);

    const drawable_size = if (state.render_output_job_stage == .resize_and_render)
        render_settings.resolveRenderOutputDimensions(state, layer_context)
    else
        utils.viewportDrawableSize(layer_context.window, state.viewport_extent);
    try layer_context.renderer.setSceneViewportSize(drawable_size[0], drawable_size[1]);
    if (state.render_output_job_stage == .resize_and_render) {
        if (state.viewport_pipeline_mode == .path_trace) {
            const progress = layer_context.renderer.pathTraceRenderProgress();
            const progress_percent: u32 = @intFromFloat(std.math.clamp(progress.fraction, 0.0, 1.0) * 100.0);
            if (progress.complete) {
                state.render_output_job_stage = .export_pending;
            }
            if (state.render_output_job_is_sequence) {
                setRenderOutputStatusFmt(
                    state,
                    .rendering,
                    "Rendering frame {d}/{d} at {d} x {d} ({d}%)",
                    .{ state.render_output_job_frame_index + 1, state.render_output_job_total_frames, drawable_size[0], drawable_size[1], progress_percent },
                );
            } else {
                setRenderOutputStatusFmt(state, .rendering, "Rendering {d} x {d} ({d}%)", .{ drawable_size[0], drawable_size[1], progress_percent });
            }
        } else {
            state.render_output_job_stage = .export_pending;
            if (state.render_output_job_is_sequence) {
                setRenderOutputStatusFmt(
                    state,
                    .rendering,
                    "Rendering frame {d}/{d} at {d} x {d}",
                    .{ state.render_output_job_frame_index + 1, state.render_output_job_total_frames, drawable_size[0], drawable_size[1] },
                );
            } else {
                setRenderOutputStatusFmt(state, .rendering, "Rendering {d} x {d}", .{ drawable_size[0], drawable_size[1] });
            }
        }
    }

    if (layer_context.renderer.sceneViewportTexture()) |texture| {
        const image_size = .{
            @max(state.viewport_extent[0], 8.0),
            @max(state.viewport_extent[1], 8.0),
        };
        gui.image(texture, image_size[0], image_size[1]);
        const image_min = gui.getItemRectMin();
        const image_max = gui.getItemRectMax();
        state.viewport_origin = image_min;
        state.viewport_extent = .{
            @max(image_max[0] - image_min[0], 0.0),
            @max(image_max[1] - image_min[1], 0.0),
        };
        mouse_pos = effectiveViewportMousePos(layer_context);
        state.viewport_hovered = gui.isItemHovered() and isPointInViewportRect(mouse_pos, state.viewport_origin, state.viewport_extent);
        state.viewport_has_image = true;

        // Draw overlays (positioned absolutely, won't affect layout)
        try handleViewportAssetDropTargets(state, layer_context);
        try drawViewportOverlayControlsWindow(state, layer_context);
        drawViewportAiStateOverlayWindow(state);
        try drawViewportPlaybackOverlayWindow(state, layer_context);
        try drawViewportFpsOverlayWindow(state, layer_context);
        try drawViewportDebugOverlayWindow(state, layer_context);
        try ai_collaboration.drawViewportCollaborationOverlay(state, layer_context);
        try drawViewportSceneEntityIcons(state, layer_context);
        drawViewportViewCube(state, layer_context);
        logViewportStateChange(state, layer_context);

        // 视口右键上下文菜单
        try drawViewportContextMenu(state, layer_context);
    } else {
        gui.text(state.text(.viewport_target_is_not_ready_yet));
        logViewportStateChange(state, layer_context);
    }
}

pub fn drawStatsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .stats, "stats_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    const runtime = layer_context.renderer.runtimeInfo();
    const summary = layer_context.world.summary();
    const fps = if (layer_context.delta_seconds > 0.0001) 1.0 / layer_context.delta_seconds else 0.0;

    var fps_buffer: [64]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
    gui.labelText(state.text(.fps), fps_text);
    gui.labelText(state.text(.backend), engine.render.graphicsApiName(layer_context.renderer.backendApi()));
    gui.labelText(state.text(.device), runtime.deviceName());

    var draw_size_buffer: [64]u8 = undefined;
    const draw_size_text = try std.fmt.bufPrint(
        &draw_size_buffer,
        "{d} x {d}",
        .{ runtime.drawable_width, runtime.drawable_height },
    );
    gui.labelText(state.text(.drawable), draw_size_text);

    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_size_buffer: [64]u8 = undefined;
    const viewport_size_text = try std.fmt.bufPrint(
        &viewport_size_buffer,
        "{d} x {d}",
        .{ viewport_size[0], viewport_size[1] },
    );
    gui.labelText(state.text(.viewport), viewport_size_text);

    var entities_buffer: [32]u8 = undefined;
    const entities_text = try std.fmt.bufPrint(&entities_buffer, "{d}", .{summary.entity_count});
    gui.labelText(state.text(.entities), entities_text);

    var meshes_buffer: [32]u8 = undefined;
    const meshes_text = try std.fmt.bufPrint(&meshes_buffer, "{d}", .{summary.mesh_count});
    gui.labelText(state.text(.meshes), meshes_text);

    var lights_buffer: [32]u8 = undefined;
    const lights_text = try std.fmt.bufPrint(&lights_buffer, "{d}", .{summary.light_count});
    gui.labelText(state.text(.lights), lights_text);

    var cameras_buffer: [32]u8 = undefined;
    const cameras_text = try std.fmt.bufPrint(&cameras_buffer, "{d}", .{summary.camera_count});
    gui.labelText(state.text(.cameras), cameras_text);
}

pub fn drawStatusBarWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const window_width = @as(f32, @floatFromInt(layer_context.window.logical_width));
    const height = 38.0;
    gui.setNextWindowPos(.{ 0.0, @as(f32, @floatFromInt(layer_context.window.logical_height)) - height });
    gui.setNextWindowSize(.{ window_width, height });
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .status_bar, "status_bar_panel");
    _ = gui.beginWindowFlags(
        title,
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_collapse |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking,
    );
    defer gui.endWindow();

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

    const status_context_ratio = viewport_status.statusBarContextRatio(window_width);
    const status_metrics_ratio = 1.0 - status_context_ratio;
    const context_width = window_width * status_context_ratio;
    const metrics_width = @max(window_width - context_width, 0.0);

    var compact_path_buffer: [160]u8 = undefined;
    const compact_path = viewport_status.compactStatusPath(
        &compact_path_buffer,
        selected_path,
        viewport_status.statusPathCharacterBudget(context_width),
    );

    var metrics_buffer: [320]u8 = undefined;
    var metrics_stream = std.io.fixedBufferStream(&metrics_buffer);
    try viewport_status.buildStatusMetricsText(
        metrics_stream.writer(),
        state,
        selection_count,
        fps,
        save_status,
        backend_text,
        memory_text,
        metrics_width,
    );
    const metrics_text = metrics_stream.getWritten();

    var context_buffer: [384]u8 = undefined;
    var context_stream = std.io.fixedBufferStream(&context_buffer);
    try viewport_status.buildStatusContextText(
        context_stream.writer(),
        state,
        compact_path,
        camera_text,
        mode_text,
        space_text,
        context_width,
    );
    const context_text = context_stream.getWritten();

    gui.pushStyleVarVec2(.item_spacing, .{ 8.0, 0.0 });
    defer gui.popStyleVar(1);
    gui.setCursorPos(.{ 0.0, 3.0 });
    if (gui.beginTable("status_bar_layout", 2)) {
        defer gui.endTable();
        gui.tableSetupColumn("##status_context", true, status_context_ratio);
        gui.tableSetupColumn("##status_metrics", true, status_metrics_ratio);
        gui.tableNextRow();
        gui.tableNextColumn();
        gui.alignTextToFramePadding();
        gui.text(context_text);
        gui.tableNextColumn();
        gui.alignTextToFramePadding();
        gui.text(metrics_text);
    }
}

pub fn handleViewportSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;
    if (input.wasMousePressed(.left)) {
        // Gizmo axis click: test on press so drag can begin immediately
        if (state.manipulation_mode != .none and
            state.viewport_has_image and state.viewport_hovered and
            !state.viewport_overlay_hovered and !input.modifiers.alt and
            !state.manipulation_drag_active)
        {
            if (viewportPixelUnderMouse(state, layer_context)) |pixel| {
                const viewport_size = layer_context.renderer.sceneViewportSize();
                if (camera.activeCameraRayFromViewportPixel(state, layer_context, pixel, viewport_size)) |ray| {
                    if (manipulation.pickGizmoHandle(state, layer_context, ray)) |picked_handle| {
                        viewport_log.info("picked gizmo handle axis={s} mode={s}", .{ @tagName(picked_handle.axis), @tagName(picked_handle.mode) });
                        try manipulation.beginManipulationFromPickedGizmoHandle(state, layer_context, picked_handle, ray);
                        return;
                    }
                }
            }
        }

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
            if (try ai_collaboration.trySelectPreviewEntity(state, layer_context, ray, mode)) {
                viewport_log.info("preview selection hit mode={s}", .{@tagName(mode)});
                return;
            }
            if (mode == .replace and state.ai_preview_selected_entity != null) {
                ai_collaboration.clearPreviewSelectionState(state, layer_context);
            }
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
        !state.manipulation_drag_active and
        !state.manipulation_keyboard_mode;
}

fn selectionUpdateModeForInput(input: *const engine.core.InputState) engine.render.SelectionUpdateMode {
    return if (input.modifiers.shift or input.modifiers.ctrl or input.modifiers.super)
        .toggle
    else
        .replace;
}

/// 视口右键上下文菜单（仅在右键无拖拽时弹出，不干扰摄像机操作）
fn drawViewportContextMenu(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;
    const context_menu_id = "viewport_context_menu";

    // 右键按下时记录位置
    if (input.wasMousePressed(.right) and state.viewport_hovered and
        !state.viewport_overlay_hovered and !input.modifiers.alt)
    {
        state.viewport_context_menu_pending = true;
        state.viewport_context_menu_mouse = input.mouse_position;
    }

    // 右键释放时判断是否为无拖拽点击（阈值 4px）
    if (state.viewport_context_menu_pending and !input.isMouseDown(.right)) {
        defer {
            state.viewport_context_menu_pending = false;
        }
        const dx = input.mouse_position[0] - state.viewport_context_menu_mouse[0];
        const dy = input.mouse_position[1] - state.viewport_context_menu_mouse[1];
        if (dx * dx + dy * dy <= 16.0) {
            gui.openPopup(context_menu_id);
        }
    }

    if (gui.beginPopup(context_menu_id)) {
        defer gui.endPopup();
        const has_selection = layer_context.renderer.selectedEntities().len > 0;

        if (gui.menuItem(state.text(.focus), "F", false, has_selection)) {
            camera.focusSelection(state, layer_context);
        }
        gui.separator();
        if (gui.menuItem(state.text(.select_tool), "Q", state.manipulation_mode == .none, true)) {
            try manipulation.selectTool(state, layer_context);
        }
        if (gui.menuItem(state.text(.move_tool), "W", state.manipulation_mode == .translate, true)) {
            try manipulation.beginManipulation(state, layer_context, .translate);
        }
        if (gui.menuItem(state.text(.rotate_tool), "E", state.manipulation_mode == .rotate, true)) {
            try manipulation.beginManipulation(state, layer_context, .rotate);
        }
        if (gui.menuItem(state.text(.scale_tool), "R", state.manipulation_mode == .scale, true)) {
            try manipulation.beginManipulation(state, layer_context, .scale);
        }
        gui.separator();
        if (gui.menuItem(state.text(.delete), null, false, has_selection)) {
            try history.deleteSelection(state, layer_context);
        }
        if (gui.menuItem(state.text(.duplicate), null, false, has_selection)) {
            try history.duplicateSelection(state, layer_context);
        }
    }
}

pub fn drawEditorUi(
    state: *EditorState,
    post_process_state: *const engine.render.EditorViewportState,
    layer_context: *engine.core.LayerContext,
) !void {
    try syncPlaybackState(state, layer_context);
    try syncRenderOutputJob(state, layer_context);
    syncViewportState(state, post_process_state, layer_context);
    try applyPendingViewportAssetDrop(state, layer_context);

    // Shell Layer 1: Top Bar
    floating_window_blocker.beginFrame();
    try menu_bar.drawMenuBar(state, layer_context);

    // Shell Layer 2: Main Workspace (center + left + right panels)
    try drawViewportWindow(state, layer_context);
    try drawLeftSidebar(state, layer_context);
    try drawRightSidebar(state, layer_context);

    // Shell Layer 3: Bottom Workspace
    try content_browser.drawContentBrowser(state, layer_context);

    // Shell Layer 4: Auxiliary / Floating Windows
    try drawAuxiliaryWindows(state, layer_context);
    try menu_bar.resolvePendingTopBarDrag(state, layer_context);

    // Shell Layer 5: Status Bar (pinned bottom)
    try drawStatusBarWindow(state, layer_context);
}

/// Left sidebar: Scene Hierarchy + Place Actors
fn drawLeftSidebar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try scene_hierarchy.drawSceneWindow(state, layer_context);
    try place_actors.drawPlaceActorsWindow(state, layer_context);
}

/// Right sidebar: Inspector / Details
fn drawRightSidebar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try inspector.drawInspectorWindow(state, layer_context);
}

/// Auxiliary floating / tool windows (toggled via state flags)
fn drawAuxiliaryWindows(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    // AI assistant
    try ai_chat.drawAiChatPanel(state, layer_context);

    // Rendering tools
    if (state.render_settings_open) {
        try render_settings.drawRenderSettingsWindow(state, layer_context);
    }

    // Editor settings
    if (state.settings_open) {
        try settings.drawSettingsWindow(state, layer_context);
    }

    // Asset tools
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

fn syncViewportState(
    state: *EditorState,
    post_process_state: *const engine.render.EditorViewportState,
    layer_context: *engine.core.LayerContext,
) void {
    layer_context.renderer.setEditorViewportState(.{
        .pipeline_mode = switch (state.viewport_pipeline_mode) {
            .raster => .raster,
            .path_trace => .path_trace,
        },
        .path_trace_samples = state.viewport_path_trace_samples,
        .path_trace_bounces = state.viewport_path_trace_bounces,
        .path_trace_resolution_scale = state.viewport_path_trace_resolution_scale,
        .render_mode = switch (state.viewport_render_mode) {
            .textured => .textured,
            .wireframe => .wireframe,
            .unlit => .unlit,
        },
        .show_grid = state.viewport_show_grid,
        .show_bones = state.viewport_show_bones,
        .show_collision = state.viewport_show_collision,
        .show_collision_bvh = post_process_state.show_collision_bvh,
        .show_constraints = post_process_state.show_constraints,
        .exposure_enabled = post_process_state.exposure_enabled,
        .exposure = post_process_state.exposure,
        .bloom_enabled = post_process_state.bloom_enabled,
        .bloom_threshold = post_process_state.bloom_threshold,
        .bloom_intensity = post_process_state.bloom_intensity,
        .ssao_enabled = post_process_state.ssao_enabled,
        .ssao_use_legacy_path = post_process_state.ssao_use_legacy_path,
        .ssao_radius = post_process_state.ssao_radius,
        .ssao_bias = post_process_state.ssao_bias,
        .ssao_intensity = post_process_state.ssao_intensity,
        .ssao_power = post_process_state.ssao_power,
        .contact_shadows_enabled = post_process_state.contact_shadows_enabled,
        .contact_shadows_distance = post_process_state.contact_shadows_distance,
        .contact_shadows_thickness = post_process_state.contact_shadows_thickness,
        .contact_shadows_intensity = post_process_state.contact_shadows_intensity,
        .contact_shadows_bias = post_process_state.contact_shadows_bias,
        .contact_shadows_steps = post_process_state.contact_shadows_steps,
        .ssr_enabled = post_process_state.ssr_enabled,
        .ssr_intensity = post_process_state.ssr_intensity,
        .ssr_ray_step = post_process_state.ssr_ray_step,
        .ssr_ray_max_distance = post_process_state.ssr_ray_max_distance,
        .ssr_ray_thickness = post_process_state.ssr_ray_thickness,
        .ssr_fade_distance = post_process_state.ssr_fade_distance,
        .ssr_edge_fade = post_process_state.ssr_edge_fade,
        .ssgi_enabled = post_process_state.ssgi_enabled,
        .ssgi_radius = post_process_state.ssgi_radius,
        .ssgi_intensity = post_process_state.ssgi_intensity,
        .ssgi_bias = post_process_state.ssgi_bias,
        .ssgi_ray_count = post_process_state.ssgi_ray_count,
        .ssgi_step_count = post_process_state.ssgi_step_count,
        .taa_enabled = post_process_state.taa_enabled,
        .taa_blend_factor = post_process_state.taa_blend_factor,
        .taa_motion_blur_scale = post_process_state.taa_motion_blur_scale,
        .taa_feedback_min = post_process_state.taa_feedback_min,
        .taa_feedback_max = post_process_state.taa_feedback_max,
        .dof_enabled = post_process_state.dof_enabled,
        .dof_focus_distance = post_process_state.dof_focus_distance,
        .dof_focus_range = post_process_state.dof_focus_range,
        .dof_blur_radius = post_process_state.dof_blur_radius,
        .dof_bokeh_radius = post_process_state.dof_bokeh_radius,
        .dof_near_blur = post_process_state.dof_near_blur,
        .dof_far_blur = post_process_state.dof_far_blur,
        .dof_quality = post_process_state.dof_quality,
        .omni_shadow_enabled = post_process_state.omni_shadow_enabled,
        .omni_shadow_resolution = post_process_state.omni_shadow_resolution,
        .omni_shadow_far_plane = post_process_state.omni_shadow_far_plane,
        .color_grading_enabled = post_process_state.color_grading_enabled,
        .color_grading_saturation = post_process_state.color_grading_saturation,
        .color_grading_contrast = post_process_state.color_grading_contrast,
        .color_grading_gamma = post_process_state.color_grading_gamma,
        .fxaa_enabled = post_process_state.fxaa_enabled,
        .rt_shadows_enabled = post_process_state.rt_shadows_enabled,
        .rt_shadow_samples = post_process_state.rt_shadow_samples,
        .rt_shadow_strength = post_process_state.rt_shadow_strength,
        .rt_shadow_softness = post_process_state.rt_shadow_softness,
        .rt_shadow_resolution_scale = post_process_state.rt_shadow_resolution_scale,
        .volumetric_fog_enabled = post_process_state.volumetric_fog_enabled,
        .volumetric_fog_density = post_process_state.volumetric_fog_density,
        .volumetric_fog_height_falloff = post_process_state.volumetric_fog_height_falloff,
        .volumetric_fog_max_distance = post_process_state.volumetric_fog_max_distance,
        .lut_enabled = post_process_state.lut_enabled,
        .lut_intensity = post_process_state.lut_intensity,
        .lut_preset = post_process_state.lut_preset,
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
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarVec2(.frame_padding, ui_icons.regular_icon_button_padding);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.regular_icon_button_rounding);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    return gui.imageButton(id, texture, 14.0, 14.0, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
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
                .textured_cube => try history.spawnPrimitiveAt(state, layer_context, .cube, spawn_transform),
                .textured_sphere => try history.spawnPrimitiveAt(state, layer_context, .sphere, spawn_transform),
                .textured_plane => try history.spawnPrimitiveAt(state, layer_context, .plane, spawn_transform),
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

            if (layer_context.physics_state.raycast(layer_context.world, .{
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
        .cube, .sphere, .textured_cube, .textured_sphere => .{ 0.5, 0.5, 0.5 },
        .plane, .textured_plane => .{ 0.5, 0.05, 0.5 },
        .empty, .camera, .point_light, .spot_light, .directional_light, .vfx_fountain, .vfx_orbit => .{ 0.25, 0.25, 0.25 },
    };
}

fn physicsAwareSpawnTransform(
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    half_extents: [3]f32,
) !?engine.scene.Transform {
    const surface_hit = layer_context.physics_state.raycast(layer_context.world, .{
        .origin = ray.origin,
        .direction = ray.direction,
        .max_distance = 2048.0,
    }, .{}) orelse return null;

    const sweep_start = vec3.add(ray.origin, vec3.scale(ray.direction, 0.05));
    const sweep_distance = @max(surface_hit.distance - 0.05, 0.0) + vec3.length(half_extents) + 0.5;
    const sweep_bounds = engine.physics.aabbFromCenterHalfExtents(sweep_start, half_extents);
    const sweep_hit = layer_context.physics_state.sweepAabb(
        layer_context.world,
        sweep_bounds,
        vec3.scale(ray.direction, sweep_distance),
        .{},
    ) orelse return .{ .translation = surface_hit.position };

    const candidate_translation = vec3.add(sweep_start, vec3.scale(ray.direction, sweep_hit.distance));
    const candidate_bounds = engine.physics.aabbFromCenterHalfExtents(candidate_translation, half_extents);
    const overlaps = try layer_context.physics_state.overlapAabb(
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
    if (gui.acceptDragDropPayloadU64(state_mod.asset_model_drag_payload, &asset_index)) {
        state.pending_viewport_drop = .{
            .source_kind = .asset,
            .asset_index = @as(usize, @intCast(asset_index)),
            .pixel = viewportPixelUnderMouse(state, layer_context),
        };
        return;
    }
    if (gui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &asset_index)) {
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
    if (gui.acceptDragDropPayloadU64(state_mod.asset_material_drag_payload, &asset_index)) {
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
    if (gui.acceptDragDropPayloadU64(state_mod.place_actor_drag_payload, &actor_kind_int)) {
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
    const view_popup_open = gui.isPopupOpen(view_popup_id);
    const render_popup_open = gui.isPopupOpen(render_popup_id);
    const overlay_popup_open = gui.isPopupOpen(overlay_popup_id);

    const overlay_pos = .{
        state.viewport_origin[0] + 14.0,
        state.viewport_origin[1] + viewportOverlayTopInset(),
    };
    gui.setNextWindowPos(overlay_pos);
    gui.setNextWindowBgAlpha(0.6);
    _ = gui.beginWindowFlags(
        "##viewport_overlay_controls",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking |
            gui.WindowFlags.always_auto_resize,
    );
    defer gui.endWindow();

    gui.pushStyleVarVec2(.item_spacing, .{ 6.0, 4.0 });
    defer gui.popStyleVar(1);

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_view", currentViewPresetIcon(state), view_popup_open)) {
        gui.openPopup(view_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.view_presets));
    }
    if (gui.beginPopup(view_popup_id)) {
        defer gui.endPopup();
        if (gui.menuItem(state.text(.perspective_view), null, state.viewport_view_preset == .perspective, true)) {
            camera.setViewPreset(state, layer_context, .perspective);
        }
        if (gui.menuItem(state.text(.top_view), null, state.viewport_view_preset == .top, true)) {
            camera.setViewPreset(state, layer_context, .top);
        }
        if (gui.menuItem(state.text(.side_view), null, state.viewport_view_preset == .side, true)) {
            camera.setViewPreset(state, layer_context, .side);
        }
    }
    gui.sameLine();

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_render", currentRenderModeIcon(state), render_popup_open)) {
        gui.openPopup(render_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.render_modes));
    }
    if (gui.beginPopup(render_popup_id)) {
        defer gui.endPopup();
        if (gui.menuItem(state.text(.textured), null, state.viewport_render_mode == .textured, true)) {
            state.viewport_render_mode = .textured;
        }
        if (gui.menuItem(state.text(.wireframe), null, state.viewport_render_mode == .wireframe, true)) {
            state.viewport_render_mode = .wireframe;
        }
        if (gui.menuItem(state.text(.unlit), null, state.viewport_render_mode == .unlit, true)) {
            state.viewport_render_mode = .unlit;
        }
    }
    gui.sameLine();

    if (try drawOverlayIconButton(state, layer_context, "viewport_overlay_options", ui_icons.paths.toolbar.overlay, overlay_popup_open)) {
        gui.openPopup(overlay_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.overlay_options));
    }
    if (gui.beginPopup(overlay_popup_id)) {
        defer gui.endPopup();
        if (gui.menuItem(state.text(.show_grid), null, state.viewport_show_grid, true)) {
            state.viewport_show_grid = !state.viewport_show_grid;
        }
        if (gui.menuItem(state.text(.show_bones), null, state.viewport_show_bones, true)) {
            state.viewport_show_bones = !state.viewport_show_bones;
        }
        if (gui.menuItem(state.text(.show_collision), null, state.viewport_show_collision, true)) {
            state.viewport_show_collision = !state.viewport_show_collision;
        }
    }
    gui.sameLine();

    // Note: Transform tools and transform space are now in the toolbar strip above the viewport
    // Only snap buttons remain in overlay

    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_translate", ui_icons.paths.toolbar.snap_translate, state.translation_snap_enabled)) {
        state.translation_snap_enabled = !state.translation_snap_enabled;
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.translation_snap));
    }
    gui.sameLine();
    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_rotate", ui_icons.paths.toolbar.snap_rotate, state.rotation_snap_enabled)) {
        state.rotation_snap_enabled = !state.rotation_snap_enabled;
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.rotation_snap));
    }
    gui.sameLine();
    if (try drawOverlayIconButton(state, layer_context, "viewport_snap_scale", ui_icons.paths.toolbar.snap_scale, state.scale_snap_enabled)) {
        state.scale_snap_enabled = !state.scale_snap_enabled;
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.scale_snap));
    }

    // Show camera speed indicator when shift is held
    if (layer_context.input.modifiers.shift) {
        gui.sameLine();
        gui.text("3x");
    }

    if (view_popup_open or render_popup_open or overlay_popup_open) {
        state.viewport_overlay_hovered = true;
    }
}

fn drawViewportPlaybackOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const window_width = 128.0;
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + @max((state.viewport_extent[0] - window_width) * 0.5, 18.0),
        state.viewport_origin[1] + 10.0,
    });
    gui.setNextWindowBgAlpha(0.6);
    _ = gui.beginWindowFlags(
        "##viewport_playback_overlay",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking |
            gui.WindowFlags.always_auto_resize,
    );
    defer gui.endWindow();

    // Overlay hover should always block viewport world interactions.
    const input = layer_context.input;
    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }
    if (gui.isWindowHovered() and input.wasMousePressed(.left)) {
        state.manipulation_started_from_ui = true;
    }

    const session_active = state.play_mode_active or state.playback_state != .stopped;
    const is_playing = state.playback_state == .playing;
    const is_paused = state.playback_state == .paused;

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        if (session_active) "viewport_stop_toggle" else "viewport_run_toggle",
        if (session_active) ui_icons.paths.toolbar.stop else ui_icons.paths.toolbar.play,
        if (is_playing)
            activePlayPalette()
        else if (session_active)
            activePausePalette()
        else
            idlePlaybackPalette(),
    )) {
        if (session_active) {
            playback_session.stop(state, layer_context);
        } else {
            try playback_session.play(state, layer_context);
        }
    }
    if (gui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;

    gui.sameLine();
    if (gui.isWindowHovered() and input.wasMousePressed(.left)) {
        state.manipulation_started_from_ui = true;
    }

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        if (is_paused) "viewport_resume" else "viewport_pause",
        if (is_paused) ui_icons.paths.toolbar.play else ui_icons.paths.toolbar.pause,
        if (is_paused) activePausePalette() else idlePlaybackPalette(),
    )) {
        if (is_paused) {
            try playback_session.play(state, layer_context);
        } else {
            playback_session.pause(state, layer_context);
        }
    }
    if (gui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;

    gui.sameLine();
    if (gui.isWindowHovered() and input.wasMousePressed(.left)) {
        state.manipulation_started_from_ui = true;
    }

    if (try drawPlaybackToolbarIconButton(
        state,
        layer_context,
        "viewport_step",
        ui_icons.paths.toolbar.step,
        stepPlaybackPalette(),
    )) {
        try playback_session.step(state, layer_context);
    }
    if (gui.isItemHovered() or (state.manipulation_started_from_ui and input.isMouseDown(.left))) state.viewport_overlay_hovered = true;
}

fn drawViewportAiStateOverlayWindow(state: *EditorState) void {
    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();

    // Only show capsule when AI is actively doing something or waiting approval.
    // Hide when ready to keep the viewport uncluttered.
    const show = ai_status.stage != .ready;
    if (!show) return;

    const stage_label: []const u8 = switch (ai_status.stage) {
        .ready => return,
        .analyzing_screenshot => "👀  Analyzing Screenshot...",
        .compiling_shader => "⚙  Compiling Shader...",
        .waiting_approval => "◆  Waiting Approval",
    };

    // Background colour: green→blue→amber→purple by stage
    const base_color: [4]f32 = switch (ai_status.stage) {
        .ready => .{ 0.20, 0.56, 0.36, 0.88 },
        .analyzing_screenshot => .{ 0.14, 0.38, 0.58, 0.90 },
        .compiling_shader => .{ 0.42, 0.30, 0.12, 0.90 },
        .waiting_approval => .{ 0.38, 0.18, 0.60, 0.94 },
    };

    // Pulse speed: faster when waiting approval to draw attention
    const pulse_speed: f32 = if (ai_status.stage == .waiting_approval) 2.6 else 3.2;
    const pulse = 0.06 * (std.math.sin(gui.time() * pulse_speed) + 1.0);
    const bg_alpha = std.math.clamp(base_color[3] + pulse, 0.0, 1.0);

    const overlay_width: f32 = if (ai_status.stage == .waiting_approval) 320.0 else 280.0;
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + @max((state.viewport_extent[0] - overlay_width) * 0.5, 12.0),
        state.viewport_origin[1] + 10.0,
    });
    gui.setNextWindowBgAlpha(bg_alpha);
    _ = gui.beginWindowFlags(
        "##viewport_ai_state_hud",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking |
            gui.WindowFlags.always_auto_resize |
            gui.WindowFlags.no_scrollbar,
    );
    defer gui.endWindow();

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    // Stage label
    gui.pushStyleColor(.text, .{ 0.96, 0.97, 1.0, 1.0 });
    gui.text(stage_label);
    gui.popStyleColor(1);

    // Detail line (when available)
    if (ai_status.detail.len > 0) {
        const detail = ai_status.detail.slice();
        // Clamp detail to one line
        const max_chars: usize = 44;
        gui.pushStyleColor(.text, .{ 0.74, 0.78, 0.86, 0.90 });
        if (detail.len <= max_chars) {
            gui.text(detail);
        } else {
            var short: [max_chars + 3]u8 = undefined;
            @memcpy(short[0..max_chars], detail[0..max_chars]);
            @memcpy(short[max_chars..], "...");
            gui.text(&short);
        }
        gui.popStyleColor(1);
    }

    // Ghost Highlight indicator when waiting approval and enabled
    if (ai_status.stage == .waiting_approval and state.ghost_highlight_enabled) {
        const ghost_pulse = 0.45 + 0.55 * @abs(std.math.sin(gui.time() * state.ghost_highlight_pulse_speed));
        gui.pushStyleColor(.text, .{ 0.75 * ghost_pulse, 0.38 * ghost_pulse, 1.0 * ghost_pulse, 1.0 });
        gui.text("◆ Ghost Highlight active");
        gui.popStyleColor(1);
    }
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
    const imgui_mouse_pos = gui.mousePos();
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
        state.viewport_extent[1] - gui.frameHeight() - 22.0,
        viewportOverlayTopInset() + 56.0,
    );

    gui.pushStyleVarVec2(.window_padding, .{ 10.0, 6.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + overlay_margin,
        overlay_y,
    });
    gui.setNextWindowBgAlpha(0.72);
    _ = gui.beginWindowFlags(
        "##viewport_fps_overlay",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking |
            gui.WindowFlags.always_auto_resize,
    );
    defer gui.endWindow();

    gui.text(fps_text);
}

fn drawViewportDebugOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.viewport_debug_overlay) {
        return;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    const overlay_size = [2]f32{ 332.0, 184.0 };
    var debug_text_buffer: [512]u8 = undefined;
    const debug_text = try buildViewportDebugText(&debug_text_buffer, state, layer_context);

    gui.pushStyleVarVec2(.window_padding, .{ 10.0, 8.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + @max(state.viewport_extent[0] - overlay_size[0] - 16.0, 16.0),
        state.viewport_origin[1] + @max(state.viewport_extent[1] - overlay_size[1] - 16.0, viewportOverlayTopInset() + 56.0),
    });
    gui.setNextWindowSize(overlay_size);
    gui.setNextWindowBgAlpha(0.80);
    _ = gui.beginWindowFlags(
        "##viewport_debug_overlay",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking,
    );
    defer gui.endWindow();

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    gui.text(state.text(.viewport_debug_overlay));
    gui.sameLineEx(220.0, 10.0);
    if (gui.buttonEx(state.text(.copy), 92.0, 0.0)) {
        copyDebugTextToClipboard(allocator, debug_text) catch {
            std.log.err("failed to copy viewport debug text to clipboard", .{});
        };
    }
    if (gui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
    }
    gui.separator();

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
    gui.labelText("Flags", flags_text);

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
    gui.labelText("Mouse", mouse_text);

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
    gui.labelText("Wheel", wheel_text);
    gui.labelText("Camera", camera_text);
    gui.labelText("Tool", tool_text);

    var selection_buffer: [96]u8 = undefined;
    const selection_text = try std.fmt.bufPrint(
        &selection_buffer,
        "count={d} selected={s}",
        .{
            layer_context.renderer.selectedEntities().len,
            debugSelectedEntityText(state, layer_context),
        },
    );
    gui.labelText("Selection", selection_text);

    gui.labelText("Manip", debugManipulationEntityText(state));
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
    const result = gui.drawViewCube(&view, cube_pos, cube_size);
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
