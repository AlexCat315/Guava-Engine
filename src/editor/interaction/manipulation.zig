const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const ai_collaboration = @import("../ai_native/collaboration.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const camera = @import("camera.zig");
const history = @import("../actions/history.zig");
const scene_hierarchy = @import("../ui/panels/scene/scene_hierarchy.zig");

const ManipulationMode = state_mod.ManipulationMode;
const TransformSpace = state_mod.TransformSpace;
const AxisConstraint = state_mod.AxisConstraint;
const ManipulationDragProjection = state_mod.ManipulationDragProjection;
const ManipulationDragSolver = state_mod.ManipulationDragSolver;

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;

    // Use wantsTextInput() instead of wantsCaptureKeyboard(): with
    // NavEnableKeyboard the latter is true whenever nav is active —
    // which blocks shortcuts virtually all the time.  wantsTextInput()
    // is scoped to actual InputText editing and won't interfere.
    if (gui.wantsTextInput()) {
        return;
    }

    if (input.modifiers.ctrl and input.wasKeyPressed(.z)) {
        try history.undo(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.y)) {
        try history.redo(state, layer_context);
        return;
    }

    if (state.manipulation_mode != .none) {
        if (input.wasKeyPressed(.q)) {
            try selectTool(state, layer_context);
            return;
        }
        if (input.wasKeyPressed(.x)) {
            state.manipulation_axis = .x;
        }
        if (input.wasKeyPressed(.y)) {
            state.manipulation_axis = .y;
        }
        if (input.wasKeyPressed(.z)) {
            state.manipulation_axis = .z;
        }
        if (input.wasKeyPressed(.space)) {
            try commitManipulation(state, layer_context);
        }
        if (input.wasKeyPressed(.escape)) {
            cancelManipulation(state, layer_context);
        }
        if (input.wasKeyPressed(.g)) {
            try beginDirectManipulation(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.w) and !input.isMouseDown(.right)) {
            try beginManipulation(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.e)) {
            try beginManipulation(state, layer_context, .rotate);
        }
        if (input.wasKeyPressed(.r)) {
            try beginManipulation(state, layer_context, .scale);
        }
        if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
            try beginDirectManipulation(state, layer_context, .scale);
        }
        return;
    }

    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.t)) {
        state.translation_snap_enabled = !state.translation_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.r)) {
        state.rotation_snap_enabled = !state.rotation_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.s)) {
        state.scale_snap_enabled = !state.scale_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.s)) {
        history.saveScene(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.o)) {
        try history.loadScene(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.n)) {
        try history.newScene(state, layer_context);
        return;
    }

    if (input.wasKeyPressed(.tab)) {
        camera.toggleCameraMode(state, layer_context);
    }
    if (input.wasKeyPressed(.f)) {
        camera.focusSelection(state, layer_context);
    }

    if (input.wasKeyPressed(.delete) or input.wasKeyPressed(.backspace)) {
        try history.deleteSelection(state, layer_context);
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.d)) {
        try history.duplicateSelection(state, layer_context);
    }
    if (input.wasKeyPressed(.p)) {
        if (input.modifiers.shift) {
            try scene_hierarchy.unparentSelection(state, layer_context);
        } else {
            try scene_hierarchy.parentSelection(state, layer_context);
        }
    }
    if (input.wasKeyPressed(.g)) {
        try beginDirectManipulation(state, layer_context, .translate);
    }
    if (input.wasKeyPressed(.q)) {
        try selectTool(state, layer_context);
    }
    if (input.wasKeyPressed(.w) and !input.isMouseDown(.right)) {
        try beginManipulation(state, layer_context, .translate);
    }
    if (input.wasKeyPressed(.e)) {
        try beginManipulation(state, layer_context, .rotate);
    }
    if (input.wasKeyPressed(.r)) {
        try beginManipulation(state, layer_context, .scale);
    }
    if (input.wasKeyPressed(.s) and !input.modifiers.ctrl and !input.isMouseDown(.right)) {
        try beginDirectManipulation(state, layer_context, .scale);
    }
    if (input.wasKeyPressed(.one)) {
        try history.spawnPrimitive(state, layer_context, .cube);
    }
    if (input.wasKeyPressed(.two)) {
        try history.spawnPrimitive(state, layer_context, .sphere);
    }
    if (input.wasKeyPressed(.three)) {
        try history.spawnPrimitive(state, layer_context, .plane);
    }
    if (input.wasKeyPressed(.l)) {
        try history.spawnPointLight(state, layer_context);
    }
}

pub fn beginManipulation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    mode: ManipulationMode,
) !void {
    state.manipulation_mode = mode;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.manipulation_projection = .{};
    state.manipulation_started_from_ui = false;
    clearManipulationSnapshot(state);
    try syncManipulationTarget(state, layer_context);
    syncGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
}

pub fn beginDirectManipulation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    mode: ManipulationMode,
) !void {
    try beginManipulation(state, layer_context, mode);
    state.manipulation_keyboard_mode = true;
    state.manipulation_projection = .{ .solver = .pixel_delta };
    if (state.manipulation_entity != null) {
        state.manipulation_drag_active = true;
        ai_collaboration.noteManipulationBegin(state);
    }
}

pub fn selectTool(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    endManipulation(state);
    syncGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
}

pub fn endManipulation(state: *EditorState) void {
    clearManipulationSnapshot(state);
    state.manipulation_mode = .none;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.manipulation_projection = .{};
    state.manipulation_started_from_ui = false;
}

pub fn cancelManipulation(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const entity_id = state.manipulation_entity orelse {
        endManipulation(state);
        return;
    };
    ai_collaboration.noteManipulationCancel(state, entity_id);
    switch (state.manipulation_target) {
        .main_world => _ = layer_context.world.setEntityWorldTransform(entity_id, state.manipulation_origin),
        .staged_preview => ai_collaboration.cancelPreviewEntityTransform(state, layer_context, entity_id, state.manipulation_origin),
    }
    endManipulation(state);
    syncGizmoState(state, layer_context);
}

