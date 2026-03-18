const std = @import("std");
const engine = @import("guava");
const mat4 = engine.math.mat4;
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const state_mod = @import("../core/state.zig");
const EditorState = state_mod.EditorState;
const utils = @import("../common/utils.zig");

pub const ViewPreset = state_mod.ViewportViewPreset;

pub fn handleCameraControls(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const input = layer_context.input;
    const tool_active = state.manipulation_mode != .none;

    const is_dragging_input = input.isMouseDown(.right) or input.isMouseDown(.middle) or (input.isMouseDown(.left) and input.modifiers.alt);

    if (state.view_cube_transition_active and is_dragging_input) {
        state.view_cube_transition_active = false;
    }
    updateViewCubeTransition(state, layer_context);

    if (!state.editor_camera_active) {
        return;
    }

    const is_hovering_viewport = state.viewport_hovered and !state.viewport_overlay_hovered;

    if (!is_dragging_input) {
        state.camera_drag_active = false;
    } else if (input.wasMousePressed(.right) or input.wasMousePressed(.middle) or (input.wasMousePressed(.left) and (!tool_active or input.modifiers.alt))) {
        if (is_hovering_viewport) {
            state.camera_drag_active = true;
        }
    }

    const camera_id = state.editor_camera orelse return;
    const camera = layer_context.world.getEntity(camera_id) orelse return;

    if (state.camera_drag_active) {
        if (input.isMouseDown(.left) and (!tool_active or input.modifiers.alt)) {
            state.yaw -= input.mouse_delta[0] * state.orbit_sensitivity;
            state.pitch = utils.clampPitch(state.pitch - input.mouse_delta[1] * state.orbit_sensitivity);
            if (@abs(input.mouse_delta[0]) > 0.0001 or @abs(input.mouse_delta[1]) > 0.0001) {
                state.viewport_view_preset = .custom;
                if (camera.camera) |camera_component| {
                    var next_camera = camera_component;
                    next_camera.projection = .{ .perspective = .{} };
                    camera.camera = next_camera;
                }
            }
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });
            camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, state.orbit_distance));
        }

        if (input.isMouseDown(.right)) {
            state.yaw -= input.mouse_delta[0] * state.look_sensitivity;
            state.pitch = utils.clampPitch(state.pitch - input.mouse_delta[1] * state.look_sensitivity);
            if (@abs(input.mouse_delta[0]) > 0.0001 or @abs(input.mouse_delta[1]) > 0.0001) {
                state.viewport_view_preset = .custom;
                if (camera.camera) |camera_component| {
                    var next_camera = camera_component;
                    next_camera.projection = .{ .perspective = .{} };
                    camera.camera = next_camera;
                }
            }
        }

        camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });

        if (input.isMouseDown(.right)) {
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const right = vec3.rightFromYaw(state.yaw);
            const move_up = [3]f32{ 0.0, 1.0, 0.0 };
            const boost: f32 = if (input.modifiers.shift) state.camera_boost_multiplier else 1.0;
            const step = moveSpeed(state, layer_context.delta_seconds) * boost;
            var movement = [3]f32{ 0.0, 0.0, 0.0 };

            if (input.isKeyDown(.w)) movement = vec3.add(movement, vec3.scale(forward, step));
            if (input.isKeyDown(.s)) movement = vec3.sub(movement, vec3.scale(forward, step));
            if (input.isKeyDown(.d)) movement = vec3.add(movement, vec3.scale(right, step));
            if (input.isKeyDown(.a)) movement = vec3.sub(movement, vec3.scale(right, step));
            if (input.isKeyDown(.e)) movement = vec3.add(movement, vec3.scale(move_up, step));
            if (input.isKeyDown(.q)) movement = vec3.sub(movement, vec3.scale(move_up, step));

            camera.local_transform.translation = vec3.add(camera.local_transform.translation, movement);
            state.focus_pivot = vec3.add(camera.local_transform.translation, vec3.scale(forward, state.orbit_distance));
        }

        if (input.isMouseDown(.middle)) {
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const right = vec3.rightFromYaw(state.yaw);
            const up = vec3.normalize(vec3.cross(right, forward));
            const pan_scale = @max(state.orbit_distance, 1.0) * state.pan_sensitivity * 0.05;
            const pan = vec3.add(
                vec3.scale(right, -input.mouse_delta[0] * pan_scale),
                vec3.scale(up, input.mouse_delta[1] * pan_scale),
            );
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, pan);
            state.focus_pivot = vec3.add(state.focus_pivot, pan);
        }
    }

    // Always process zoom if hovering viewport (no need to click)
    if (state.viewport_hovered and !state.viewport_overlay_hovered) {
        if (@abs(input.mouse_wheel[1]) > 0.001) {
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const zoom_step = input.mouse_wheel[1] * state.wheel_speed * @max(state.orbit_distance * 0.2, 0.8);
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, vec3.scale(forward, zoom_step));
            state.orbit_distance = utils.clampDistance(vec3.length(vec3.sub(state.focus_pivot, camera.local_transform.translation)));

            if (camera.camera) |camera_component| {
                if (camera_component.projection == .orthographic) {
                    var next_camera = camera_component;
                    next_camera.projection.orthographic.size = @max(state.orbit_distance * 1.1, 2.0);
                    camera.camera = next_camera;
                }
            }
        }

        if (@abs(input.mouse_wheel[0]) > 0.001) {
            const right = vec3.rightFromYaw(state.yaw);
            const pan_step = input.mouse_wheel[0] * state.wheel_speed * @max(state.orbit_distance * 0.3, 1.0);
            const pan = vec3.scale(right, pan_step);
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, pan);
            state.focus_pivot = vec3.add(state.focus_pivot, pan);
        }
    }

    camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });
}

