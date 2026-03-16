const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const state_mod = @import("../../core/state.zig");
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");
const ui_icons = @import("../icons.zig");

pub fn drawSceneWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .scene, "scene_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    var selection_count_buffer: [32]u8 = undefined;
    const selection_count_text = try std.fmt.bufPrint(&selection_count_buffer, "{d}", .{layer_context.renderer.selectedEntities().len});
    engine.ui.ImGui.labelText(state.text(.selection_count), selection_count_text);

    const controls_width = engine.ui.ImGui.contentRegionAvail()[0];
    const root_button_width = 112.0;
    engine.ui.ImGui.setNextItemWidth(@max(controls_width - root_button_width - 8.0, 96.0));
    _ = engine.ui.ImGui.inputText(state.text(.scene_filter), state.scene_filter_buffer[0..]);
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.scene_root), root_button_width, 0.0) and layer_context.renderer.selectedEntities().len > 0) {
        try unparentSelection(state, layer_context);
    }
    var dropped_root: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_root)) {
        try reparentEntity(state, layer_context, dropped_root, null);
    }
    engine.ui.ImGui.separator();

    if (!engine.ui.ImGui.beginTable("scene_tree_table", 3)) {
        return;
    }
    defer engine.ui.ImGui.endTable();
    engine.ui.ImGui.tableSetupColumn(state.text(.name), true, 1.0);
    engine.ui.ImGui.tableSetupColumn("##scene_visible", false, 32.0);
    engine.ui.ImGui.tableSetupColumn("##scene_locked", false, 32.0);

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
    const entity = layer_context.world.getEntity(entity_id) orelse return;
    if (entity.editor_only) {
        return;
    }

    const is_selected = utils.isEntitySelected(state, layer_context, entity_id);
    const is_locked = utils.isEntitySelectionLocked(state, entity_id);
    const leaf = !utils.hasVisibleChildren(state, layer_context.world, entity_id);
    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.entityIconPath(entity),
        14.0,
        if (entity.visible) .{ 188, 203, 228, 255 } else .{ 108, 116, 128, 255 },
    );

    engine.ui.ImGui.tableNextRow();
    engine.ui.ImGui.tableNextColumn();
    const is_open = engine.ui.ImGui.treeNodeEntity(entity_id, entity.name, icon_texture, 14.0, is_selected, leaf, false);

    if (engine.ui.ImGui.isItemClicked() and !is_locked) {
        if (layer_context.input.modifiers.shift or layer_context.input.modifiers.ctrl or layer_context.input.modifiers.super) {
            try layer_context.renderer.toggleSelection(entity_id);
        } else {
            try layer_context.renderer.replaceSelection(entity_id);
        }
        utils.syncInspectorNameBuffer(state, layer_context);
    }

    if (!is_locked) {
        _ = engine.ui.ImGui.dragDropSourceU64(state_mod.entity_drag_payload, entity_id, entity.name);
        var dropped_child: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_child)) {
            try reparentEntity(state, layer_context, dropped_child, entity_id);
        }
    }

    engine.ui.ImGui.tableNextColumn();
    var visibility_button_id_buffer: [48]u8 = undefined;
    const visibility_button_id = try std.fmt.bufPrint(&visibility_button_id_buffer, "{d}_visibility", .{entity_id});
    if (try ui_icons.drawIconButton(
        state,
        layer_context,
        visibility_button_id,
        if (entity.visible) ui_icons.paths.hierarchy.eye else ui_icons.paths.hierarchy.eye_off,
        18.0,
        if (entity.visible) .{ 208, 240, 224, 255 } else .{ 164, 171, 183, 255 },
        if (entity.visible) ui_icons.palettes.status_on else ui_icons.palettes.status_off,
    )) {
        entity.visible = !entity.visible;
        try history.captureSnapshot(state, layer_context);
    }

    engine.ui.ImGui.tableNextColumn();
    var lock_button_id_buffer: [40]u8 = undefined;
    const lock_button_id = try std.fmt.bufPrint(&lock_button_id_buffer, "{d}_lock", .{entity_id});
    if (try ui_icons.drawIconButton(
        state,
        layer_context,
        lock_button_id,
        if (is_locked) ui_icons.paths.hierarchy.lock else ui_icons.paths.hierarchy.unlock,
        18.0,
        if (is_locked) .{ 255, 220, 144, 255 } else .{ 169, 176, 189, 255 },
        if (is_locked) ui_icons.palettes.toolbar_active else ui_icons.palettes.status_off,
    )) {
        const locked_now = try utils.toggleEntitySelectionLocked(state, entity_id);
        if (locked_now and is_selected) {
            try utils.pruneLockedSelection(state, layer_context);
            utils.syncInspectorNameBuffer(state, layer_context);
        }
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
