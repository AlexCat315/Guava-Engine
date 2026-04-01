const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const sdl = engine.platform.sdl.c;
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const mesh_edit = @import("../interaction/mesh_edit.zig");
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
const ai_chat = @import("panels/ai/ai_chat.zig");
const ui_icons = @import("icons.zig");
const layout = @import("layout.zig");
const playback_session = @import("../core/playback_session.zig");
const viewport_log = std.log.scoped(.viewport_input);
const ViewportShadingMode = state_mod.ViewportShadingMode;

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
    const accent_tint = [4]u8{ 230, 236, 242, 255 };
    const idle_tint = [4]u8{ 168, 174, 182, 255 };
    const texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        path,
        14.0,
        if (active) accent_tint else idle_tint,
    );
    const palette = if (active)
        hudActivePalette()
    else
        hudIdlePalette();
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarVec2(.frame_padding, .{ 7.0, 5.0 });
    gui.pushStyleVarFloat(.frame_rounding, 4.0);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    const clicked = gui.imageButton(id, texture, 14.0, 14.0, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
    if (gui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }
    return clicked;
}

fn hudIdlePalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.15, 0.16, 0.18, 0.90 },
        .hovered = .{ 0.20, 0.22, 0.25, 0.96 },
        .active = .{ 0.12, 0.14, 0.17, 1.0 },
    };
}

fn hudActivePalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.20, 0.60, 0.45, 0.20 },
        .hovered = .{ 0.24, 0.68, 0.52, 0.30 },
        .active = .{ 0.16, 0.52, 0.38, 0.42 },
    };
}

fn drawOverlayMenuButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    label: []const u8,
    active: bool,
) !bool {
    const palette = if (active)
        hudActivePalette()
    else
        hudIdlePalette();
    const text_width = gui.calcTextSize(label, false, 0.0)[0];
    const button_width = @max(50.0, text_width + 18.0);
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarVec2(.frame_padding, .{ 7.0, 3.0 });
    gui.pushStyleVarFloat(.frame_rounding, 3.0);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    gui.pushIdU64(std.hash.Wyhash.hash(0, id));
    defer gui.popId();
    const clicked = gui.buttonEx(label, button_width, 0.0);
    if (gui.isItemHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }
    return clicked;
}

fn drawOverlayStatusChip(label: []const u8) void {
    gui.pushStyleColor(.text, .{ 0.74, 0.77, 0.82, 1.0 });
    defer gui.popStyleColor(1);
    gui.text(label);
}

fn drawOverlayTitleChip(label: []const u8) void {
    gui.pushStyleColor(.text, .{ 0.95, 0.97, 0.99, 1.0 });
    defer gui.popStyleColor(1);
    gui.text(label);
}

fn drawHudWindowChrome() void {
    const draw_list = gui.getWindowDrawList();
    const pos = gui.windowPos();
    const size = gui.windowSize();
    const top_color = gui.getColorU32(.{ 0.42, 0.45, 0.50, 0.26 });
    const bottom_color = gui.getColorU32(.{ 0.03, 0.04, 0.05, 0.55 });
    const side_color = gui.getColorU32(.{ 0.50, 0.53, 0.58, 0.12 });
    draw_list.addLine(pos, .{ pos[0] + size[0], pos[1] }, top_color, 1.0);
    draw_list.addLine(
        .{ pos[0], pos[1] + size[1] - 1.0 },
        .{ pos[0] + size[0], pos[1] + size[1] - 1.0 },
        bottom_color,
        1.0,
    );
    draw_list.addLine(pos, .{ pos[0], pos[1] + size[1] }, side_color, 1.0);
    draw_list.addLine(
        .{ pos[0] + size[0] - 1.0, pos[1] },
        .{ pos[0] + size[0] - 1.0, pos[1] + size[1] },
        side_color,
        1.0,
    );
}

fn drawToolbarDivider(height: f32) void {
    const draw_list = gui.getWindowDrawList();
    const pos = gui.cursorScreenPos();
    const x = pos[0] + 4.0;
    draw_list.addLine(
        .{ x, pos[1] + 3.0 },
        .{ x, pos[1] + height - 3.0 },
        gui.getColorU32(.{ 0.55, 0.59, 0.64, 0.22 }),
        1.0,
    );
    gui.dummy(8.0, height);
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

fn projectWorldPointToViewport(
    state: *const EditorState,
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
    const clip = transformPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
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

fn transformPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
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

fn resolveViewportViewedCamera(state: *EditorState, layer_context: *engine.core.LayerContext) ?engine.scene.EntityId {
    if (state.editor_camera_active) {
        return state.editor_camera;
    }
    return layer_context.world.primaryCameraEntity();
}

fn viewportSceneAspectRatio(state: *const EditorState, layer_context: *engine.core.LayerContext) f32 {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] > 0 and viewport_size[1] > 0) {
        return @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));
    }
    if (state.viewport_extent[0] > 1.0 and state.viewport_extent[1] > 1.0) {
        return state.viewport_extent[0] / state.viewport_extent[1];
    }
    return 16.0 / 9.0;
}

fn viewportCameraHelperScale(view_camera_position: [3]f32, helper_position: [3]f32) f32 {
    const distance = vec3.length(vec3.sub(view_camera_position, helper_position));
    return std.math.clamp(distance * 0.16, 0.55, 3.0);
}

fn drawProjectedWorldSegment(
    draw_list: gui.DrawList,
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    a: [3]f32,
    b: [3]f32,
    color: u32,
    thickness: f32,
) void {
    const a_screen = projectWorldPointToViewport(state, layer_context, a) orelse return;
    const b_screen = projectWorldPointToViewport(state, layer_context, b) orelse return;
    draw_list.addLine(a_screen, b_screen, color, thickness);
}

