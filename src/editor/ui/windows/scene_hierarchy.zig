const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const state_mod = @import("../../core/state.zig");
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");
const content_browser = @import("../../assets/browser.zig");
const inspector = @import("inspector.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");

const hierarchy_row_icon_size: f32 = 14.0;
const hierarchy_status_icon_size: f32 = 16.0;
const hierarchy_status_button_extent: f32 = 28.0;
const hierarchy_status_column_width: f32 = 34.0;

pub fn drawSceneWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .scene, "scene_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    syncHierarchyRenameState(state, layer_context);

    layout.beginSectionBody();
    var selection_count_buffer: [32]u8 = undefined;
    const selection_count_text = try std.fmt.bufPrint(&selection_count_buffer, "{d}", .{layer_context.renderer.selectedEntities().len});
    engine.ui.ImGui.labelText(state.text(.selection_count), selection_count_text);

    engine.ui.ImGui.dummy(0.0, 4.0);
    const controls_width = engine.ui.ImGui.contentRegionAvail()[0];
    if (controls_width >= 360.0) {
        const root_button_width = std.math.clamp(controls_width * 0.22, 96.0, 124.0);
        const rename_button_width = std.math.clamp(controls_width * 0.18, 84.0, 104.0);
        engine.ui.ImGui.setNextItemWidth(@max(controls_width - root_button_width - rename_button_width - 16.0, 96.0));
        _ = engine.ui.ImGui.inputTextWithHint("##scene_filter", state.text(.scene_filter), state.scene_filter_buffer[0..]);
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.buttonEx(state.text(.scene_root), root_button_width, 0.0) and layer_context.renderer.selectedEntities().len > 0) {
            try unparentSelection(state, layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.buttonEx(state.text(.rename), rename_button_width, 0.0)) {
            try beginSelectedHierarchyRename(state, layer_context);
        }
    } else {
        engine.ui.ImGui.setNextItemWidth(-1.0);
        _ = engine.ui.ImGui.inputTextWithHint("##scene_filter", state.text(.scene_filter), state.scene_filter_buffer[0..]);
        engine.ui.ImGui.dummy(0.0, 6.0);
        if (controls_width >= 184.0) {
            const half_width = @max((controls_width - 8.0) * 0.5, 88.0);
            if (engine.ui.ImGui.buttonEx(state.text(.scene_root), half_width, 0.0) and layer_context.renderer.selectedEntities().len > 0) {
                try unparentSelection(state, layer_context);
            }
            engine.ui.ImGui.sameLine();
            if (engine.ui.ImGui.buttonEx(state.text(.rename), half_width, 0.0)) {
                try beginSelectedHierarchyRename(state, layer_context);
            }
        } else {
            if (engine.ui.ImGui.buttonEx(state.text(.scene_root), controls_width, 0.0) and layer_context.renderer.selectedEntities().len > 0) {
                try unparentSelection(state, layer_context);
            }
            engine.ui.ImGui.dummy(0.0, 6.0);
            if (engine.ui.ImGui.buttonEx(state.text(.rename), controls_width, 0.0)) {
                try beginSelectedHierarchyRename(state, layer_context);
            }
        }
    }
    layout.endSectionBody();
    var dropped_root: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_root)) {
        _ = try handleHierarchyEntityDrop(state, layer_context, dropped_root, null);
    }
    var dropped_model: u64 = 0;
    if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_model_drag_payload, &dropped_model)) {
        const asset_index: usize = @intCast(dropped_model);
        if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .model) {
            try history.importModelPath(state, layer_context, state.asset_entries.items[asset_index].path);
        }
    }
    engine.ui.ImGui.dummy(0.0, 4.0);
    engine.ui.ImGui.separator();
    engine.ui.ImGui.dummy(0.0, 4.0);

    if (!engine.ui.ImGui.beginTable("scene_tree_table", 4)) {
        return;
    }
    engine.ui.ImGui.tableSetupColumn(state.text(.name), true, 1.0);
    engine.ui.ImGui.tableSetupColumn("##scene_visible", false, hierarchy_status_column_width);
    engine.ui.ImGui.tableSetupColumn("##scene_frozen", false, hierarchy_status_column_width);
    engine.ui.ImGui.tableSetupColumn("##scene_locked", false, hierarchy_status_column_width);

    for (layer_context.world.entities.items) |entity| {
        if (entity.editor_only or entity.parent != null) {
            continue;
        }
        if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, entity.id)) {
            continue;
        }
        drawHierarchyNode(state, layer_context, entity.id) catch |err| switch (err) {
            error.HierarchyMutated => return,
            else => return err,
        };
    }
    engine.ui.ImGui.endTable();

    if (try drawSceneWindowContextMenu(state, layer_context)) {
        return;
    }
}