fn commitManipulation(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entity_id = state.manipulation_entity orelse {
        endManipulation(state);
        return;
    };
    ai_collaboration.noteManipulationCommit(state, entity_id);
    if (state.manipulation_target == .staged_preview) {
        const runtime = state.ai_preview_runtime orelse {
            endManipulation(state);
            return;
        };
        const transform = runtime.world.worldTransformConst(entity_id) orelse {
            endManipulation(state);
            return;
        };
        _ = try ai_collaboration.commitPreviewEntityTransform(state, layer_context, entity_id, transform);
        endManipulation(state);
        syncGizmoState(state, layer_context);
        return;
    }
    const before = state.manipulation_snapshot orelse {
        endManipulation(state);
        return;
    };
    state.manipulation_snapshot = null;
    state.manipulation_mode = .none;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.manipulation_projection = .{};
    state.manipulation_started_from_ui = false;
    try history.recordEntityMutation(state, layer_context, before, &.{entity_id});
    syncGizmoState(state, layer_context);
}

fn clearManipulationSnapshot(state: *EditorState) void {
    const allocator = state.allocator orelse {
        state.manipulation_snapshot = null;
        return;
    };
    if (state.manipulation_snapshot) |*snapshot| {
        snapshot.deinit(allocator);
        state.manipulation_snapshot = null;
    }
}

pub fn applyManipulation(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const input = layer_context.input;

    // Keyboard-mode (Blender-style): mouse moves freely, left-click confirms,
    // right-click cancels.  Do NOT commit on mouse release.
    if (state.manipulation_keyboard_mode and state.manipulation_drag_active) {
        // Right-click or Escape → cancel
        if (input.wasMousePressed(.right)) {
            cancelManipulation(state, layer_context);
            return;
        }
        // Left-click → confirm (commit history and end)
        if (input.wasMousePressed(.left)) {
            commitManipulation(state, layer_context) catch |err| {
                std.log.err("Failed to commit keyboard manipulation: {}", .{err});
            };
            return;
        }

        const entity_id = state.manipulation_entity orelse return;
        // Accumulate mouse delta and apply transform
        state.manipulation_drag_accumulator[0] += input.mouse_delta[0];
        state.manipulation_drag_accumulator[1] += input.mouse_delta[1];
        state.manipulation_accumulated_delta[0] += input.mouse_delta[0];
        state.manipulation_accumulated_delta[1] += input.mouse_delta[1];

        var entity_transform = state.manipulation_origin;
        switch (state.manipulation_mode) {
            .none => {},
            .translate => applyTranslate(state, layer_context, &entity_transform),
            .rotate => applyRotate(state, &entity_transform),
            .scale => applyScale(state, &entity_transform),
        }
        switch (state.manipulation_target) {
            .main_world => _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform),
            .staged_preview => {
                if (state.ai_preview_runtime) |*runtime| {
                    _ = runtime.world.setEntityWorldTransform(entity_id, entity_transform);
                    runtime.world.updateHierarchy();
                }
            },
        }
        return;
    }

    // 1. ALWAYS reset UI interaction lock on mouse release to prevent deadlocks
    if (!input.isMouseDown(.left)) {
        state.manipulation_started_from_ui = false;

        if (state.manipulation_drag_active) {
            if (state.manipulation_entity) |entity_id| {
                if (state.manipulation_target == .staged_preview) {
                    if (state.ai_preview_runtime) |*runtime| {
                        if (runtime.world.worldTransformConst(entity_id)) |transform| {
                            _ = ai_collaboration.commitPreviewEntityTransform(state, layer_context, entity_id, transform) catch |err| {
                                std.log.err("Failed to commit preview manipulation: {}", .{err});
                            };
                        }
                    }
                } else if (state.manipulation_snapshot) |before| {
                    state.manipulation_snapshot = null; // Prevent double free
                    history.recordEntityMutation(state, layer_context, before, &.{entity_id}) catch |err| {
                        std.log.err("Failed to commit manipulation history: {}", .{err});
                    };

                    clearManipulationSnapshot(state); // Now safe since snapshot is null
                    if (history.captureEntitySnapshot(state, layer_context.world, entity_id)) |new_snapshot| {
                        state.manipulation_snapshot = new_snapshot;
                    } else |err| {
                        std.log.err("Failed to capture snapshot: {}", .{err});
                    }

                    if (layer_context.world.worldTransform(entity_id)) |transform| {
                        state.manipulation_origin = transform;
                    }
                }
            }
            state.manipulation_drag_active = false;
            state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
            state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
            state.manipulation_projection = .{};
        }
        return;
    }

    // 2. If the drag started on a UI element, ignore all movement
    if (state.manipulation_started_from_ui) {
        return;
    }

    const entity_id = state.manipulation_entity orelse return;
    _ = currentManipulationTransform(state, layer_context, entity_id) orelse {
        endManipulation(state);
        return;
    };

    if (!state.manipulation_drag_active) return;

    if (state.manipulation_projection.solver != .none and state.manipulation_projection.solver != .pixel_delta) {
        const ray = currentViewportRay(state, layer_context, true) orelse return;
        var entity_transform = state.manipulation_origin;

        switch (state.manipulation_mode) {
            .none => {},
            .translate => applyProjectedTranslate(state, layer_context, ray, &entity_transform),
            .rotate => applyProjectedRotate(state, ray, &entity_transform),
            .scale => applyProjectedScale(state, ray, &entity_transform),
        }

        switch (state.manipulation_target) {
            .main_world => _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform),
            .staged_preview => {
                if (state.ai_preview_runtime) |*runtime| {
                    _ = runtime.world.setEntityWorldTransform(entity_id, entity_transform);
                    runtime.world.updateHierarchy();
                }
            },
        }
        return;
    }

    if (@abs(input.mouse_delta[0]) < 0.0001 and @abs(input.mouse_delta[1]) < 0.0001) {
        return;
    }

    state.manipulation_drag_accumulator[0] += input.mouse_delta[0];
    state.manipulation_drag_accumulator[1] += input.mouse_delta[1];
    state.manipulation_accumulated_delta[0] += input.mouse_delta[0];
    state.manipulation_accumulated_delta[1] += input.mouse_delta[1];

    var entity_transform = state.manipulation_origin;

    switch (state.manipulation_mode) {
        .none => {},
        .translate => applyTranslate(state, layer_context, &entity_transform),
        .rotate => applyRotate(state, &entity_transform),
        .scale => applyScale(state, &entity_transform),
    }

    switch (state.manipulation_target) {
        .main_world => _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform),
        .staged_preview => {
            if (state.ai_preview_runtime) |*runtime| {
                _ = runtime.world.setEntityWorldTransform(entity_id, entity_transform);
                runtime.world.updateHierarchy();
            }
        },
    }
}