pub fn toggleCameraMode(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (state.manipulation_mode != .none) {
        return;
    }
    if (state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            if (layer_context.world.hasEntity(scene_camera_id)) {
                _ = layer_context.world.setPrimaryCamera(scene_camera_id);
                state.editor_camera_active = false;
            }
        }
        return;
    }

    if (state.editor_camera) |editor_camera_id| {
        if (layer_context.world.hasEntity(editor_camera_id)) {
            _ = layer_context.world.setPrimaryCamera(editor_camera_id);
            state.editor_camera_active = true;
        }
    }
}

pub fn focusSelection(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const selected = layer_context.renderer.selectedEntity() orelse return;
    const camera_id = state.editor_camera orelse return;
    const camera = layer_context.world.getEntity(camera_id) orelse return;
    const entity_transform = layer_context.world.worldTransform(selected) orelse return;

    state.focus_pivot = entity_transform.translation;
    if (!state.editor_camera_active) {
        return;
    }

    const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
    state.orbit_distance = utils.clampDistance(state.orbit_distance);
    camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, state.orbit_distance));
}

pub fn createEditorCamera(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const transform = editorCameraTransform(state);
    state.editor_camera = try layer_context.world.createEntity(.{
        .name = "EditorCamera",
        .camera = .{
            .is_primary = true,
        },
        .local_transform = transform,
        .editor_only = true,
    });
    if (state.editor_camera_active) {
        _ = layer_context.world.setPrimaryCamera(state.editor_camera.?);
    }
}

pub fn setViewPreset(state: *EditorState, layer_context: *engine.core.LayerContext, preset: ViewPreset) void {
    switch (preset) {
        .perspective => requestViewOrientation(state, layer_context, vec3.normalize(.{ -0.45, -0.32, -0.84 }), false, .perspective),
        .top => requestViewOrientation(state, layer_context, .{ 0.0, -1.0, 0.0 }, true, .top),
        .side => requestViewOrientation(state, layer_context, .{ -1.0, 0.0, 0.0 }, true, .side),
        .custom => {},
    }
}