fn drawViewport3DCursor(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.viewport_has_image) return;

    const draw_list = gui.getWindowDrawList();
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const origin = state.transform_cursor_world_position;
    const scale = viewportCameraHelperScale(camera_transform.translation, origin) * 0.28;
    const x_color = gui.getColorU32(.{ 0.96, 0.42, 0.42, 0.95 });
    const y_color = gui.getColorU32(.{ 0.48, 0.92, 0.54, 0.95 });
    const z_color = gui.getColorU32(.{ 0.44, 0.68, 0.98, 0.95 });
    const center_color = gui.getColorU32(.{ 0.98, 0.92, 0.42, 0.98 });
    const halo_color = gui.getColorU32(.{ 0.96, 0.86, 0.34, 0.24 });
    const label_bg = gui.getColorU32(.{ 0.07, 0.08, 0.10, 0.88 });
    const label_border = gui.getColorU32(.{ 0.93, 0.84, 0.34, 0.30 });
    const label_text = gui.getColorU32(.{ 0.96, 0.95, 0.88, 0.98 });

    drawProjectedWorldSegment(draw_list, state, layer_context, vec3.add(origin, .{ -scale, 0.0, 0.0 }), vec3.add(origin, .{ scale, 0.0, 0.0 }), x_color, 2.0);
    drawProjectedWorldSegment(draw_list, state, layer_context, vec3.add(origin, .{ 0.0, -scale, 0.0 }), vec3.add(origin, .{ 0.0, scale, 0.0 }), y_color, 2.0);
    drawProjectedWorldSegment(draw_list, state, layer_context, vec3.add(origin, .{ 0.0, 0.0, -scale }), vec3.add(origin, .{ 0.0, 0.0, scale }), z_color, 2.0);

    if (projectWorldPointToViewport(state, layer_context, origin)) |screen_pos| {
        const pulse = if (state.transform_cursor_place_mode)
            0.75 + 0.55 * @abs(std.math.sin(gui.time() * 4.6))
        else
            0.0;
        const ring_radius = 7.5 + pulse * 2.5;
        draw_list.addCircleFilled(screen_pos, ring_radius + 4.5, halo_color, 28);
        draw_list.addCircleFilled(screen_pos, ring_radius, gui.getColorU32(.{ 0.12, 0.12, 0.12, 0.92 }), 28);
        draw_list.addCircleFilled(screen_pos, 4.5, center_color, 20);
        draw_list.addLine(.{ screen_pos[0] - 12.0, screen_pos[1] }, .{ screen_pos[0] - 6.0, screen_pos[1] }, center_color, 1.8);
        draw_list.addLine(.{ screen_pos[0] + 6.0, screen_pos[1] }, .{ screen_pos[0] + 12.0, screen_pos[1] }, center_color, 1.8);
        draw_list.addLine(.{ screen_pos[0], screen_pos[1] - 12.0 }, .{ screen_pos[0], screen_pos[1] - 6.0 }, center_color, 1.8);
        draw_list.addLine(.{ screen_pos[0], screen_pos[1] + 6.0 }, .{ screen_pos[0], screen_pos[1] + 12.0 }, center_color, 1.8);

        if (state.transform_pivot_mode == .cursor or state.transform_cursor_place_mode) {
            const label = if (state.transform_cursor_place_mode)
                state.text(.place_cursor)
            else
                state.text(.pivot_cursor);
            const label_size = gui.calcTextSize(label, false, 0.0);
            const label_min = [2]f32{ screen_pos[0] + 13.0, screen_pos[1] - label_size[1] - 8.0 };
            const label_max = [2]f32{ label_min[0] + label_size[0] + 14.0, label_min[1] + label_size[1] + 8.0 };
            draw_list.addRectFilled(label_min, label_max, label_bg, 7.0, 0);
            draw_list.addRectFilled(
                .{ label_min[0] + 1.0, label_min[1] + 1.0 },
                .{ label_max[0] - 1.0, label_min[1] + 2.0 },
                label_border,
                6.0,
                0,
            );
            draw_list.addText(.{ label_min[0] + 7.0, label_min[1] + 4.0 }, label_text, label);
        }
    }
}

fn drawMeshEditOverlay(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const context = mesh_edit.activeContext(state, layer_context) orelse return;
    if (!state.viewport_has_image) {
        return;
    }

    const draw_list = gui.getWindowDrawList();
    const allocator = state.allocator orelse layer_context.world.allocator;
    const selected_color = gui.getColorU32(.{ 0.98, 0.84, 0.32, 0.96 });
    const accent_color = gui.getColorU32(.{ 0.42, 0.86, 0.78, 0.92 });
    const muted_color = gui.getColorU32(.{ 0.54, 0.62, 0.72, 0.34 });

    switch (state.mesh_edit_selection_mode) {
        .vertex => {
            const edges = try mesh_edit.buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (edges) |edge| {
                const a = meshEditTransformPoint(context.world_transform, context.mesh.vertices[edge.a].position);
                const b = meshEditTransformPoint(context.world_transform, context.mesh.vertices[edge.b].position);
                drawProjectedWorldSegment(draw_list, state, layer_context, a, b, muted_color, 1.0);
            }

            for (context.mesh.vertices, 0..) |vertex, index| {
                const world_position = meshEditTransformPoint(context.world_transform, vertex.position);
                const screen = projectWorldPointToViewport(state, layer_context, world_position) orelse continue;
                const is_selected = meshEditSelectionContains(state, @intCast(index));
                draw_list.addCircleFilled(screen, if (is_selected) 5.2 else 3.4, if (is_selected) selected_color else accent_color, 18);
            }
        },
        .edge => {
            const edges = try mesh_edit.buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (edges, 0..) |edge, index| {
                const a = meshEditTransformPoint(context.world_transform, context.mesh.vertices[edge.a].position);
                const b = meshEditTransformPoint(context.world_transform, context.mesh.vertices[edge.b].position);
                drawProjectedWorldSegment(
                    draw_list,
                    state,
                    layer_context,
                    a,
                    b,
                    if (meshEditSelectionContains(state, @intCast(index))) selected_color else accent_color,
                    if (meshEditSelectionContains(state, @intCast(index))) 3.0 else 1.2,
                );
            }
        },
        .face => {
            var face_index: usize = 0;
            while (face_index * 3 + 2 < context.mesh.indices.len) : (face_index += 1) {
                const triangle_offset = face_index * 3;
                const a = meshEditTransformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset]].position);
                const b = meshEditTransformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 1]].position);
                const c = meshEditTransformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 2]].position);
                const is_selected = meshEditSelectionContains(state, @intCast(face_index));
                drawProjectedWorldSegment(draw_list, state, layer_context, a, b, if (is_selected) selected_color else accent_color, if (is_selected) 2.6 else 1.0);
                drawProjectedWorldSegment(draw_list, state, layer_context, b, c, if (is_selected) selected_color else accent_color, if (is_selected) 2.6 else 1.0);
                drawProjectedWorldSegment(draw_list, state, layer_context, c, a, if (is_selected) selected_color else accent_color, if (is_selected) 2.6 else 1.0);

                if (is_selected) {
                    const centroid = .{
                        (a[0] + b[0] + c[0]) / 3.0,
                        (a[1] + b[1] + c[1]) / 3.0,
                        (a[2] + b[2] + c[2]) / 3.0,
                    };
                    if (projectWorldPointToViewport(state, layer_context, centroid)) |screen| {
                        draw_list.addCircleFilled(screen, 4.0, selected_color, 14);
                    }
                }
            }
        },
    }
}