const ManipulationCameraBasis = struct {
    right: [3]f32,
    up: [3]f32,
    forward: [3]f32,
};

fn effectiveViewportMousePos(layer_context: *const engine.core.LayerContext) [2]f32 {
    const imgui_mouse_pos = gui.mousePos();
    const invalid_imgui_mouse = !std.math.isFinite(imgui_mouse_pos[0]) or
        !std.math.isFinite(imgui_mouse_pos[1]) or
        imgui_mouse_pos[0] <= -std.math.floatMax(f32) * 0.5 or
        imgui_mouse_pos[1] <= -std.math.floatMax(f32) * 0.5;
    return if (invalid_imgui_mouse) layer_context.input.mouse_position else imgui_mouse_pos;
}

fn viewportPixelFromMouse(
    state: *const EditorState,
    layer_context: *const engine.core.LayerContext,
    clamp_to_viewport: bool,
) ?[2]u32 {
    if (state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) return null;

    const mouse_pos = effectiveViewportMousePos(layer_context);
    var local_x = mouse_pos[0] - state.viewport_origin[0];
    var local_y = mouse_pos[1] - state.viewport_origin[1];
    if (clamp_to_viewport) {
        local_x = std.math.clamp(local_x, 0.0, state.viewport_extent[0]);
        local_y = std.math.clamp(local_y, 0.0, state.viewport_extent[1]);
    } else if (local_x < 0.0 or local_y < 0.0 or local_x > state.viewport_extent[0] or local_y > state.viewport_extent[1]) {
        return null;
    }

    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0) return null;

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

fn currentViewportRay(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    clamp_to_viewport: bool,
) ?engine.scene.Ray {
    const pixel = viewportPixelFromMouse(state, layer_context, clamp_to_viewport) orelse return null;
    const viewport_size = layer_context.renderer.sceneViewportSize();
    return camera.activeCameraRayFromViewportPixel(state, layer_context, pixel, viewport_size);
}

fn safeNormalizeOr(vector: [3]f32, fallback: [3]f32) [3]f32 {
    if (vec3.length(vector) <= 0.0001) return vec3.normalize(fallback);
    return vec3.normalize(vector);
}

fn manipulationCameraBasis(state: *const EditorState, layer_context: *engine.core.LayerContext) ManipulationCameraBasis {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    return .{
        .right = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 1.0, 0.0, 0.0 })),
        .up = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 1.0, 0.0 })),
        .forward = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 })),
    };
}

fn rayPlaneIntersection(ray: engine.scene.Ray, plane_origin: [3]f32, plane_normal: [3]f32) ?[3]f32 {
    const normal = safeNormalizeOr(plane_normal, .{ 0.0, 0.0, -1.0 });
    const denom = vec3.dot(ray.direction, normal);
    if (@abs(denom) < 1e-5) return null;

    const t = vec3.dot(vec3.sub(plane_origin, ray.origin), normal) / denom;
    if (t < 0.0) return null;
    return vec3.add(ray.origin, vec3.scale(ray.direction, t));
}

fn axisDragPlaneNormal(axis_world: [3]f32, camera_forward: [3]f32, camera_up: [3]f32) [3]f32 {
    const view_cross_axis = vec3.cross(camera_forward, axis_world);
    var normal = vec3.cross(axis_world, view_cross_axis);
    if (vec3.length(normal) <= 0.0001) {
        normal = vec3.cross(axis_world, camera_up);
    }
    if (vec3.length(normal) <= 0.0001) {
        normal = vec3.cross(axis_world, .{ 1.0, 0.0, 0.0 });
    }
    return safeNormalizeOr(normal, camera_forward);
}

fn scalePlaneDirection(camera_right: [3]f32, camera_up: [3]f32) [3]f32 {
    return safeNormalizeOr(vec3.add(camera_right, camera_up), camera_right);
}

fn signedAngleAroundAxis(from_vector: [3]f32, to_vector: [3]f32, axis: [3]f32) f32 {
    const from_norm = safeNormalizeOr(from_vector, .{ 1.0, 0.0, 0.0 });
    const to_norm = safeNormalizeOr(to_vector, .{ 1.0, 0.0, 0.0 });
    const axis_norm = safeNormalizeOr(axis, .{ 0.0, 1.0, 0.0 });
    const cross_value = vec3.cross(from_norm, to_norm);
    const sin_angle = vec3.dot(axis_norm, cross_value);
    const cos_angle = std.math.clamp(vec3.dot(from_norm, to_norm), -1.0, 1.0);
    return std.math.atan2(sin_angle, cos_angle);
}