pub fn lookAlongWorldAxis(state: *EditorState, layer_context: *engine.core.LayerContext, axis: [3]f32) void {
    requestViewOrientation(state, layer_context, vec3.normalize(axis), true, viewPresetForAxis(axis));
}

pub fn orbitFromViewCubeDrag(state: *EditorState, layer_context: *engine.core.LayerContext, drag_delta: [2]f32) void {
    const camera_id = state.editor_camera orelse return;
    const camera_entity = layer_context.world.getEntity(camera_id) orelse return;

    state.view_cube_transition_active = false;
    state.yaw -= drag_delta[0] * state.orbit_sensitivity;
    state.pitch = utils.clampPitch(state.pitch - drag_delta[1] * state.orbit_sensitivity);
    state.viewport_view_preset = .custom;

    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }

    camera_entity.local_transform = editorCameraTransform(state);
    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

pub fn editorCameraTransform(state: *const EditorState) engine.scene.Transform {
    return .{
        .translation = vec3.sub(state.focus_pivot, vec3.scale(vec3.forwardFromAngles(state.yaw, state.pitch), state.orbit_distance)),
        .rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }),
    };
}

pub fn activeCameraTransform(state: *const EditorState, layer_context: *engine.core.LayerContext) engine.scene.Transform {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.worldTransform(camera_id)) |camera_transform| {
            return camera_transform;
        }
    }
    return .{
        .translation = .{ 0.0, 2.0, 6.0 },
    };
}

pub fn activeCameraComponent(state: *const EditorState, layer_context: *engine.core.LayerContext) engine.scene.Camera {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.getEntityConst(camera_id)) |entity| {
            if (entity.camera) |camera_component| {
                return camera_component;
            }
        }
    }
    return .{};
}

pub fn activeCameraRayFromViewportPixel(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    pixel: [2]u32,
    viewport_size: [2]u32,
) ?engine.scene.Ray {
    if (viewport_size[0] == 0 or viewport_size[1] == 0) {
        return null;
    }

    const camera_transform = activeCameraTransform(state, layer_context);
    const camera_component = activeCameraComponent(state, layer_context);
    const ndc_x = ((@as(f32, @floatFromInt(pixel[0])) + 0.5) / @as(f32, @floatFromInt(viewport_size[0]))) * 2.0 - 1.0;
    const ndc_y = 1.0 - ((@as(f32, @floatFromInt(pixel[1])) + 0.5) / @as(f32, @floatFromInt(viewport_size[1]))) * 2.0;
    const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));

    return switch (camera_component.projection) {
        .perspective => |projection| blk: {
            const tan_half_fov = @tan(projection.fov_y_radians * 0.5);
            const local_direction = normalize(.{
                ndc_x * tan_half_fov * aspect,
                ndc_y * tan_half_fov,
                -1.0,
            });
            break :blk .{
                .origin = camera_transform.translation,
                .direction = normalize(quat.rotateVec3(camera_transform.rotation, local_direction)),
            };
        },
        .orthographic => |projection| blk: {
            const half_height = projection.size * 0.5;
            const half_width = half_height * aspect;
            const local_origin = .{
                ndc_x * half_width,
                ndc_y * half_height,
                0.0,
            };
            break :blk .{
                .origin = vec3.add(camera_transform.translation, quat.rotateVec3(camera_transform.rotation, local_origin)),
                .direction = normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 })),
            };
        },
    };
}

pub fn activeCameraViewMatrix(state: *const EditorState, layer_context: *engine.core.LayerContext) [16]f32 {
    return mat4.viewMatrix(activeCameraTransform(state, layer_context));
}

pub fn activeCameraIsOrthographic(state: *const EditorState, layer_context: *engine.core.LayerContext) bool {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.getEntityConst(camera_id)) |entity| {
            if (entity.camera) |camera_component| {
                return switch (camera_component.projection) {
                    .orthographic => true,
                    else => false,
                };
            }
        }
    }
    return false;
}