fn meshEditSelectionContains(state: *const EditorState, element_index: u32) bool {
    for (mesh_edit.selectedElements(state)) |selected| {
        if (selected == element_index) {
            return true;
        }
    }
    return false;
}

fn meshEditTransformPoint(transform: engine.scene.Transform, point: [3]f32) [3]f32 {
    return vec3.add(
        transform.translation,
        quat.rotateVec3(transform.rotation, .{
            transform.scale[0] * point[0],
            transform.scale[1] * point[1],
            transform.scale[2] * point[2],
        }),
    );
}

fn rayPlaneIntersection(ray: engine.scene.Ray, plane_origin: [3]f32, plane_normal: [3]f32) ?[3]f32 {
    const normalized_normal = vec3.normalize(plane_normal);
    const denominator = vec3.dot(normalized_normal, ray.direction);
    if (@abs(denominator) <= 0.00001) return null;
    const distance = vec3.dot(vec3.sub(plane_origin, ray.origin), normalized_normal) / denominator;
    if (distance < 0.0) return null;
    return vec3.add(ray.origin, vec3.scale(ray.direction, distance));
}

fn tryPlace3DCursorFromViewportClick(state: *EditorState, layer_context: *engine.core.LayerContext) bool {
    if (!state.transform_cursor_place_mode or
        !state.viewport_has_image or
        !state.viewport_hovered or
        state.viewport_overlay_hovered or
        layer_context.input.modifiers.alt)
    {
        return false;
    }

    const pixel = viewportPixelUnderMouse(state, layer_context) orelse return false;
    const viewport_size = layer_context.renderer.sceneViewportSize();
    const ray = camera.activeCameraRayFromViewportPixel(state, layer_context, pixel, viewport_size) orelse return false;

    if (layer_context.world.raycastSurface(ray)) |hit| {
        state.transform_cursor_world_position = hit.position;
    } else if (rayPlaneIntersection(ray, .{ 0.0, state.transform_cursor_world_position[1], 0.0 }, .{ 0.0, 1.0, 0.0 })) |plane_hit| {
        state.transform_cursor_world_position = plane_hit;
    } else {
        return false;
    }

    state.transform_cursor_place_mode = false;
    manipulation.refreshGizmoState(state, layer_context);
    return true;
}

fn drawViewportPerspectiveCameraFrustum(
    draw_list: gui.DrawList,
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world_transform: engine.scene.Transform,
    projection: anytype,
    aspect: f32,
    color: u32,
    thickness: f32,
    helper_scale: f32,
) void {
    const origin = world_transform.translation;
    const forward = quat.rotateVec3(world_transform.rotation, .{ 0.0, 0.0, -1.0 });
    const right = quat.rotateVec3(world_transform.rotation, .{ 1.0, 0.0, 0.0 });
    const up = quat.rotateVec3(world_transform.rotation, .{ 0.0, 1.0, 0.0 });

    const plane_depth = std.math.clamp(helper_scale * 1.25, projection.near_clip + 0.05, projection.far_clip);
    const half_height = @tan(projection.fov_y_radians * 0.5) * plane_depth;
    const half_width = half_height * aspect;
    const plane_center = vec3.add(origin, vec3.scale(forward, plane_depth));
    const top_left = vec3.add(vec3.add(plane_center, vec3.scale(up, half_height)), vec3.scale(right, -half_width));
    const top_right = vec3.add(vec3.add(plane_center, vec3.scale(up, half_height)), vec3.scale(right, half_width));
    const bottom_right = vec3.add(vec3.add(plane_center, vec3.scale(up, -half_height)), vec3.scale(right, half_width));
    const bottom_left = vec3.add(vec3.add(plane_center, vec3.scale(up, -half_height)), vec3.scale(right, -half_width));

    drawProjectedWorldSegment(draw_list, state, layer_context, origin, top_left, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, origin, top_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, origin, bottom_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, origin, bottom_left, color, thickness);

    drawProjectedWorldSegment(draw_list, state, layer_context, top_left, top_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, top_right, bottom_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, bottom_right, bottom_left, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, bottom_left, top_left, color, thickness);

    const plane_mid_top = vec3.add(plane_center, vec3.scale(up, half_height * 1.16));
    drawProjectedWorldSegment(draw_list, state, layer_context, top_left, plane_mid_top, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, plane_mid_top, top_right, color, thickness);
}