fn initializeProjectedManipulationDrag(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    picked_handle: PickedGizmoHandle,
    ray: engine.scene.Ray,
) void {
    const entity_id = state.manipulation_entity orelse {
        state.manipulation_projection = .{ .solver = .pixel_delta };
        return;
    };
    const entity_transform = currentManipulationTransform(state, layer_context, entity_id) orelse {
        state.manipulation_projection = .{ .solver = .pixel_delta };
        return;
    };
    const camera_basis = manipulationCameraBasis(state, layer_context);
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const axis_world = if (picked_handle.axis == .free)
        [3]f32{ 0.0, 0.0, 0.0 }
    else
        manipulationAxisVector(state.transform_space, picked_handle.axis, entity_transform.rotation);
    const gizmo_scale_value = gizmoScale(camera_transform.translation, entity_transform.translation);

    var projection = ManipulationDragProjection{
        .solver = .pixel_delta,
        .plane_origin = entity_transform.translation,
        .plane_normal = camera_basis.forward,
        .axis_world = if (picked_handle.axis == .free) scalePlaneDirection(camera_basis.right, camera_basis.up) else axis_world,
        .gizmo_scale = gizmo_scale_value,
    };

    switch (picked_handle.mode) {
        .translate => {
            if (picked_handle.axis == .free) {
                projection.solver = .translate_plane;
                projection.plane_normal = camera_basis.forward;
            } else {
                projection.solver = .translate_axis;
                projection.plane_normal = axisDragPlaneNormal(axis_world, camera_basis.forward, camera_basis.up);
            }
            projection.start_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.solver = .pixel_delta;
                state.manipulation_projection = projection;
                return;
            };
        },
        .rotate => {
            projection.solver = .rotate_ring;
            projection.axis_world = axis_world;
            projection.plane_normal = safeNormalizeOr(axis_world, camera_basis.up);
            const start_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.solver = .pixel_delta;
                state.manipulation_projection = projection;
                return;
            };
            projection.start_vector = vec3.sub(start_point, projection.plane_origin);
            if (vec3.length(projection.start_vector) <= 0.0001) {
                projection.solver = .pixel_delta;
                state.manipulation_projection = projection;
                return;
            }
            projection.start_vector = vec3.normalize(projection.start_vector);
        },
        .scale => {
            if (picked_handle.axis == .free) {
                projection.solver = .scale_plane;
                projection.plane_normal = camera_basis.forward;
                projection.axis_world = scalePlaneDirection(camera_basis.right, camera_basis.up);
            } else {
                projection.solver = .scale_axis;
                projection.plane_normal = axisDragPlaneNormal(axis_world, camera_basis.forward, camera_basis.up);
            }
            projection.start_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.solver = .pixel_delta;
                state.manipulation_projection = projection;
                return;
            };
        },
        .none => projection.solver = .none,
    }

    state.manipulation_projection = projection;
}

fn applyProjectedTranslate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    _ = layer_context;
    const projection = state.manipulation_projection;
    const current_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse return;

    var target = switch (projection.solver) {
        .translate_plane => vec3.add(
            state.manipulation_origin.translation,
            vec3.sub(current_point, projection.start_point),
        ),
        .translate_axis => vec3.add(
            state.manipulation_origin.translation,
            vec3.scale(
                projection.axis_world,
                vec3.dot(vec3.sub(current_point, projection.start_point), projection.axis_world),
            ),
        ),
        else => return,
    };

    if (state.translation_snap_enabled) {
        target = snapVec3FromOrigin(state.manipulation_origin.translation, target, state.translation_snap_step);
    }

    entity_transform.translation = target;
}

fn applyProjectedRotate(
    state: *EditorState,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    const projection = state.manipulation_projection;
    const current_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse return;
    const current_vector = vec3.sub(current_point, projection.plane_origin);
    if (vec3.length(current_vector) <= 0.0001) return;

    var angle = signedAngleAroundAxis(projection.start_vector, current_vector, projection.axis_world);
    if (state.rotation_snap_enabled) {
        const snap_radians = state.rotation_snap_step_degrees * std.math.pi / 180.0;
        angle = @round(angle / snap_radians) * snap_radians;
    }

    entity_transform.rotation = switch (state.transform_space) {
        .local => quat.normalize(quat.mul(
            state.manipulation_origin.rotation,
            quat.fromAxisAngle(engine.math.axis.vector(state.manipulation_axis), angle),
        )),
        .world => quat.normalize(quat.mul(
            quat.fromAxisAngle(projection.axis_world, angle),
            state.manipulation_origin.rotation,
        )),
    };
}

fn applyProjectedScale(
    state: *EditorState,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    const projection = state.manipulation_projection;
    const current_point = rayPlaneIntersection(ray, projection.plane_origin, projection.plane_normal) orelse return;
    const amount = vec3.dot(vec3.sub(current_point, projection.start_point), projection.axis_world) /
        @max(projection.gizmo_scale, 0.05);
    const scalar = @max(0.05, 1.0 + amount);

    var raw_scale = state.manipulation_origin.scale;
    switch (projection.solver) {
        .scale_plane => {
            raw_scale[0] *= scalar;
            raw_scale[1] *= scalar;
            raw_scale[2] *= scalar;
        },
        .scale_axis => switch (state.manipulation_axis) {
            .free => {
                raw_scale[0] *= scalar;
                raw_scale[1] *= scalar;
                raw_scale[2] *= scalar;
            },
            .x => raw_scale[0] *= scalar,
            .y => raw_scale[1] *= scalar,
            .z => raw_scale[2] *= scalar,
        },
        else => return,
    }

    if (state.scale_snap_enabled) {
        raw_scale = snapScaleFromOrigin(state.manipulation_origin.scale, raw_scale, state.scale_snap_step);
    }

    entity_transform.scale = .{
        utils.clampScale(raw_scale[0]),
        utils.clampScale(raw_scale[1]),
        utils.clampScale(raw_scale[2]),
    };
}