pub fn moveSpeed(state: *const EditorState, delta_seconds: f32) f32 {
    return state.move_speed * @max(delta_seconds, 0.001);
}

fn applyEditorViewDirection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    forward: [3]f32,
    orthographic: bool,
) void {
    const camera_id = state.editor_camera orelse return;
    const camera_entity = layer_context.world.getEntity(camera_id) orelse return;

    state.pitch = utils.clampPitch(std.math.asin(std.math.clamp(forward[1], -1.0, 1.0)));
    state.yaw = std.math.atan2(-forward[0], -forward[2]);
    camera_entity.local_transform = editorCameraTransform(state);
    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = if (orthographic)
            .{ .orthographic = .{ .size = @max(state.orbit_distance * 1.1, 2.0), .near_clip = -1000.0, .far_clip = 1000.0 } }
        else
            .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }
    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

fn requestViewOrientation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    forward: [3]f32,
    orthographic: bool,
    preset: ViewPreset,
) void {
    const camera_id = state.editor_camera orelse return;
    if (!layer_context.world.hasEntity(camera_id)) {
        return;
    }

    state.view_cube_transition_start_yaw = state.yaw;
    state.view_cube_transition_start_pitch = state.pitch;
    state.view_cube_transition_target_pitch = utils.clampPitch(std.math.asin(std.math.clamp(forward[1], -1.0, 1.0)));
    state.view_cube_transition_target_yaw = std.math.atan2(-forward[0], -forward[2]);
    state.view_cube_transition_elapsed = 0.0;
    state.view_cube_transition_target_orthographic = orthographic;
    state.view_cube_transition_active = true;
    state.viewport_view_preset = preset;

    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

fn viewPresetForAxis(axis: [3]f32) ViewPreset {
    if (@abs(axis[1]) >= 0.99) {
        return .top;
    }
    if (@abs(axis[0]) >= 0.99) {
        return .side;
    }
    return .custom;
}

fn updateViewCubeTransition(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.view_cube_transition_active) {
        return;
    }

    const camera_id = state.editor_camera orelse {
        state.view_cube_transition_active = false;
        return;
    };
    const camera_entity = layer_context.world.getEntity(camera_id) orelse {
        state.view_cube_transition_active = false;
        return;
    };

    state.view_cube_transition_elapsed += @max(layer_context.delta_seconds, 0.0);
    const t = std.math.clamp(
        state.view_cube_transition_elapsed / @max(state.view_cube_transition_duration, 0.0001),
        0.0,
        1.0,
    );
    const smooth_t = t * t * (3.0 - 2.0 * t);
    state.yaw = state.view_cube_transition_start_yaw + shortestAngleDelta(state.view_cube_transition_start_yaw, state.view_cube_transition_target_yaw) * smooth_t;
    state.pitch = state.view_cube_transition_start_pitch + (state.view_cube_transition_target_pitch - state.view_cube_transition_start_pitch) * smooth_t;

    camera_entity.local_transform = editorCameraTransform(state);
    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = if (state.view_cube_transition_target_orthographic)
            .{ .orthographic = .{ .size = @max(state.orbit_distance * 1.1, 2.0), .near_clip = -1000.0, .far_clip = 1000.0 } }
        else
            .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }

    if (t >= 0.999) {
        state.view_cube_transition_active = false;
        state.yaw = state.view_cube_transition_target_yaw;
        state.pitch = state.view_cube_transition_target_pitch;
        camera_entity.local_transform = editorCameraTransform(state);
    }
}

fn shortestAngleDelta(from: f32, to: f32) f32 {
    var delta = to - from;
    while (delta > std.math.pi) {
        delta -= std.math.tau;
    }
    while (delta < -std.math.pi) {
        delta += std.math.tau;
    }
    return delta;
}

fn normalize(vector: [3]f32) [3]f32 {
    const len = vec3.length(vector);
    if (len <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return .{
        vector[0] / len,
        vector[1] / len,
        vector[2] / len,
    };
}