fn drawViewportOrthographicCameraFrustum(
    draw_list: gui.DrawList,
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world_transform: engine.scene.Transform,
    projection: anytype,
    aspect: f32,
    color: u32,
    thickness: f32,
    helper_scale: f32,
) void {
    const origin = world_transform.translation;
    const forward = quat.rotateVec3(world_transform.rotation, .{ 0.0, 0.0, -1.0 });
    const right = quat.rotateVec3(world_transform.rotation, .{ 1.0, 0.0, 0.0 });
    const up = quat.rotateVec3(world_transform.rotation, .{ 0.0, 1.0, 0.0 });

    const half_height = std.math.clamp(projection.size * 0.12, helper_scale * 0.34, helper_scale * 0.82);
    const half_width = half_height * aspect;
    const back_depth = helper_scale * 0.22;
    const front_depth = helper_scale * 1.08;
    const back_center = vec3.add(origin, vec3.scale(forward, back_depth));
    const front_center = vec3.add(origin, vec3.scale(forward, front_depth));

    const back_top_left = vec3.add(vec3.add(back_center, vec3.scale(up, half_height)), vec3.scale(right, -half_width));
    const back_top_right = vec3.add(vec3.add(back_center, vec3.scale(up, half_height)), vec3.scale(right, half_width));
    const back_bottom_right = vec3.add(vec3.add(back_center, vec3.scale(up, -half_height)), vec3.scale(right, half_width));
    const back_bottom_left = vec3.add(vec3.add(back_center, vec3.scale(up, -half_height)), vec3.scale(right, -half_width));

    const front_top_left = vec3.add(vec3.add(front_center, vec3.scale(up, half_height)), vec3.scale(right, -half_width));
    const front_top_right = vec3.add(vec3.add(front_center, vec3.scale(up, half_height)), vec3.scale(right, half_width));
    const front_bottom_right = vec3.add(vec3.add(front_center, vec3.scale(up, -half_height)), vec3.scale(right, half_width));
    const front_bottom_left = vec3.add(vec3.add(front_center, vec3.scale(up, -half_height)), vec3.scale(right, -half_width));

    drawProjectedWorldSegment(draw_list, state, layer_context, back_top_left, back_top_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_top_right, back_bottom_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_bottom_right, back_bottom_left, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_bottom_left, back_top_left, color, thickness);

    drawProjectedWorldSegment(draw_list, state, layer_context, front_top_left, front_top_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, front_top_right, front_bottom_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, front_bottom_right, front_bottom_left, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, front_bottom_left, front_top_left, color, thickness);

    drawProjectedWorldSegment(draw_list, state, layer_context, back_top_left, front_top_left, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_top_right, front_top_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_bottom_right, front_bottom_right, color, thickness);
    drawProjectedWorldSegment(draw_list, state, layer_context, back_bottom_left, front_bottom_left, color, thickness);
}

fn drawViewportCameraFrustums(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.viewport_has_image) return;

    const draw_list = gui.getWindowDrawList();
    const selected_entities = layer_context.renderer.selectedEntities();
    const primary_scene_camera = resolveViewportPrimarySceneCamera(state, layer_context);
    const viewed_camera = resolveViewportViewedCamera(state, layer_context);
    const aspect = viewportSceneAspectRatio(state, layer_context);
    const view_camera_transform = camera.activeCameraTransform(state, layer_context);

    for (layer_context.scene.entities.items) |entity| {
        const camera_component = entity.camera orelse continue;
        if (!entity.visible or entity.editor_only) continue;
        if (state.editor_camera != null and entity.id == state.editor_camera.?) continue;
        if (viewed_camera != null and entity.id == viewed_camera.?) continue;

        const world_transform = layer_context.scene.worldTransformConst(entity.id) orelse entity.local_transform;

        var is_selected = false;
        for (selected_entities) |selected_id| {
            if (selected_id == entity.id) {
                is_selected = true;
                break;
            }
        }

        const is_primary_scene_camera = primary_scene_camera != null and primary_scene_camera.? == entity.id;
        const color_rgba: [4]f32 = if (is_selected)
            .{ 0.62, 0.88, 1.0, 0.96 }
        else if (is_primary_scene_camera)
            .{ 0.28, 0.92, 0.60, 0.92 }
        else
            .{ 0.47, 0.78, 1.0, 0.66 };
        const thickness: f32 = if (is_selected) 2.0 else if (is_primary_scene_camera) 1.8 else 1.35;
        const helper_scale = viewportCameraHelperScale(view_camera_transform.translation, world_transform.translation);
        const color = gui.getColorU32(color_rgba);

        switch (camera_component.projection) {
            .perspective => |projection| drawViewportPerspectiveCameraFrustum(
                draw_list,
                state,
                layer_context,
                world_transform,
                projection,
                aspect,
                color,
                thickness,
                helper_scale,
            ),
            .orthographic => |projection| drawViewportOrthographicCameraFrustum(
                draw_list,
                state,
                layer_context,
                world_transform,
                projection,
                aspect,
                color,
                thickness,
                helper_scale,
            ),
        }
    }
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
        const screen_pos = projectWorldPointToViewport(state, layer_context, world_transform.translation) orelse continue;

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
    const content_width = gui.contentRegionAvail()[0];
    gui.pushStyleVarVec2(.item_spacing, .{ 6.0, 6.0 });
    defer gui.popStyleVar(1);
    const strip_height = gui.frameHeight();

    if (try drawToolbarIconButton(state, layer_context, "toolbar_select", ui_icons.paths.toolbar.select, state.manipulation_mode == .none)) {
        try manipulation.activateSelectTool(state, layer_context);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.select_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_move", ui_icons.paths.toolbar.move, state.manipulation_mode == .translate)) {
        try manipulation.activateTransformTool(state, layer_context, .translate);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.move_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_rotate", ui_icons.paths.toolbar.rotate, state.manipulation_mode == .rotate)) {
        try manipulation.activateTransformTool(state, layer_context, .rotate);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.rotate_tool));
    }
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_scale", ui_icons.paths.toolbar.scale, state.manipulation_mode == .scale)) {
        try manipulation.activateTransformTool(state, layer_context, .scale);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.scale_tool));
    }

    gui.sameLine();
    drawToolbarDivider(strip_height);
    gui.sameLine();

    const edit_mode_active = mesh_edit.isEditModeActive(state);
    const can_enter_edit_mode = mesh_edit.canEnterEditMode(state, layer_context);
    {
        gui.pushStyleVarVec2(.item_spacing, .{ 0.0, 6.0 });
        defer gui.popStyleVar(1);
        if (drawSegmentedModeButton(state.text(.object_mode), !edit_mode_active, 66.0, .first)) {
            mesh_edit.exitEditMode(state, layer_context);
        }
        if (gui.isItemHovered()) gui.setTooltip(state.text(.object_mode));
        gui.sameLine();
        if (drawSegmentedModeButton(
            state.text(.edit_mode),
            edit_mode_active,
            58.0,
            if (edit_mode_active) .middle else .last,
        )) {
            if (edit_mode_active or can_enter_edit_mode) {
                _ = try mesh_edit.enterEditMode(state, layer_context);
            }
        }
        if (gui.isItemHovered()) {
            gui.setTooltip(if (!edit_mode_active and !can_enter_edit_mode)
                state.text(.select_mesh_to_edit)
            else
                state.text(.edit_mode));
        }

        if (edit_mode_active) {
            gui.sameLine();
            if (drawSegmentedModeButton(state.text(.vertex_mode), state.mesh_edit_selection_mode == .vertex, 54.0, .middle)) {
                mesh_edit.setSelectionMode(state, .vertex);
            }
            if (gui.isItemHovered()) gui.setTooltip("1");
            gui.sameLine();
            if (drawSegmentedModeButton(state.text(.edge_mode), state.mesh_edit_selection_mode == .edge, 46.0, .middle)) {
                mesh_edit.setSelectionMode(state, .edge);
            }
            if (gui.isItemHovered()) gui.setTooltip("2");
            gui.sameLine();
            if (drawSegmentedModeButton(state.text(.face_mode), state.mesh_edit_selection_mode == .face, 46.0, .last)) {
                mesh_edit.setSelectionMode(state, .face);
            }
            if (gui.isItemHovered()) gui.setTooltip("3");
        }
    }

    gui.sameLine();
    drawToolbarDivider(strip_height);
    gui.sameLine();

    const utility_width: f32 = 90.0;
    gui.sameLineEx(@max(0.0, content_width - utility_width), 0.0);
    if (try drawToolbarIconButton(state, layer_context, "toolbar_ai_chat", ui_icons.paths.toolbar.ai_chat, state.ai_chat_open)) {
        state.ai_chat_open = !state.ai_chat_open;
    }
    if (gui.isItemHovered()) gui.setTooltip(state.text(.ai_chat));
    gui.sameLine();
    if (try drawToolbarIconButton(state, layer_context, "toolbar_settings", ui_icons.paths.toolbar.settings, state.render_settings_open)) {
        state.render_settings_open = !state.render_settings_open;
    }
    if (gui.isItemHovered()) gui.setTooltip(state.text(.render_settings));
}