pub fn applyTranslate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_transform: *engine.scene.Transform,
) void {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const camera_euler = quat.toEuler(camera_transform.rotation);
    const right = vec3.rightFromYaw(camera_euler[1]);
    const forward = vec3.forwardFromAngles(camera_euler[1], camera_euler[0]);
    const up = vec3.normalize(vec3.cross(right, forward));

    // 使用manipulation_origin锁定距离计算，防止操作过程中的速率抖动
    const distance = @max(vec3.length(vec3.sub(camera_transform.translation, state.manipulation_origin.translation)), 1.0);
    const move_scale = distance * state.translation_drag_sensitivity;

    // 基于累计偏移量计算
    switch (state.manipulation_axis) {
        .free => {
            const delta = vec3.add(
                vec3.scale(right, state.manipulation_accumulated_delta[0] * move_scale),
                vec3.scale(up, state.manipulation_accumulated_delta[1] * move_scale),
            );
            entity_transform.translation = vec3.add(state.manipulation_origin.translation, delta);
        },
        .x, .y, .z => {
            const axis = manipulationAxisVector(state.transform_space, state.manipulation_axis, state.manipulation_origin.rotation);
            const scalar = combinedDrag(state.manipulation_accumulated_delta) * move_scale;
            entity_transform.translation = vec3.add(state.manipulation_origin.translation, vec3.scale(axis, scalar));
        },
    }

    // 对计算出的绝对值进行Snap，不污染下一次计算
    if (state.translation_snap_enabled) {
        const origin = state.manipulation_origin.translation;
        const snap = state.translation_snap_step;
        const delta_x = entity_transform.translation[0] - origin[0];
        const delta_y = entity_transform.translation[1] - origin[1];
        const delta_z = entity_transform.translation[2] - origin[2];

        entity_transform.translation = .{
            origin[0] + @round(delta_x / snap) * snap,
            origin[1] + @round(delta_y / snap) * snap,
            origin[2] + @round(delta_z / snap) * snap,
        };
    }
}
pub fn applyRotate(state: *EditorState, entity_transform: *engine.scene.Transform) void {
    // 基于累计偏移量计算旋转
    const scalar = combinedDrag(state.manipulation_accumulated_delta) * state.rotation_drag_sensitivity;
    const origin_euler = quat.toEuler(state.manipulation_origin.rotation);
    var euler = origin_euler;

    switch (state.manipulation_axis) {
        .free => {
            euler[1] -= state.manipulation_accumulated_delta[0] * state.rotation_drag_sensitivity;
            euler[0] -= state.manipulation_accumulated_delta[1] * state.rotation_drag_sensitivity;
        },
        .x => euler[0] += scalar,
        .y => euler[1] += scalar,
        .z => euler[2] += scalar,
    }

    // 对计算出的绝对值进行Snap，不污染下一次计算
    if (state.rotation_snap_enabled) {
        const snap_radians = state.rotation_snap_step_degrees * std.math.pi / 180.0;
        const delta_x = euler[0] - origin_euler[0];
        const delta_y = euler[1] - origin_euler[1];
        const delta_z = euler[2] - origin_euler[2];

        euler = .{
            origin_euler[0] + @round(delta_x / snap_radians) * snap_radians,
            origin_euler[1] + @round(delta_y / snap_radians) * snap_radians,
            origin_euler[2] + @round(delta_z / snap_radians) * snap_radians,
        };
    }

    entity_transform.rotation = quat.fromEuler(euler);
}

pub fn applyScale(state: *EditorState, entity_transform: *engine.scene.Transform) void {
    // 使用累计偏移量计算标量
    const scalar = 1.0 + combinedDrag(state.manipulation_accumulated_delta) * state.scale_drag_sensitivity;

    // 始终从原点计算，避免精度丢失
    var raw_scale = state.manipulation_origin.scale;
    switch (state.manipulation_axis) {
        .free => {
            raw_scale[0] *= scalar;
            raw_scale[1] *= scalar;
            raw_scale[2] *= scalar;
        },
        .x => raw_scale[0] *= scalar,
        .y => raw_scale[1] *= scalar,
        .z => raw_scale[2] *= scalar,
    }

    // 对绝对值进行Snap，不污染下一次计算
    if (state.scale_snap_enabled) {
        const origin = state.manipulation_origin.scale;
        const snap = state.scale_snap_step;
        const delta_x = raw_scale[0] - origin[0];
        const delta_y = raw_scale[1] - origin[1];
        const delta_z = raw_scale[2] - origin[2];

        raw_scale = .{
            origin[0] + @round(delta_x / snap) * snap,
            origin[1] + @round(delta_y / snap) * snap,
            origin[2] + @round(delta_z / snap) * snap,
        };
    }

    entity_transform.scale = .{
        utils.clampScale(raw_scale[0]),
        utils.clampScale(raw_scale[1]),
        utils.clampScale(raw_scale[2]),
    };
}

pub fn syncGizmoState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    syncManipulationTarget(state, layer_context) catch |err| {
        std.log.err("failed to sync manipulation target: {}", .{err});
    };
    layer_context.renderer.setEditorGizmoState(.{
        .mode = switch (state.manipulation_mode) {
            .none => .idle,
            .translate => .translate,
            .rotate => .rotate,
            .scale => .scale,
        },
        .axis = state.manipulation_axis,
        .space = switch (state.transform_space) {
            .local => .local,
            .world => .world,
        },
    });
}

fn syncManipulationTarget(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.manipulation_mode == .none or state.manipulation_drag_active) {
        if (state.manipulation_mode == .none) {
            clearManipulationSnapshot(state);
            state.manipulation_entity = null;
        }
        return;
    }

    const next = nextManipulationTarget(state, layer_context);

    if (next.entity_id == state.manipulation_entity and next.target == state.manipulation_target) {
        return;
    }

    clearManipulationSnapshot(state);
    state.manipulation_entity = next.entity_id;
    state.manipulation_target = next.target;
    state.manipulation_drag_active = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };

    if (next.entity_id) |entity_id| {
        state.manipulation_origin = currentManipulationTransform(state, layer_context, entity_id) orelse return;
        if (next.target == .main_world) {
            state.manipulation_snapshot = try history.captureEntitySnapshot(state, layer_context.world, entity_id);
        }
    }
}