pub fn drawHierarchyNode(state: *EditorState, layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) anyerror!void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;
    if (entity.editor_only) {
        return;
    }

    const is_selected = utils.isEntitySelected(state, layer_context, entity_id);
    const is_frozen = utils.isEntityFrozen(state, entity_id);
    const is_locked = utils.isEntitySelectionLocked(state, entity_id);
    const filter_active = utils.zeroTerminatedSlice(state.scene_filter_buffer[0..]).len != 0 or
        utils.zeroTerminatedSlice(state.hierarchy_filter_buffer[0..]).len != 0 or
        state.hierarchy_category != .all;
    const has_visible_children = utils.hasVisibleSceneTreeChildren(state, layer_context.world, entity_id);
    const leaf = !has_visible_children;
    const rename_active = state.hierarchy_rename_entity != null and state.hierarchy_rename_entity.? == entity_id;
    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.entityIconPath(entity),
        hierarchy_row_icon_size,
        if (is_frozen)
            .{ 122, 132, 145, 255 }
        else if (entity.visible)
            .{ 188, 203, 228, 255 }
        else
            .{ 108, 116, 128, 255 },
    );

    engine.ui.ImGui.tableNextRow();
    engine.ui.ImGui.tableNextColumn();
    const tree_result = engine.ui.ImGui.treeNodeEntity(
        entity_id,
        entity.name,
        icon_texture,
        hierarchy_row_icon_size,
        is_selected,
        leaf,
        filter_active and has_visible_children,
        if (rename_active) state.hierarchy_rename_buffer[0..] else null,
        rename_active and state.hierarchy_rename_focus_pending,
    );
    const is_open = tree_result.open;
    if (rename_active) {
        state.hierarchy_rename_focus_pending = false;
    }

    if (tree_result.clicked and !is_locked and !is_frozen) {
        if (state.hierarchy_rename_entity != null and state.hierarchy_rename_entity.? != entity_id) {
            cancelHierarchyRename(state);
        }
        if (layer_context.input.modifiers.shift or layer_context.input.modifiers.ctrl or layer_context.input.modifiers.super) {
            try layer_context.renderer.toggleSelection(entity_id);
        } else {
            try layer_context.renderer.replaceSelection(entity_id);
        }
        utils.syncInspectorNameBuffer(state, layer_context);
    }

    if (!is_locked and !is_frozen and !rename_active) {
        _ = engine.ui.ImGui.dragDropSourceU64(state_mod.entity_drag_payload, entity_id, entity.name);
        var dropped_child: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_child)) {
            if (try handleHierarchyEntityDrop(state, layer_context, dropped_child, entity_id)) {
                return error.HierarchyMutated;
            }
        }
        var dropped_material: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_material_drag_payload, &dropped_material)) {
            const asset_index: usize = @intCast(dropped_material);
            if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .material) {
                _ = try content_browser.applyMaterialAssetToEntity(state, layer_context, &state.asset_entries.items[asset_index], entity_id);
            }
        }
        var dropped_texture: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &dropped_texture)) {
            const asset_index: usize = @intCast(dropped_texture);
            if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .texture) {
                if (entity.material == null) {
                    try inspector.addMaterialComponent(state, layer_context, entity);
                }
                const entry = state.asset_entries.items[asset_index];
                const texture_handle = try inspector.importTextureAsset(state, layer_context, entry.id, entry.path);
                if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
                    material_resource.base_color_texture = texture_handle;
                    if (entity.material) |*material_component| {
                        material_component.handle = inspector.materialHandleForEntity(state, entity);
                    }
                    try history.captureSnapshot(state, layer_context);
                }
            }
        }
    }

    var popup_id_buffer: [48]u8 = undefined;
    const popup_id = try std.fmt.bufPrint(&popup_id_buffer, "{d}_context", .{entity_id});
    if (engine.ui.ImGui.beginPopupContextItem(popup_id)) {
        defer engine.ui.ImGui.endPopup();
        if (!is_selected and !is_frozen) {
            try layer_context.renderer.replaceSelection(entity_id);
            utils.syncInspectorNameBuffer(state, layer_context);
        }
        if (try drawHierarchyNodeContextMenu(state, layer_context, entity_id, is_selected)) {
            return error.HierarchyMutated;
        }
    }

    engine.ui.ImGui.tableNextColumn();
    var visibility_button_id_buffer: [48]u8 = undefined;
    const visibility_button_id = try std.fmt.bufPrint(&visibility_button_id_buffer, "{d}_visibility", .{entity_id});
    if (try drawHierarchyStatusIconButton(
        state,
        layer_context,
        visibility_button_id,
        if (entity.visible) ui_icons.paths.hierarchy.eye else ui_icons.paths.hierarchy.eye_off,
        hierarchy_status_icon_size,
        if (entity.visible) .{ 176, 203, 224, 255 } else .{ 145, 151, 162, 255 },
        if (entity.visible) ui_icons.palettes.status_on else ui_icons.palettes.status_off,
    )) {
        entity.visible = !entity.visible;
        try history.captureSnapshot(state, layer_context);
    }

    engine.ui.ImGui.tableNextColumn();
    var freeze_button_id_buffer: [40]u8 = undefined;
    const freeze_button_id = try std.fmt.bufPrint(&freeze_button_id_buffer, "{d}_freeze", .{entity_id});
    if (try drawFreezeToggleButton(freeze_button_id, is_frozen)) {
        try setFrozenForEntities(state, layer_context, &.{entity_id}, !is_frozen);
    }

    engine.ui.ImGui.tableNextColumn();
    var lock_button_id_buffer: [40]u8 = undefined;
    const lock_button_id = try std.fmt.bufPrint(&lock_button_id_buffer, "{d}_lock", .{entity_id});
    if (try drawHierarchyStatusIconButton(
        state,
        layer_context,
        lock_button_id,
        if (is_locked) ui_icons.paths.hierarchy.lock else ui_icons.paths.hierarchy.unlock,
        hierarchy_status_icon_size,
        if (is_locked) .{ 170, 203, 188, 255 } else .{ 148, 154, 166, 255 },
        if (is_locked) ui_icons.palettes.status_on else ui_icons.palettes.status_off,
    )) {
        try setLockedForEntities(state, layer_context, &.{entity_id}, !is_locked);
    }

    if (rename_active and tree_result.rename_finished) {
        if (tree_result.rename_committed) {
            try commitHierarchyRename(state, layer_context, entity_id);
        }
        cancelHierarchyRename(state);
    }

    if (has_visible_children and is_open) {
        for (layer_context.world.entities.items) |child| {
            if (child.editor_only or child.parent != entity_id) {
                continue;
            }
            if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, child.id)) {
                continue;
            }
            drawHierarchyNode(state, layer_context, child.id) catch |err| switch (err) {
                error.HierarchyMutated => return error.HierarchyMutated,
                else => return err,
            };
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
    try unparentEntities(state, layer_context, selection);
}