fn applyViewportShadingMode(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    shading_mode: ViewportShadingMode,
) void {
    if (state_mod.setViewportShadingMode(state, shading_mode)) {
        // 切换到 Rendered 时强制同步当前场景状态并重新渲染，
        // 而 Material / Solid / Wireframe 不影响 PathTrace 渐进状态。
        layer_context.renderer.resetPathTraceState();
    }
}

const SegmentedButtonPosition = enum {
    single,
    first,
    middle,
    last,
};

fn drawSegmentedModeButton(label: []const u8, active: bool, width: f32, position: SegmentedButtonPosition) bool {
    const palette = if (active)
        hudActivePalette()
    else
        hudIdlePalette();
    const rounding: f32 = switch (position) {
        .single, .first, .last => 4.0,
        .middle => 0.0,
    };
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarFloat(.frame_rounding, rounding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(3);
    }
    return gui.buttonEx(label, width, 0.0);
}

fn drawConstraintChipButton(id: []const u8, label: []const u8, active: bool) bool {
    const palette = if (active)
        ui_icons.palettes.toolbar_active
    else
        ui_icons.palettes.toolbar_idle;
    const text_width = gui.calcTextSize(label, false, 0.0)[0];
    const button_width = @max(44.0, text_width + 18.0);
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    defer gui.popStyleColor(3);
    gui.pushIdU64(std.hash.Wyhash.hash(0, id));
    defer gui.popId();
    return gui.buttonEx(label, button_width, 0.0);
}

fn transformConstraintsActive(state: *const EditorState) bool {
    return state.transform_pivot_mode != .origin or
        state.translation_snap_target != .grid or
        state.transform_cursor_place_mode or
        state.surface_snap_align_rotation_to_normal or
        state.manipulation_axis != .free or
        state.translation_snap_enabled or
        state.rotation_snap_enabled or
        state.scale_snap_enabled;
}

