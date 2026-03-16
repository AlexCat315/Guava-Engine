const std = @import("std");
const engine = @import("guava");
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const content_browser = @import("../assets/browser.zig");
const autosave_path = state_mod.autosave_path;

pub fn captureSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    const snapshot = try engine.scene.serializeWorldAlloc(allocator, layer_context.world);
    errdefer allocator.free(snapshot);

    if (state.snapshot_history.items.len > 0) {
        const current = state.snapshot_history.items[state.snapshot_cursor];
        if (std.mem.eql(u8, current, snapshot)) {
            allocator.free(snapshot);
            return;
        }
    }

    while (state.snapshot_history.items.len > state.snapshot_cursor + 1) {
        const removed = state.snapshot_history.pop().?;
        allocator.free(removed);
        if (state.saved_snapshot_cursor) |saved_snapshot_cursor| {
            if (saved_snapshot_cursor >= state.snapshot_history.items.len) {
                state.saved_snapshot_cursor = null;
            }
        }
    }

    try state.snapshot_history.append(allocator, snapshot);
    state.snapshot_cursor = state.snapshot_history.items.len - 1;

    while (state.snapshot_history.items.len > state.max_snapshots) {
        const removed = state.snapshot_history.orderedRemove(0);
        allocator.free(removed);
        if (state.saved_snapshot_cursor) |saved_snapshot_cursor| {
            state.saved_snapshot_cursor = if (saved_snapshot_cursor == 0) null else saved_snapshot_cursor - 1;
        }
        if (state.snapshot_cursor > 0) {
            state.snapshot_cursor -= 1;
        }
    }
}

pub fn resetSnapshotHistory(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    clearSnapshotHistory(state);
    try captureSnapshot(state, layer_context);
    state.saved_snapshot_cursor = if (state.snapshot_history.items.len > 0) state.snapshot_cursor else null;
}

pub fn clearSnapshotHistory(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.snapshot_history.items) |snapshot| {
        allocator.free(snapshot);
    }
    state.snapshot_history.deinit(allocator);
    state.snapshot_history = .empty;
    state.snapshot_cursor = 0;
    state.saved_snapshot_cursor = null;
}

pub fn undo(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.snapshot_history.items.len == 0 or state.snapshot_cursor == 0) {
        return;
    }
    state.snapshot_cursor -= 1;
    try restoreSnapshot(state, layer_context, state.snapshot_cursor);
}

pub fn redo(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.snapshot_history.items.len == 0 or state.snapshot_cursor + 1 >= state.snapshot_history.items.len) {
        return;
    }
    state.snapshot_cursor += 1;
    try restoreSnapshot(state, layer_context, state.snapshot_cursor);
}

pub fn restoreSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext, index: usize) !void {
    if (index >= state.snapshot_history.items.len) {
        return;
    }

    manipulation.endManipulation(state);
    const snapshot = state.snapshot_history.items[index];
    try engine.scene.deserializeWorldFromSlice(layer_context.world.allocator, layer_context.world, snapshot);
    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try layer_context.renderer.replaceSelection(null);
    utils.syncInspectorNameBuffer(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

pub fn pruneMissingSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    if (layer_context.renderer.selectedEntity()) |selected| {
        if (!layer_context.world.hasEntity(selected)) {
            try layer_context.renderer.replaceSelection(null);
        }
    }
}

pub fn deleteSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try deleteEntities(state, layer_context, layer_context.renderer.selectedEntities());
}

pub fn deleteEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    const allocator = state.allocator orelse return;
    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectSelectionRoots(allocator, layer_context.world, entity_ids, state.editor_camera, &roots);
    if (roots.items.len == 0) {
        return;
    }

    manipulation.endManipulation(state);
    var changed = false;
    for (roots.items) |entity_id| {
        changed = layer_context.world.destroyEntity(entity_id) or changed;
    }
    if (changed) {
        try layer_context.renderer.replaceSelection(null);
        try captureSnapshot(state, layer_context);
    }
}

pub fn duplicateSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try duplicateEntities(state, layer_context, layer_context.renderer.selectedEntities());
}