pub fn reparentEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    child_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !void {
    _ = try reparentEntities(state, layer_context, &.{child_id}, parent_id, false);
}

fn handleHierarchyEntityDrop(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    dragged_entity_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !bool {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const selection = layer_context.renderer.selectedEntities();
    const preserve_selection = selection.len > 1 and sliceContainsEntity(selection, dragged_entity_id);

    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectDraggedEntityRoots(
        allocator,
        layer_context.world,
        selection,
        dragged_entity_id,
        state.editor_camera,
        &roots,
    );
    return reparentEntities(state, layer_context, roots.items, parent_id, preserve_selection);
}

fn reparentEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
    preserve_selection: bool,
) !bool {
    if (entity_ids.len == 0) {
        return false;
    }
    if (parent_id) |resolved_parent_id| {
        if (utils.isEntityFrozen(state, resolved_parent_id) or utils.isEntitySelectionLocked(state, resolved_parent_id)) {
            return false;
        }
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    var moved = std.ArrayList(engine.scene.EntityId).empty;
    defer moved.deinit(allocator);

    for (entity_ids) |entity_id| {
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        if (!layer_context.world.hasEntity(entity_id)) {
            continue;
        }
        if (utils.isEntityFrozen(state, entity_id) or utils.isEntitySelectionLocked(state, entity_id)) {
            continue;
        }
        if (wouldCreateHierarchyCycle(layer_context.world, entity_id, parent_id)) {
            continue;
        }

        const changed = layer_context.world.setParent(entity_id, parent_id) catch |err| {
            std.log.warn("failed to reparent entity {d}: {}", .{ entity_id, err });
            continue;
        };
        if (!changed) {
            continue;
        }
        try moved.append(allocator, entity_id);
    }

    if (moved.items.len == 0) {
        return false;
    }

    if (!preserve_selection) {
        try layer_context.renderer.replaceSelection(moved.items[0]);
    }
    utils.syncInspectorNameBuffer(state, layer_context);
    try history.captureSnapshot(state, layer_context);
    return true;
}

fn collectDraggedEntityRoots(
    allocator: std.mem.Allocator,
    world: *const engine.scene.World,
    selection: []const engine.scene.EntityId,
    dragged_entity_id: engine.scene.EntityId,
    editor_camera: ?engine.scene.EntityId,
    out_roots: *std.ArrayList(engine.scene.EntityId),
) !void {
    if (selection.len > 1 and sliceContainsEntity(selection, dragged_entity_id)) {
        try collectSelectionRoots(allocator, world, selection, editor_camera, out_roots);
        return;
    }

    if (editor_camera != null and dragged_entity_id == editor_camera.?) {
        return;
    }
    if (!world.hasEntity(dragged_entity_id)) {
        return;
    }
    try out_roots.append(allocator, dragged_entity_id);
}

fn collectSelectionRoots(
    allocator: std.mem.Allocator,
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
    editor_camera: ?engine.scene.EntityId,
    out_roots: *std.ArrayList(engine.scene.EntityId),
) !void {
    for (entity_ids) |entity_id| {
        if (editor_camera != null and entity_id == editor_camera.?) {
            continue;
        }
        if (!world.hasEntity(entity_id) or selectionContainsAncestor(world, entity_ids, entity_id)) {
            continue;
        }
        try out_roots.append(allocator, entity_id);
    }
}

fn selectionContainsAncestor(
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
    entity_id: engine.scene.EntityId,
) bool {
    var current = world.parentEntity(entity_id);
    while (current) |current_id| {
        if (sliceContainsEntity(entity_ids, current_id)) {
            return true;
        }
        current = world.parentEntity(current_id);
    }
    return false;
}

fn wouldCreateHierarchyCycle(
    world: *const engine.scene.World,
    child_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) bool {
    var current = parent_id;
    while (current) |current_id| {
        if (current_id == child_id) {
            return true;
        }
        current = world.parentEntity(current_id);
    }
    return false;
}

fn sliceContainsEntity(entity_ids: []const engine.scene.EntityId, entity_id: engine.scene.EntityId) bool {
    for (entity_ids) |candidate| {
        if (candidate == entity_id) {
            return true;
        }
    }
    return false;
}

fn beginHierarchyRename(state: *EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) void {
    const entity = world.getEntityConst(entity_id) orelse return;
    @memset(state.hierarchy_rename_buffer[0..], 0);
    const copy_len = @min(entity.name.len, state.hierarchy_rename_buffer.len - 1);
    @memcpy(state.hierarchy_rename_buffer[0..copy_len], entity.name[0..copy_len]);
    state.hierarchy_rename_entity = entity_id;
    state.hierarchy_rename_focus_pending = true;
}

fn beginSelectedHierarchyRename(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (layer_context.renderer.selectedEntities().len != 1) {
        return;
    }
    const selected = layer_context.renderer.selectedEntity() orelse return;
    if (!utils.isEntitySelectionLocked(state, selected) and
        !utils.isEntityFrozen(state, selected) and
        utils.shouldShowEntityInSceneTree(state, layer_context.world, selected))
    {
        beginHierarchyRename(state, layer_context.world, selected);
    }
}

fn cancelHierarchyRename(state: *EditorState) void {
    state.hierarchy_rename_entity = null;
    state.hierarchy_rename_focus_pending = false;
    @memset(state.hierarchy_rename_buffer[0..], 0);
}

fn syncHierarchyRenameState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const rename_entity = state.hierarchy_rename_entity orelse return;
    if (layer_context.renderer.selectedEntities().len != 1 or
        layer_context.renderer.selectedEntity() != rename_entity or
        !layer_context.world.hasEntity(rename_entity) or
        utils.isEntityFrozen(state, rename_entity) or
        utils.isEntitySelectionLocked(state, rename_entity) or
        !utils.shouldShowEntityInSceneTree(state, layer_context.world, rename_entity))
    {
        cancelHierarchyRename(state);
    }
}

