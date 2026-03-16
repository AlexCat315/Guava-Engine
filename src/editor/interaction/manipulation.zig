const engine = @import("guava");
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const camera = @import("camera.zig");
const history = @import("../actions/history.zig");
const scene_hierarchy = @import("../ui/windows/scene_hierarchy.zig");

const ManipulationMode = state_mod.ManipulationMode;

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;

    if (engine.ui.ImGui.wantsCaptureKeyboard()) {
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
            endManipulation(state);
            try history.captureSnapshot(state, layer_context);
        }
        if (input.wasKeyPressed(.escape)) {
            cancelManipulation(state, layer_context);
        }
        if (input.wasKeyPressed(.g)) {
            try beginManipulation(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.r)) {
            try beginManipulation(state, layer_context, .rotate);
        }
        if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
            try beginManipulation(state, layer_context, .scale);
        }
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
    if (input.wasKeyPressed(.r)) {
        try beginManipulation(state, layer_context, .rotate);
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
    const selected = layer_context.renderer.selectedEntity() orelse return;
    if (state.editor_camera != null and selected == state.editor_camera.?) {
        return;
    }

    state.manipulation_mode = mode;
    state.manipulation_axis = .free;
    state.manipulation_entity = selected;
    state.manipulation_origin = layer_context.world.worldTransform(selected) orelse return;
    syncGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
}

pub fn endManipulation(state: *EditorState) void {
    state.manipulation_mode = .none;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
}

pub fn cancelManipulation(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const entity_id = state.manipulation_entity orelse {
        endManipulation(state);
        return;
    };
    _ = layer_context.world.setEntityWorldTransform(entity_id, state.manipulation_origin);
    endManipulation(state);
    syncGizmoState(state, layer_context);
}

pub fn applyManipulation(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const entity_id = state.manipulation_entity orelse return;
    var entity_transform = layer_context.world.worldTransform(entity_id) orelse {
        endManipulation(state);
        return;
    };
    const input = layer_context.input;
    if (@abs(input.mouse_delta[0]) < 0.0001 and @abs(input.mouse_delta[1]) < 0.0001) {
        return;
    }

    switch (state.manipulation_mode) {
        .none => {},
        .translate => applyTranslate(state, layer_context, &entity_transform),
        .rotate => applyRotate(state, input, &entity_transform),
        .scale => applyScale(state, input, &entity_transform),
    }

    _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform);
}

pub fn applyTranslate(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    entity_transform: *engine.scene.Transform,
) void {
    const input = layer_context.input;
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const right = vec3.rightFromYaw(camera_transform.rotation_euler[1]);
    const forward = vec3.forwardFromAngles(camera_transform.rotation_euler[1], camera_transform.rotation_euler[0]);
    const up = vec3.normalize(vec3.cross(right, forward));
    const distance = @max(vec3.length(vec3.sub(camera_transform.translation, entity_transform.translation)), 1.0);
    const move_scale = distance * 0.0025;

    switch (state.manipulation_axis) {
        .free => {
            const delta = vec3.add(
                vec3.scale(right, input.mouse_delta[0] * move_scale),
                vec3.scale(up, -input.mouse_delta[1] * move_scale),
            );
            entity_transform.translation = vec3.add(entity_transform.translation, delta);
        },
        .x, .y, .z => {
            const axis = engine.math.axis.vector(state.manipulation_axis);
            const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * move_scale;
            entity_transform.translation = vec3.add(entity_transform.translation, vec3.scale(axis, scalar));
        },
    }
}

pub fn applyRotate(state: *const EditorState, input: *const engine.core.InputState, entity_transform: *engine.scene.Transform) void {
    const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
    switch (state.manipulation_axis) {
        .free => {
            entity_transform.rotation_euler[1] -= input.mouse_delta[0] * 0.01;
            entity_transform.rotation_euler[0] -= input.mouse_delta[1] * 0.01;
        },
        .x => entity_transform.rotation_euler[0] += scalar,
        .y => entity_transform.rotation_euler[1] += scalar,
        .z => entity_transform.rotation_euler[2] += scalar,
    }
}

pub fn applyScale(state: *const EditorState, input: *const engine.core.InputState, entity_transform: *engine.scene.Transform) void {
    const scalar = 1.0 + (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
    switch (state.manipulation_axis) {
        .free => {
            entity_transform.scale = .{
                utils.clampScale(entity_transform.scale[0] * scalar),
                utils.clampScale(entity_transform.scale[1] * scalar),
                utils.clampScale(entity_transform.scale[2] * scalar),
            };
        },
        .x => entity_transform.scale[0] = utils.clampScale(entity_transform.scale[0] * scalar),
        .y => entity_transform.scale[1] = utils.clampScale(entity_transform.scale[1] * scalar),
        .z => entity_transform.scale[2] = utils.clampScale(entity_transform.scale[2] * scalar),
    }
}

pub fn syncGizmoState(state: *const EditorState, layer_context: *engine.core.LayerContext) void {
    layer_context.renderer.setEditorGizmoState(.{
        .mode = switch (state.manipulation_mode) {
            .none => .idle,
            .translate => .translate,
            .rotate => .rotate,
            .scale => .scale,
        },
        .axis = state.manipulation_axis,
    });
}