fn drawTransformConstraintsPopup(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var changed = false;

    gui.text(state.text(.coordinate_space));
    if (drawConstraintPopupButton(state.text(.local_space), 96.0, state.transform_space == .local)) {
        state.transform_space = .local;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.world_space), 96.0, state.transform_space == .world)) {
        state.transform_space = .world;
        changed = true;
    }

    gui.separator();
    gui.text(state.text(.pivot_point));
    if (drawConstraintPopupButton(state.text(.pivot_origin), 96.0, state.transform_pivot_mode == .origin)) {
        state.transform_pivot_mode = .origin;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.pivot_bounds_center), 120.0, state.transform_pivot_mode == .bounds_center)) {
        state.transform_pivot_mode = .bounds_center;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.pivot_median_point), 108.0, state.transform_pivot_mode == .median_point)) {
        state.transform_pivot_mode = .median_point;
        changed = true;
    }
    if (drawConstraintPopupButton(state.text(.pivot_active_element), 120.0, state.transform_pivot_mode == .active_element)) {
        state.transform_pivot_mode = .active_element;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.pivot_cursor), 96.0, state.transform_pivot_mode == .cursor)) {
        state.transform_pivot_mode = .cursor;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.pivot_individual_origins), 126.0, state.transform_pivot_mode == .individual_origins)) {
        state.transform_pivot_mode = .individual_origins;
        changed = true;
    }
    if (state.transform_pivot_mode == .cursor) {
        gui.text(state.text(.cursor_position));
        var cursor_position = state.transform_cursor_world_position;
        if (gui.dragFloat3("##transform_cursor_world_position", &cursor_position, 0.1, -100000.0, 100000.0)) {
            state.transform_cursor_world_position = cursor_position;
            changed = true;
        }
        if (drawConstraintPopupButton(state.text(.place_cursor), 164.0, state.transform_cursor_place_mode)) {
            state.transform_cursor_place_mode = !state.transform_cursor_place_mode;
        }
    }

    gui.separator();
    gui.text(state.text(.axis_constraint));
    if (drawConstraintPopupButton(state.text(.free_axis), 56.0, state.manipulation_axis == .free)) {
        state.manipulation_axis = .free;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton("X", 40.0, state.manipulation_axis == .x)) {
        toggleAxisConstraint(state, .x);
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton("Y", 40.0, state.manipulation_axis == .y)) {
        toggleAxisConstraint(state, .y);
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton("Z", 40.0, state.manipulation_axis == .z)) {
        toggleAxisConstraint(state, .z);
        changed = true;
    }

    gui.separator();
    gui.text(state.text(.snap_target));
    if (drawConstraintPopupButton(state.text(.grid_view), 72.0, state.translation_snap_target == .grid)) {
        state.translation_snap_target = .grid;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.surface_snap), 84.0, state.translation_snap_target == .surface)) {
        state.translation_snap_target = .surface;
        changed = true;
    }
    gui.sameLine();
    if (drawConstraintPopupButton(state.text(.vertex_snap), 76.0, state.translation_snap_target == .vertex)) {
        state.translation_snap_target = .vertex;
        changed = true;
    }
    if (state.translation_snap_target != .grid) {
        if (drawConstraintPopupButton(
            state.text(.align_rotation_to_surface_normal),
            220.0,
            state.surface_snap_align_rotation_to_normal,
        )) {
            state.surface_snap_align_rotation_to_normal = !state.surface_snap_align_rotation_to_normal;
            changed = true;
        }
    }

    gui.separator();
    gui.text(state.text(.transform_constraints));
    drawSnapControlRow(state.text(.translation_snap), "translation", &state.translation_snap_enabled, &state.translation_snap_step, 0.01, 0.01, 1024.0);
    drawSnapControlRow(state.text(.rotation_snap), "rotation", &state.rotation_snap_enabled, &state.rotation_snap_step_degrees, 1.0, 1.0, 180.0);
    drawSnapControlRow(state.text(.scale_snap), "scale", &state.scale_snap_enabled, &state.scale_snap_step, 0.01, 0.01, 10.0);
    if (changed) {
        manipulation.refreshGizmoState(state, layer_context);
    }
}

fn drawSnapControlRow(
    label: []const u8,
    id_suffix: []const u8,
    enabled: *bool,
    step_value: *f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) void {
    _ = gui.checkbox(label, enabled);
    gui.sameLine();
    gui.setNextItemWidth(88.0);
    var drag_id_buf: [64]u8 = undefined;
    const drag_id = std.fmt.bufPrint(&drag_id_buf, "##{s}_snap_step", .{id_suffix}) catch "##snap_step";
    if (gui.dragFloat(drag_id, step_value, speed, min_value, max_value)) {
        step_value.* = std.math.clamp(step_value.*, min_value, max_value);
    }
}

fn drawConstraintPopupButton(label: []const u8, width: f32, active: bool) bool {
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

fn toggleAxisConstraint(state: *EditorState, axis: state_mod.AxisConstraint) void {
    state.manipulation_axis = if (state.manipulation_axis == axis) .free else axis;
}

pub fn drawViewportWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .viewport, "viewport_panel");

    gui.pushStyleVarVec2(.window_padding, .{ 0.0, 4.0 });
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
    var mouse_pos = effectiveCursorPos(layer_context);
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
        mouse_pos = effectiveCursorPos(layer_context);
        state.viewport_hovered = gui.isItemHovered() and isPointInViewportRect(mouse_pos, state.viewport_origin, state.viewport_extent);
        state.viewport_has_image = true;

        // Draw overlays (positioned absolutely, won't affect layout)
        try handleViewportAssetDropTargets(state, layer_context);
        try drawViewportOverlayControlsWindow(state, layer_context);
        drawViewportAiStateOverlayWindow(state);
        try drawViewportPlaybackOverlayWindow(state, layer_context);
        try drawViewportFpsOverlayWindow(state, layer_context);
        try ai_collaboration.drawViewportCollaborationOverlay(state, layer_context);
        drawViewport3DCursor(state, layer_context);
        try drawMeshEditOverlay(state, layer_context);
        drawViewportCameraFrustums(state, layer_context);
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
    const fps_metrics = viewportFpsMetrics(layer_context);

    var fps_buffer: [64]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps_metrics.fps});
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