fn commitHierarchyRename(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) !void {
    const next_name = utils.zeroTerminatedSlice(state.hierarchy_rename_buffer[0..]);
    if (next_name.len == 0) {
        return;
    }
    if (try layer_context.world.renameEntity(entity_id, next_name)) {
        utils.syncInspectorNameBuffer(state, layer_context);
        try history.captureSnapshot(state, layer_context);
        try history.refreshWindowTitle(state, layer_context);
    }
}

fn drawSceneWindowContextMenu(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (!engine.ui.ImGui.beginPopupContextWindow("scene_tree_window_context", false)) {
        return false;
    }
    defer engine.ui.ImGui.endPopup();

    if (engine.ui.ImGui.beginMenu(state.text(.create))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.folder), null, false, true)) {
            try createFolderEntity(state, layer_context);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.empty), null, false, true)) {
            try history.spawnEmptyEntity(state, layer_context);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.camera), null, false, true)) {
            try history.spawnCameraEntity(state, layer_context);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.cube), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .cube);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.sphere), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .sphere);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.plane), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .plane);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.point_light), null, false, true)) {
            try history.spawnPointLight(state, layer_context);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.vfx_fountain), null, false, true)) {
            try history.spawnVfxEntity(state, layer_context, .fountain);
            return true;
        }
        if (engine.ui.ImGui.menuItem(state.text(.vfx_orbit), null, false, true)) {
            try history.spawnVfxEntity(state, layer_context, .orbit);
            return true;
        }
    }
    return false;
}