pub fn duplicateEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    const allocator = state.allocator orelse return;
    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectSelectionRoots(allocator, layer_context.world, entity_ids, state.editor_camera, &roots);
    if (roots.items.len == 0) {
        return;
    }

    var duplicates = std.ArrayList(engine.scene.EntityId).empty;
    defer duplicates.deinit(allocator);

    for (roots.items, 0..) |entity_id, index| {
        const duplicate_id = try layer_context.world.duplicateEntity(entity_id);
        if (layer_context.world.worldTransform(duplicate_id)) |duplicate_transform| {
            var moved = duplicate_transform;
            const stack_offset = @as(f32, @floatFromInt(index)) * 0.2;
            moved.translation[0] += 0.65 + stack_offset;
            moved.translation[1] += 0.15;
            _ = layer_context.world.setEntityWorldTransform(duplicate_id, moved);
        }
        try duplicates.append(allocator, duplicate_id);
    }

    try layer_context.renderer.replaceSelectionMany(duplicates.items);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnEmptyEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entity_id = try layer_context.world.createEmptyEntity(spawnTransform(state, layer_context));
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnCameraEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entity_id = try layer_context.world.createCameraEntity(camera.activeCameraTransform(state, layer_context));
    try layer_context.renderer.replaceSelection(entity_id);
    state.scene_camera = entity_id;
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnPrimitive(state: *EditorState, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive) !void {
    const spawn_transform = spawnTransform(state, layer_context);
    const entity_id = try layer_context.world.createPrimitiveEntity(primitive, spawn_transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnPointLight(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var transform = spawnTransform(state, layer_context);
    transform.translation[1] += 1.0;
    const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnEmptyEntityAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createEmptyEntity(transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnCameraEntityAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createCameraEntity(transform);
    try layer_context.renderer.replaceSelection(entity_id);
    state.scene_camera = entity_id;
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnPrimitiveAt(state: *EditorState, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createPrimitiveEntity(primitive, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnPointLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnSpotLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createLightEntity(.spot, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnDirectionalLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const entity_id = try layer_context.world.createLightEntity(.directional, transform, 1.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try captureSnapshot(state, layer_context);
}

pub fn spawnTransform(state: *EditorState, layer_context: *engine.core.LayerContext) engine.scene.Transform {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const forward = vec3.forwardFromAngles(camera_transform.rotation_euler[1], camera_transform.rotation_euler[0]);
    const spawn_position = vec3.add(camera_transform.translation, vec3.scale(forward, 3.0));

    return .{
        .translation = spawn_position,
    };
}

pub fn saveScene(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    saveScenePath(state, layer_context, autosave_path);
}

pub fn saveScenePath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) void {
    engine.scene.saveWorldToPath(layer_context.world.allocator, layer_context.world, path) catch |err| {
        std.log.err("failed to save scene to {s}: {}", .{ path, err });
        return;
    };
    state.saved_snapshot_cursor = if (state.snapshot_history.items.len > 0) state.snapshot_cursor else null;
    content_browser.refreshAssetBrowser(state, layer_context) catch |err| {
        std.log.warn("failed to refresh asset browser after save: {}", .{err});
    };
}

pub fn loadScene(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try loadScenePath(state, layer_context, autosave_path);
}

pub fn newScene(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    manipulation.endManipulation(state);
    layer_context.world.clear();
    try layer_context.renderer.resetSceneState();
    state.scene_camera = null;
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try layer_context.renderer.replaceSelection(null);
    utils.syncInspectorNameBuffer(state, layer_context);
    try resetSnapshotHistory(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

pub fn loadScenePath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) !void {
    manipulation.endManipulation(state);
    engine.scene.loadWorldFromPath(layer_context.world.allocator, layer_context.world, path) catch |err| {
        std.log.err("failed to load scene from {s}: {}", .{ path, err });
        return;
    };

    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try layer_context.renderer.replaceSelection(null);
    utils.syncInspectorNameBuffer(state, layer_context);
    try resetSnapshotHistory(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

pub fn importModelPath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) !void {
    try importModelPathAt(state, layer_context, path, spawnTransform(state, layer_context));
}

pub fn importModelPathAt(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8, transform: engine.scene.Transform) !void {
    const report = if (state.asset_registry) |*registry|
        if (registry.recordByPath(path)) |record|
            try engine.assets.importGltfStaticModelAssetInstance(
                layer_context.world,
                registry,
                record.id,
                transform,
            )
        else
            try layer_context.world.importGltfStaticModelInstance(path, transform)
    else
        try layer_context.world.importGltfStaticModelInstance(path, transform);
    if (report.root_entity) |root_entity| {
        try layer_context.renderer.replaceSelection(root_entity);
        utils.syncInspectorNameBuffer(state, layer_context);
        camera.focusSelection(state, layer_context);
    }
    try captureSnapshot(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

pub fn refreshWindowTitle(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    _ = layer_context;
}

pub fn hasUnsavedChanges(state: *const EditorState) bool {
    if (state.snapshot_history.items.len == 0) {
        return false;
    }
    const saved_snapshot_cursor = state.saved_snapshot_cursor orelse return true;
    return saved_snapshot_cursor != state.snapshot_cursor;
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
        for (entity_ids) |candidate| {
            if (candidate == current_id) {
                return true;
            }
        }
        current = world.parentEntity(current_id);
    }
    return false;
}