const NextManipulationTarget = struct {
    entity_id: ?engine.scene.EntityId = null,
    target: state_mod.ManipulationTarget = .main_world,
};

fn nextManipulationTarget(state: *EditorState, layer_context: *engine.core.LayerContext) NextManipulationTarget {
    if (state.ai_preview_selected_entity) |entity_id| {
        if (state.ai_preview_runtime) |*runtime| {
            if (runtime.world.hasEntity(entity_id)) {
                return .{
                    .entity_id = entity_id,
                    .target = .staged_preview,
                };
            }
        }
    }

    const selected = layer_context.renderer.selectedEntity();
    const next_entity = blk: {
        const entity_id = selected orelse break :blk null;
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            break :blk null;
        }
        if (utils.isEntitySelectionLocked(state, entity_id)) {
            break :blk null;
        }
        break :blk entity_id;
    };
    return .{
        .entity_id = next_entity,
        .target = .main_world,
    };
}

fn currentManipulationTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) ?engine.scene.Transform {
    return switch (state.manipulation_target) {
        .main_world => layer_context.world.worldTransform(entity_id),
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            runtime.world.worldTransformConst(entity_id)
        else
            null,
    };
}

fn manipulationAxisVector(space: TransformSpace, axis: state_mod.AxisConstraint, rotation: [4]f32) [3]f32 {
    const base_axis = engine.math.axis.vector(axis);
    return switch (space) {
        .world => base_axis,
        .local => engine.math.quat.rotateVec3(rotation, base_axis),
    };
}

fn combinedDrag(drag: [2]f32) f32 {
    return drag[0] + drag[1];
}

fn snapVec3FromOrigin(origin: [3]f32, target: [3]f32, step: f32) [3]f32 {
    return .{
        origin[0] + @round((target[0] - origin[0]) / step) * step,
        origin[1] + @round((target[1] - origin[1]) / step) * step,
        origin[2] + @round((target[2] - origin[2]) / step) * step,
    };
}

fn snapScaleFromOrigin(origin: [3]f32, target: [3]f32, step: f32) [3]f32 {
    return .{
        utils.clampScale(origin[0] + @round((target[0] - origin[0]) / step) * step),
        utils.clampScale(origin[1] + @round((target[1] - origin[1]) / step) * step),
        utils.clampScale(origin[2] + @round((target[2] - origin[2]) / step) * step),
    };
}

fn rotateVec3Euler(rotation: [3]f32, vector: [3]f32) [3]f32 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn rotateX(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

// ── Gizmo axis click interaction ─────────────────────────────────────────────

/// Result of picking a gizmo handle under the cursor.
pub const PickedGizmoHandle = struct {
    axis: AxisConstraint,
    mode: ManipulationMode,
    distance: f32,
};

/// Compute the gizmo visual scale matching gizmo_pass.scaleForSelection.
fn gizmoScale(camera_position: [3]f32, target_position: [3]f32) f32 {
    const dx = camera_position[0] - target_position[0];
    const dy = camera_position[1] - target_position[1];
    const dz = camera_position[2] - target_position[2];
    const distance = std.math.sqrt(dx * dx + dy * dy + dz * dz);
    return std.math.clamp(distance * 0.18, 0.7, 3.4);
}

/// Ray-capsule distance test: returns the closest approach distance of a ray to
/// a line segment (axis_start → axis_end), or null if the closest point is not
/// within `threshold` world units.
fn rayAxisDistance(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    axis_start: [3]f32,
    axis_end: [3]f32,
) f32 {
    // Direction vectors
    const d = ray_direction;
    const e = vec3.sub(axis_end, axis_start);
    const w = vec3.sub(ray_origin, axis_start);

    const a = vec3.dot(d, d);
    const b = vec3.dot(d, e);
    const c = vec3.dot(e, e);
    const d_val = vec3.dot(d, w);
    const e_val = vec3.dot(e, w);

    const denom = a * c - b * b;
    if (@abs(denom) < 1e-8) {
        // Parallel lines — use distance from ray origin to segment
        const t_seg = std.math.clamp(-e_val / @max(c, 1e-8), 0.0, 1.0);
        const closest_on_seg = vec3.add(axis_start, vec3.scale(e, t_seg));
        return vec3.length(vec3.sub(closest_on_seg, ray_origin));
    }

    var t_ray = (b * e_val - c * d_val) / denom;
    var t_seg = (a * e_val - b * d_val) / denom;

    // Clamp segment parameter to [0, 1]
    t_seg = std.math.clamp(t_seg, 0.0, 1.0);
    // Recompute ray parameter for clamped segment point (must be non-negative)
    t_ray = @max((b * t_seg + d_val) / @max(a, 1e-8), 0.0);

    const closest_on_ray = vec3.add(ray_origin, vec3.scale(d, t_ray));
    const closest_on_seg = vec3.add(axis_start, vec3.scale(e, t_seg));

    return vec3.length(vec3.sub(closest_on_ray, closest_on_seg));
}

fn mulPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
}

fn worldPointToViewportScreen(
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
    const clip = mulPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
    if (@abs(clip[3]) <= 0.00001 or clip[3] <= 0.0) return null;

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    if (ndc_x < -1.2 or ndc_x > 1.2 or ndc_y < -1.2 or ndc_y > 1.2) return null;

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn length2d(vector: [2]f32) f32 {
    return std.math.sqrt(vector[0] * vector[0] + vector[1] * vector[1]);
}

fn distancePointToSegment2d(point: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const ab = .{ b[0] - a[0], b[1] - a[1] };
    const ab_len_sq = ab[0] * ab[0] + ab[1] * ab[1];
    if (ab_len_sq <= 0.0001) return length2d(.{ point[0] - a[0], point[1] - a[1] });

    const ap = .{ point[0] - a[0], point[1] - a[1] };
    const t = std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / ab_len_sq, 0.0, 1.0);
    const closest = .{ a[0] + ab[0] * t, a[1] + ab[1] * t };
    return length2d(.{ point[0] - closest[0], point[1] - closest[1] });
}