fn drawHierarchyNodeContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    is_selected: bool,
) !bool {
    const single_target = [_]engine.scene.EntityId{entity_id};
    const targets = if (is_selected and layer_context.renderer.selectedEntities().len > 1)
        layer_context.renderer.selectedEntities()
    else
        single_target[0..];
    const can_rename = targets.len == 1 and !utils.isEntityFrozen(state, entity_id) and !utils.isEntitySelectionLocked(state, entity_id);
    const all_frozen = allEntitiesFrozen(state, targets);
    const all_locked = allEntitiesLocked(state, targets);
    const has_parent = anyEntityHasParent(layer_context.world, targets);

    if (engine.ui.ImGui.menuItem(state.text(.rename), null, false, can_rename)) {
        beginHierarchyRename(state, layer_context.world, entity_id);
        return false;
    }
    if (engine.ui.ImGui.menuItem(state.text(.duplicate), null, false, true)) {
        try history.duplicateEntities(state, layer_context, targets);
        return true;
    } else if (engine.ui.ImGui.menuItem(state.text(.delete), null, false, true)) {
        try history.deleteEntities(state, layer_context, targets);
        return true;
    }
    engine.ui.ImGui.separator();
    if (engine.ui.ImGui.menuItem(state.text(if (all_frozen) .unfreeze else .freeze), null, false, true)) {
        try setFrozenForEntities(state, layer_context, targets, !all_frozen);
        return false;
    }
    if (engine.ui.ImGui.menuItem(state.text(if (all_locked) .unlock else .lock), null, false, true)) {
        try setLockedForEntities(state, layer_context, targets, !all_locked);
        return false;
    }
    if (engine.ui.ImGui.menuItem(state.text(.unparent), null, false, has_parent)) {
        try unparentEntities(state, layer_context, targets);
        return true;
    }
    return false;
}

fn unparentEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    if (entity_ids.len == 0) {
        return;
    }

    var changed = false;
    for (entity_ids) |entity_id| {
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        changed = (try layer_context.world.setParent(entity_id, null)) or changed;
    }

    if (changed) {
        try history.captureSnapshot(state, layer_context);
    }
}