pub fn handleViewportSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;
    if (input.wasMousePressed(.left)) {
        if (tryPlace3DCursorFromViewportClick(state, layer_context)) {
            state.viewport_selection_press_active = false;
            return;
        }

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
                        try manipulation.beginGizmoHandleDrag(state, layer_context, picked_handle, ray);
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
            if (try mesh_edit.handleViewportSelection(state, layer_context, ray, mode)) {
                return;
            }
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
            try manipulation.activateSelectTool(state, layer_context);
        }
        if (gui.menuItem(state.text(.move_tool), "W", state.manipulation_mode == .translate, true)) {
            try manipulation.activateTransformTool(state, layer_context, .translate);
        }
        if (gui.menuItem(state.text(.rotate_tool), "E", state.manipulation_mode == .rotate, true)) {
            try manipulation.activateTransformTool(state, layer_context, .rotate);
        }
        if (gui.menuItem(state.text(.scale_tool), "R", state.manipulation_mode == .scale, true)) {
            try manipulation.activateTransformTool(state, layer_context, .scale);
        }
        if (mesh_edit.isEditModeActive(state) or mesh_edit.canEnterEditMode(state, layer_context)) {
            gui.separator();
            if (gui.menuItem(state.text(.object_mode), "Tab", !mesh_edit.isEditModeActive(state), true)) {
                mesh_edit.exitEditMode(state, layer_context);
            }
            if (gui.menuItem(state.text(.edit_mode), "Tab", mesh_edit.isEditModeActive(state), true)) {
                _ = try mesh_edit.enterEditMode(state, layer_context);
            }
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

    // Shell Layer 3: Bottom drawer (positioned at viewport bottom)
    try content_browser.drawBottomDrawer(state, layer_context);

    // Shell Layer 4: Auxiliary / Floating Windows
    try drawAuxiliaryWindows(state, layer_context);
    try menu_bar.resolvePendingTopBarDrag(state, layer_context);
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

    const mouse_pos = effectiveCursorPos(layer_context);
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

const viewport_bottom_drawer_bar_height: f32 = 38.0;
const viewport_bottom_overlay_gap: f32 = 18.0;

const ViewportFpsMetrics = struct {
    fps: f32,
    frame_ms: f32,
    refresh_hz: ?f32,
};

fn viewportBottomOverlayInset(state: *const EditorState) f32 {
    const drawer_height = if (state.bottom_drawer_open)
        state.bottom_drawer_height + viewport_bottom_drawer_bar_height
    else
        viewport_bottom_drawer_bar_height;
    return drawer_height + viewport_bottom_overlay_gap;
}

fn viewportFpsMetrics(layer_context: *const engine.core.LayerContext) ViewportFpsMetrics {
    const perf = layer_context.renderer.device().performanceStats();
    const fps = if (perf.avg_frame_time_ns != 0)
        @as(f32, @floatCast(perf.fps()))
    else if (layer_context.delta_seconds > 0.0001)
        1.0 / layer_context.delta_seconds
    else
        0.0;
    const frame_ms = if (perf.avg_frame_time_ns != 0)
        @as(f32, @floatCast(perf.avgFrameTimeMs()))
    else
        layer_context.delta_seconds * 1000.0;

    return .{
        .fps = fps,
        .frame_ms = frame_ms,
        .refresh_hz = layer_context.window.displayRefreshRate(),
    };
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
    gui.pushStyleVarVec2(.frame_padding, .{ 5.0, 3.0 });
    gui.pushStyleVarFloat(.frame_rounding, 3.0);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    return gui.imageButton(id, texture, 12.0, 12.0, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}

fn idlePlaybackPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.20, 0.22, 0.25, 0.76 },
        .hovered = .{ 0.24, 0.27, 0.31, 0.82 },
        .active = .{ 0.18, 0.20, 0.24, 0.88 },
    };
}

fn activePlayPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.30, 0.35, 0.34, 0.80 },
        .hovered = .{ 0.34, 0.40, 0.38, 0.86 },
        .active = .{ 0.28, 0.32, 0.31, 0.92 },
    };
}

fn activePausePalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.32, 0.30, 0.25, 0.80 },
        .hovered = .{ 0.36, 0.34, 0.29, 0.86 },
        .active = .{ 0.29, 0.27, 0.23, 0.92 },
    };
}

fn stepPlaybackPalette() ui_icons.ButtonPalette {
    return .{
        .button = .{ 0.24, 0.26, 0.30, 0.78 },
        .hovered = .{ 0.28, 0.31, 0.36, 0.84 },
        .active = .{ 0.22, 0.24, 0.28, 0.90 },
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
    const display_popup_id = "viewport_display_popup";
    const snap_popup_id = "viewport_snap_popup";
    const view_popup_open = gui.isPopupOpen(view_popup_id);
    const display_popup_open = gui.isPopupOpen(display_popup_id);
    const snap_popup_open = gui.isPopupOpen(snap_popup_id);

    const overlay_pos = .{
        state.viewport_origin[0] + 14.0,
        state.viewport_origin[1] + viewportOverlayTopInset(),
    };
    gui.pushStyleVarVec2(.window_padding, .{ 4.0, 4.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(overlay_pos);
    gui.setNextWindowBgAlpha(0.38);
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
    drawHudWindowChrome();

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    gui.pushStyleVarVec2(.item_spacing, .{ 6.0, 4.0 });
    defer gui.popStyleVar(1);

    if (try drawOverlayMenuButton(
        state,
        layer_context,
        "viewport_overlay_view",
        state.text(.view_menu),
        view_popup_open or state.viewport_view_preset != .perspective or state_mod.viewportShadingMode(state) != .material,
    )) {
        gui.openPopup(view_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.view_presets));
    }
    if (gui.beginPopup(view_popup_id)) {
        defer gui.endPopup();
        gui.text(state.text(.view_presets));
        if (gui.menuItem(state.text(.perspective_view), null, state.viewport_view_preset == .perspective, true)) {
            camera.setViewPreset(state, layer_context, .perspective);
        }
        if (gui.menuItem(state.text(.top_view), null, state.viewport_view_preset == .top, true)) {
            camera.setViewPreset(state, layer_context, .top);
        }
        if (gui.menuItem(state.text(.side_view), null, state.viewport_view_preset == .side, true)) {
            camera.setViewPreset(state, layer_context, .side);
        }
        gui.separator();
        gui.text(state.text(.render_modes));
        const shading_mode = state_mod.viewportShadingMode(state);
        if (gui.menuItem(state.text(.solid_view), null, shading_mode == .solid, true)) {
            applyViewportShadingMode(state, layer_context, .solid);
        }
        if (gui.menuItem(state.text(.material_view), null, shading_mode == .material, true)) {
            applyViewportShadingMode(state, layer_context, .material);
        }
        if (gui.menuItem(state.text(.rendered_view), null, shading_mode == .rendered, true)) {
            applyViewportShadingMode(state, layer_context, .rendered);
        }
        if (gui.menuItem(state.text(.wireframe), null, shading_mode == .wireframe, true)) {
            applyViewportShadingMode(state, layer_context, .wireframe);
        }
        gui.separator();
        gui.text("Render Style");
        const style_reg = layer_context.renderer.styleRegistry();
        var style_it = style_reg.styleIterator();
        while (style_it.next()) |entry| {
            const active_style_name = layer_context.renderer.editor_viewport_state.activeRenderStyleName();
            const is_active = std.mem.eql(u8, entry.key_ptr.*, active_style_name);
            const display = if (entry.value_ptr.display_name.len > 0) entry.value_ptr.display_name else entry.key_ptr.*;
            if (gui.menuItem(display, null, is_active, true)) {
                layer_context.renderer.editor_viewport_state.setActiveRenderStyle(entry.key_ptr.*);
                _ = style_reg.setActiveStyle(entry.key_ptr.*);
            }
        }
    }
    gui.sameLine();
    drawToolbarDivider(gui.frameHeight());
    gui.sameLine();

    if (try drawOverlayMenuButton(
        state,
        layer_context,
        "viewport_overlay_display",
        state.text(.display_menu),
        display_popup_open or !state.viewport_show_grid or state.viewport_show_bones or state.viewport_show_collision,
    )) {
        gui.openPopup(display_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.overlay_options));
    }
    if (gui.beginPopup(display_popup_id)) {
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
    drawToolbarDivider(gui.frameHeight());
    gui.sameLine();

    if (try drawOverlayMenuButton(
        state,
        layer_context,
        "viewport_overlay_snap",
        state.text(.snap_menu),
        snap_popup_open or transformConstraintsActive(state),
    )) {
        gui.openPopup(snap_popup_id);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.transform_constraints));
    }
    if (gui.beginPopup(snap_popup_id)) {
        defer gui.endPopup();
        state.viewport_overlay_hovered = true;
        drawTransformConstraintsPopup(state, layer_context);
    }

    // Show camera speed indicator when shift is held
    if (layer_context.input.modifiers.shift) {
        gui.sameLine();
        drawOverlayStatusChip("3x");
        if (gui.isItemHovered()) {
            state.viewport_overlay_hovered = true;
        }
    }

    if (view_popup_open or display_popup_open or snap_popup_open) {
        state.viewport_overlay_hovered = true;
    }
}

fn drawViewportPlaybackOverlayWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const window_width = 108.0;
    gui.pushStyleVarVec2(.window_padding, .{ 4.0, 4.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + @max((state.viewport_extent[0] - window_width) * 0.5, 18.0),
        state.viewport_origin[1] + viewportOverlayTopInset(),
    });
    gui.setNextWindowBgAlpha(0.38);
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
    drawHudWindowChrome();

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
    drawToolbarDivider(gui.frameHeight());
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
    drawToolbarDivider(gui.frameHeight());
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
        .analyzing_screenshot => state.text(.ai_chat_stage_analyzing_screenshot),
        .compiling_shader => state.text(.ai_chat_stage_compiling_shader),
        .waiting_approval => state.text(.ai_chat_stage_waiting_approval),
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
    const bg_alpha = std.math.clamp(@max(0.54, base_color[3] + pulse) * 0.72, 0.0, 0.68);

    const overlay_width: f32 = if (ai_status.stage == .waiting_approval) 320.0 else 280.0;
    gui.pushStyleVarVec2(.window_padding, .{ 4.0, 3.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(.{
        state.viewport_origin[0] + @max((state.viewport_extent[0] - overlay_width) * 0.5, 12.0),
        state.viewport_origin[1] + viewportOverlayTopInset() + 48.0,
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
    drawHudWindowChrome();

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    drawOverlayTitleChip(state.text(.ai_chat));
    gui.sameLine();
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
        gui.text(state.text(.ghost_highlight_active));
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
        const mouse_pos = effectiveCursorPos(layer_context);
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

fn effectiveCursorPos(layer_context: *const engine.core.LayerContext) [2]f32 {
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

    const fps_metrics = viewportFpsMetrics(layer_context);
    const sample_interval: f64 = 0.20;
    const now = gui.time();
    if (state.fps_overlay_last_sample_time < 0.0 or now - state.fps_overlay_last_sample_time >= sample_interval) {
        state.fps_overlay_display_fps = fps_metrics.fps;
        state.fps_overlay_display_frame_ms = fps_metrics.frame_ms;
        state.fps_overlay_display_refresh_hz = fps_metrics.refresh_hz;
        state.fps_overlay_last_sample_time = now;
    }

    const overlay_width: f32 = 220.0;
    const overlay_height: f32 = 22.0;
    var fps_buffer: [32]u8 = undefined;
    const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.0}", .{state.fps_overlay_display_fps});
    var frame_time_buffer: [32]u8 = undefined;
    const frame_time_text = try std.fmt.bufPrint(&frame_time_buffer, "{d:.1} ms", .{state.fps_overlay_display_frame_ms});
    var refresh_buffer: [24]u8 = undefined;
    const refresh_text = if (state.fps_overlay_display_refresh_hz) |refresh_hz|
        try std.fmt.bufPrint(&refresh_buffer, "{d:.0} Hz", .{refresh_hz})
    else
        "-- Hz";
    const overlay_margin = 14.0;
    // Position at top-right, below the view cube
    const cube_clearance = std.math.clamp(@min(state.viewport_extent[0], state.viewport_extent[1]) * 0.13, 72.0, 92.0) + 12.0;
    const overlay_x = state.viewport_origin[0] + state.viewport_extent[0] - overlay_width - overlay_margin;
    const overlay_y = state.viewport_origin[1] + viewportOverlayTopInset() + cube_clearance;

    gui.pushStyleVarVec2(.window_padding, .{ 6.0, 3.0 });
    defer gui.popStyleVar(1);
    gui.setNextWindowPos(.{
        overlay_x,
        overlay_y,
    });
    gui.setNextWindowSize(.{ overlay_width, overlay_height });
    gui.setNextWindowBgAlpha(0.34);
    _ = gui.beginWindowFlags(
        "##viewport_fps_overlay",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking,
    );
    defer gui.endWindow();
    drawHudWindowChrome();

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    drawOverlayTitleChip(state.text(.fps));
    gui.sameLineEx(56.0, 0.0);
    gui.pushStyleColor(.text, .{ 0.96, 0.98, 1.0, 1.0 });
    gui.text(fps_text);
    gui.popStyleColor(1);
    gui.sameLineEx(116.0, 0.0);
    drawOverlayStatusChip(frame_time_text);
    gui.sameLineEx(174.0, 0.0);
    drawOverlayStatusChip(refresh_text);
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