fn perpendicularBasis(normal: [3]f32) [2][3]f32 {
    const n = safeNormalizeOr(normal, .{ 0.0, 1.0, 0.0 });
    const reference = if (@abs(n[1]) < 0.9)
        [3]f32{ 0.0, 1.0, 0.0 }
    else
        [3]f32{ 1.0, 0.0, 0.0 };
    const tangent = safeNormalizeOr(vec3.cross(n, reference), .{ 1.0, 0.0, 0.0 });
    const bitangent = safeNormalizeOr(vec3.cross(n, tangent), .{ 0.0, 0.0, 1.0 });
    return .{ tangent, bitangent };
}

fn pickTranslateOrScaleHandleScreenSpace(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    origin: [3]f32,
    axes: [3][3]f32,
    axis_ids: [3]AxisConstraint,
    mode: ManipulationMode,
    scale: f32,
) ?PickedGizmoHandle {
    const mouse = effectiveViewportMousePos(layer_context);
    const origin_screen = worldPointToViewportScreen(state, layer_context, origin) orelse return null;

    const axis_pick_radius_px: f32 = 12.0;
    const center_pick_radius_px: f32 = if (mode == .translate) 14.0 else 16.0;
    const min_axis_projected_len_px: f32 = 16.0;
    var best: ?PickedGizmoHandle = null;

    for (axes, axis_ids) |axis_dir, axis_id| {
        const axis_end = vec3.add(origin, vec3.scale(axis_dir, scale));
        const axis_end_screen = worldPointToViewportScreen(state, layer_context, axis_end) orelse continue;
        if (length2d(.{ axis_end_screen[0] - origin_screen[0], axis_end_screen[1] - origin_screen[1] }) < min_axis_projected_len_px) {
            continue;
        }
        const dist = distancePointToSegment2d(mouse, origin_screen, axis_end_screen);
        if (dist <= axis_pick_radius_px and (best == null or dist < best.?.distance)) {
            best = .{ .axis = axis_id, .mode = mode, .distance = dist };
        }
    }

    const center_dist = length2d(.{ mouse[0] - origin_screen[0], mouse[1] - origin_screen[1] });
    if (center_dist <= center_pick_radius_px and (best == null or center_dist <= best.?.distance * 0.8)) {
        best = .{ .axis = .free, .mode = mode, .distance = center_dist };
    }
    return best;
}

fn pickRotateHandleScreenSpace(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    origin: [3]f32,
    axes: [3][3]f32,
    axis_ids: [3]AxisConstraint,
    scale: f32,
) ?PickedGizmoHandle {
    const mouse = effectiveViewportMousePos(layer_context);
    const ring_radius = 0.9 * scale;
    const ring_pick_radius_px: f32 = 12.0;
    const samples: usize = 40;
    var best: ?PickedGizmoHandle = null;

    for (axes, axis_ids) |axis_normal, axis_id| {
        const basis = perpendicularBasis(axis_normal);
        var previous_screen: ?[2]f32 = null;
        var min_dist = std.math.inf(f32);
        var visible_segments: usize = 0;

        var sample_index: usize = 0;
        while (sample_index <= samples) : (sample_index += 1) {
            const t = (@as(f32, @floatFromInt(sample_index)) / @as(f32, @floatFromInt(samples))) * std.math.tau;
            const ring_point = vec3.add(
                origin,
                vec3.add(
                    vec3.scale(basis[0], std.math.cos(t) * ring_radius),
                    vec3.scale(basis[1], std.math.sin(t) * ring_radius),
                ),
            );
            const screen_point = worldPointToViewportScreen(state, layer_context, ring_point);
            if (previous_screen) |previous| {
                if (screen_point) |current| {
                    visible_segments += 1;
                    min_dist = @min(min_dist, distancePointToSegment2d(mouse, previous, current));
                }
            }
            previous_screen = screen_point;
        }

        if (visible_segments == 0) continue;
        if (min_dist <= ring_pick_radius_px and (best == null or min_dist < best.?.distance)) {
            best = .{ .axis = axis_id, .mode = .rotate, .distance = min_dist };
        }
    }

    return best;
}

