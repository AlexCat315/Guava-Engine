const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const state_mod = @import("../../core/state.zig");
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");

pub fn drawSceneWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .scene, "scene_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    _ = engine.ui.ImGui.inputText(state.text(.scene_filter), state.scene_filter_buffer[0..]);
    if (engine.ui.ImGui.button(state.text(.scene_root)) and layer_context.renderer.selectedEntities().len > 0) {
        try unparentSelection(state, layer_context);
    }
    var dropped_root: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_root)) {
        try reparentEntity(state, layer_context, dropped_root, null);
    }
    engine.ui.ImGui.separator();

    for (layer_context.world.entities.items) |entity| {
        if (entity.editor_only or entity.parent != null) {
            continue;
        }
        if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, entity.id)) {
            continue;
        }
        try drawHierarchyNode(state, layer_context, entity.id);
    }
}

pub fn drawHierarchyNode(state: *EditorState, layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) !void {
    const entity = layer_context.world.getEntityConst(entity_id) orelse return;
    if (entity.editor_only) {
        return;
    }

    const is_selected = utils.isEntitySelected(state, layer_context, entity_id);
    const leaf = !utils.hasVisibleChildren(state, layer_context.world, entity_id);
    const is_open = engine.ui.ImGui.treeNodeEntity(entity_id, entity.name, is_selected, leaf, false);

    if (engine.ui.ImGui.isItemClicked()) {
        if (layer_context.input.modifiers.shift or layer_context.input.modifiers.ctrl or layer_context.input.modifiers.super) {
            try layer_context.renderer.toggleSelection(entity_id);
        } else {
            try layer_context.renderer.replaceSelection(entity_id);
        }
        utils.syncInspectorNameBuffer(state, layer_context);
    }

    _ = engine.ui.ImGui.dragDropSourceU64(state_mod.entity_drag_payload, entity_id, entity.name);
    var dropped_child: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_child)) {
        try reparentEntity(state, layer_context, dropped_child, entity_id);
    }

    if (!leaf and is_open) {
        for (layer_context.world.entities.items) |child| {
            if (child.editor_only or child.parent != entity_id) {
                continue;
            }
            if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, child.id)) {
                continue;
            }
            try drawHierarchyNode(state, layer_context, child.id);
        }
        engine.ui.ImGui.treePop();
    }
}

pub fn parentSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection = layer_context.renderer.selectedEntities();
    if (selection.len < 2) {
        return;
    }

    const parent_id = layer_context.renderer.selectedEntity() orelse return;
    if (state.editor_camera != null and parent_id == state.editor_camera.?) {
        return;
    }

    var changed = false;
    for (selection) |entity_id| {
        if (entity_id == parent_id) {
            continue;
        }
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        changed = (try layer_context.world.setParent(entity_id, parent_id)) or changed;
    }

    if (changed) {
        try history.captureSnapshot(state, layer_context);
    }
}

pub fn unparentSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection = layer_context.renderer.selectedEntities();
    if (selection.len == 0) {
        return;
    }

    var changed = false;
    for (selection) |entity_id| {
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        changed = (try layer_context.world.setParent(entity_id, null)) or changed;
    }

    if (changed) {
        try history.captureSnapshot(state, layer_context);
    }
}

pub fn reparentEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    child_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !void {
    if (state.editor_camera != null and child_id == state.editor_camera.?) {
        return;
    }

    const changed = layer_context.world.setParent(child_id, parent_id) catch |err| {
        std.log.warn("failed to reparent entity {d}: {}", .{ child_id, err });
        return;
    };
    if (!changed) {
        return;
    }

    try layer_context.renderer.replaceSelection(child_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try history.captureSnapshot(state, layer_context);
}