fn setFrozenForEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    frozen: bool,
) !void {
    var changed = false;
    for (entity_ids) |entity_id| {
        changed = (try utils.setEntityFrozen(state, entity_id, frozen)) or changed;
    }
    if (!changed) {
        return;
    }
    if (frozen) {
        try utils.pruneFrozenSelection(state, layer_context);
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}

fn setLockedForEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    locked: bool,
) !void {
    var changed = false;
    for (entity_ids) |entity_id| {
        changed = (try utils.setEntitySelectionLocked(state, entity_id, locked)) or changed;
    }
    if (!changed) {
        return;
    }
    if (locked) {
        try utils.pruneLockedSelection(state, layer_context);
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}

fn allEntitiesFrozen(state: *const EditorState, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (!utils.isEntityFrozen(state, entity_id)) {
            return false;
        }
    }
    return entity_ids.len > 0;
}

fn allEntitiesLocked(state: *const EditorState, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (!utils.isEntitySelectionLocked(state, entity_id)) {
            return false;
        }
    }
    return entity_ids.len > 0;
}

fn anyEntityHasParent(world: *const engine.scene.World, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (world.parentEntity(entity_id) != null) {
            return true;
        }
    }
    return false;
}

fn drawFreezeToggleButton(id: []const u8, active: bool) !bool {
    engine.ui.ImGui.pushStyleColor(.text, if (active) .{ 0.74, 0.92, 0.98, 1.0 } else .{ 0.55, 0.58, 0.62, 1.0 });
    engine.ui.ImGui.pushStyleColor(.button, if (active) .{ 0.19, 0.29, 0.34, 0.82 } else .{ 0.16, 0.17, 0.19, 0.54 });
    engine.ui.ImGui.pushStyleColor(.button_hovered, if (active) .{ 0.24, 0.36, 0.42, 0.92 } else .{ 0.21, 0.23, 0.27, 0.74 });
    engine.ui.ImGui.pushStyleColor(.button_active, if (active) .{ 0.18, 0.26, 0.31, 0.96 } else .{ 0.18, 0.20, 0.24, 0.86 });
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, .{ 0.0, 0.0 });
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, ui_icons.regular_icon_button_rounding);
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(4);
    }
    var label_buffer: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buffer, "F##{s}", .{id});
    return engine.ui.ImGui.buttonEx(label, hierarchy_status_button_extent, hierarchy_status_button_extent);
}

fn drawHierarchyStatusIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    size: f32,
    tint: [4]u8,
    palette: ui_icons.ButtonPalette,
) !bool {
    const texture = try ui_icons.ensureTintedIconTexture(state, layer_context, path, size, tint);
    engine.ui.ImGui.pushStyleColor(.button, palette.button);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette.hovered);
    engine.ui.ImGui.pushStyleColor(.button_active, palette.active);
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, ui_icons.regular_icon_button_padding);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, ui_icons.regular_icon_button_rounding);
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.imageButton(id, texture, size, size, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}

fn createFolderEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const transform = history.spawnTransform(state, layer_context);
    const entity_id = try layer_context.world.createFolderEntity(transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try history.captureSnapshot(state, layer_context);
}

test "collectDraggedEntityRoots keeps only selection roots during multi-drag" {
    var world = engine.scene.World.init(std.testing.allocator);
    defer world.deinit();

    const root = try world.createEntity(.{ .name = "Root" });
    const child = try world.createEntity(.{ .name = "Child", .parent = root });
    const sibling = try world.createEntity(.{ .name = "Sibling" });

    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(std.testing.allocator);

    try collectDraggedEntityRoots(std.testing.allocator, &world, &.{ child, root, sibling }, child, null, &roots);
    try std.testing.expectEqualSlices(engine.scene.EntityId, &.{ root, sibling }, roots.items);
}

test "wouldCreateHierarchyCycle rejects descendant drop targets" {
    var world = engine.scene.World.init(std.testing.allocator);
    defer world.deinit();

    const root = try world.createEntity(.{ .name = "Root" });
    const child = try world.createEntity(.{ .name = "Child", .parent = root });
    const grandchild = try world.createEntity(.{ .name = "GrandChild", .parent = child });
    const sibling = try world.createEntity(.{ .name = "Sibling" });

    try std.testing.expect(wouldCreateHierarchyCycle(&world, root, grandchild));
    try std.testing.expect(wouldCreateHierarchyCycle(&world, child, grandchild));
    try std.testing.expect(!wouldCreateHierarchyCycle(&world, grandchild, root));
    try std.testing.expect(!wouldCreateHierarchyCycle(&world, sibling, grandchild));
}