/// Pick the gizmo handle under the current ray for the selected entity.
/// Returns the best handle, or null if nothing was clicked.
pub fn pickGizmoHandle(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
) ?PickedGizmoHandle {
    // Only test when a manipulation tool is active AND an entity is selected
    if (state.manipulation_mode == .none) return null;
    const entity_id = layer_context.renderer.selectedEntity() orelse return null;
    if (state.editor_camera != null and entity_id == state.editor_camera.?) return null;

    const entity_transform = switch (state.manipulation_target) {
        .main_world => layer_context.world.worldTransformConst(entity_id) orelse return null,
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            runtime.world.worldTransformConst(entity_id) orelse return null
        else
            return null,
    };

    const cam_transform = camera.activeCameraTransform(state, layer_context);
    const scale = gizmoScale(cam_transform.translation, entity_transform.translation);
    const threshold = scale * 0.18; // click tolerance in world units

    const rotation_euler = switch (state.transform_space) {
        .local => quat.toEuler(entity_transform.rotation),
        .world => [3]f32{ 0.0, 0.0, 0.0 },
    };

    const mode: ManipulationMode = state.manipulation_mode;
    const origin = entity_transform.translation;

    // Build the three axis directions in world space (considering transform space)
    const axes = [3][3]f32{
        rotateVec3Euler(rotation_euler, .{ 1.0, 0.0, 0.0 }),
        rotateVec3Euler(rotation_euler, .{ 0.0, 1.0, 0.0 }),
        rotateVec3Euler(rotation_euler, .{ 0.0, 0.0, 1.0 }),
    };
    const axis_ids = [3]AxisConstraint{ .x, .y, .z };

    var best: ?PickedGizmoHandle = null;
    const ray_dir = vec3.normalize(ray.direction);

    switch (mode) {
        .translate, .scale => {
            if (pickTranslateOrScaleHandleScreenSpace(state, layer_context, origin, axes, axis_ids, mode, scale)) |picked_handle| {
                return picked_handle;
            }
            // Test ray against each axis line segment (length = scale in world)
            for (axes, axis_ids) |axis_dir, axis_id| {
                const axis_end = vec3.add(origin, vec3.scale(axis_dir, scale));
                const dist = rayAxisDistance(ray.origin, ray_dir, origin, axis_end);
                if (dist < threshold) {
                    if (best == null or dist < best.?.distance) {
                        best = .{ .axis = axis_id, .mode = mode, .distance = dist };
                    }
                }
            }
            // Test center region (free axis) — a sphere around origin
            const to_origin = vec3.sub(origin, ray.origin);
            const t = vec3.dot(to_origin, ray_dir);
            const closest = vec3.add(ray.origin, vec3.scale(ray_dir, @max(t, 0.0)));
            const center_dist = vec3.length(vec3.sub(closest, origin));
            if (center_dist < scale * 0.28) {
                if (best == null or center_dist < best.?.distance) {
                    best = .{ .axis = .free, .mode = mode, .distance = center_dist };
                }
            }
        },
        .rotate => {
            if (pickRotateHandleScreenSpace(state, layer_context, origin, axes, axis_ids, scale)) |picked_handle| {
                return picked_handle;
            }
            // Test ray against each rotation ring (radius = 0.9 * scale)
            const ring_radius = 0.9 * scale;
            const ring_threshold = scale * 0.19;
            for (axes, axis_ids) |axis_normal, axis_id| {
                // Intersect ray with the plane of the ring
                const n_dot_d = vec3.dot(axis_normal, ray_dir);
                if (@abs(n_dot_d) < 1e-6) continue; // ray parallel to ring plane
                const t_plane = vec3.dot(vec3.sub(origin, ray.origin), axis_normal) / n_dot_d;
                if (t_plane < 0) continue;
                const hit_point = vec3.add(ray.origin, vec3.scale(ray_dir, t_plane));
                const dist_from_center = vec3.length(vec3.sub(hit_point, origin));
                const ring_dist = @abs(dist_from_center - ring_radius);
                if (ring_dist < ring_threshold) {
                    if (best == null or ring_dist < best.?.distance) {
                        best = .{ .axis = axis_id, .mode = mode, .distance = ring_dist };
                    }
                }
            }
        },
        .none => {},
    }

    return best;
}

/// Begin manipulation from a picked gizmo handle (mouse-hold drag mode, not keyboard mode).
pub fn beginManipulationFromPickedGizmoHandle(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    picked_handle: PickedGizmoHandle,
    ray: engine.scene.Ray,
) !void {
    state.manipulation_mode = picked_handle.mode;
    state.manipulation_axis = picked_handle.axis;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_started_from_ui = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    clearManipulationSnapshot(state);
    try syncManipulationTarget(state, layer_context);
    if (state.manipulation_entity != null) {
        initializeProjectedManipulationDrag(state, layer_context, picked_handle, ray);
        state.manipulation_drag_active = true;
    }
    syncGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
    ai_collaboration.noteManipulationBegin(state);
}

test "manipulationAxisVector rotates constrained local axes" {
    const axis = manipulationAxisVector(.local, .x, .{ 0.0, std.math.pi * 0.5, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), axis[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), axis[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), axis[2], 0.0001);
}

test "scale snap uses accumulated delta from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .free;
    state.manipulation_origin.scale = .{ 1.0, 1.0, 1.0 };
    state.scale_drag_sensitivity = 0.1;
    state.scale_snap_enabled = true;
    state.scale_snap_step = 0.1;

    // 使用manipulation_accumulated_delta而不是manipulation_drag_accumulator
    state.manipulation_accumulated_delta = .{ 0.4, 0.0 };
    var transform = state.manipulation_origin;
    applyScale(&state, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), transform.scale[0], 0.0001);

    state.manipulation_accumulated_delta = .{ 0.6, 0.0 };
    transform = state.manipulation_origin;
    applyScale(&state, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[2], 0.0001);
}

test "rotation snap uses accumulated drag from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .y;
    state.manipulation_origin.rotation = quat.fromEuler(.{ 0.0, 0.0, 0.0 });
    state.rotation_drag_sensitivity = 1.0;
    state.rotation_snap_enabled = true;
    state.rotation_snap_step_degrees = 45.0;

    state.manipulation_drag_accumulator = .{ 0.5, 0.0 };
    var transform = state.manipulation_origin;
    applyRotate(&state, &transform);
    const euler = quat.toEuler(transform.rotation);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), euler[1], 0.0001);
}

test "translation snap uses accumulated drag from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .x;
    state.transform_space = .world;
    state.manipulation_origin = .{
        .translation = .{ 0.0, 0.0, 0.0 },
    };
    state.translation_drag_sensitivity = 1.0;
    state.translation_snap_enabled = true;
    state.translation_snap_step = 1.0;

    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();
    var renderer: engine.render.Renderer = undefined;
    var input = engine.core.InputState{};
    var playback = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &world,
        .renderer = &renderer,
        .input = &input,
        .window = undefined,
        .playback_controller = &playback,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 1.0 / 60.0,
    };

    // The helper only reads the active camera transform, so no world state is needed here.
    state.manipulation_drag_accumulator = .{ 0.4, 0.0 };
    var transform = state.manipulation_origin;
    applyTranslate(&state, &layer_context, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), transform.translation[0], 0.0001);

    state.manipulation_drag_accumulator = .{ 0.6, 0.0 };
    transform = state.manipulation_origin;
    applyTranslate(&state, &layer_context, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), transform.translation[0], 0.0001);
}
