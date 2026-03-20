const std = @import("std");
const engine = @import("guava");
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const ai_collaboration = @import("../ai_native/collaboration.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const camera = @import("camera.zig");
const history = @import("../actions/history.zig");
const scene_hierarchy = @import("../ui/windows/scene_hierarchy.zig");

const ManipulationMode = state_mod.ManipulationMode;
const TransformSpace = state_mod.TransformSpace;

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;

    if (engine.ui.ImGui.wantsTextInput()) {
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
            try beginManipulation(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.w) and !input.isMouseDown(.right)) {
            try beginManipulation(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.r)) {
            try beginManipulation(state, layer_context, .scale);
        }
        if (input.wasKeyPressed(.e)) {
            try beginManipulation(state, layer_context, .rotate);
        }
        if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
            try beginManipulation(state, layer_context, .scale);
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
        try beginManipulation(state, layer_context, .translate);
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
        try beginManipulation(state, layer_context, .scale);
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
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 }; // 重置累计偏移量
    clearManipulationSnapshot(state);
    try syncManipulationTarget(state, layer_context);
    syncGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
    ai_collaboration.noteManipulationBegin(state);
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
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
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
        }
        return;
    }

    // 2. If the drag started on a UI element, ignore all movement
    if (state.manipulation_started_from_ui) {
        return;
    }

    const entity_id = state.manipulation_entity orelse return;
    const current_transform = currentManipulationTransform(state, layer_context, entity_id) orelse {
        endManipulation(state);
        return;
    };

    // 3. Prevent starting a drag if outside viewport or using alt (camera),
    //    but allow continuing a drag even if mouse leaves viewport
    if (!state.manipulation_drag_active) {
        if (!state.viewport_has_image or !state.viewport_hovered or state.viewport_overlay_hovered or input.modifiers.alt) {
            return;
        }
    }

    // 4. Start or continue drag
    if (input.wasMousePressed(.left) or !state.manipulation_drag_active) {
        state.manipulation_origin = current_transform;
        state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
        state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
        state.manipulation_drag_active = true;
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
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &world,
        .renderer = &renderer,
        .input = &input,
        .window = undefined,
        .frame_index = 0,
        .delta_seconds = 1.0 / 60.0,
        .playback_controller = &playback,
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
