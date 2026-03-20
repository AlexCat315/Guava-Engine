const std = @import("std");
const engine = @import("guava");
const camera = @import("../interaction/camera.zig");
const state_mod = @import("../core/state.zig");

const collaboration_mod = engine.mcp.collaboration;
const EditorState = state_mod.EditorState;

pub fn beginFrame(state: *EditorState) void {
    state.active_drag_payload = null;
}

pub fn syncContext(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const store = state.ai_collaboration orelse return;
    const viewport_size = layer_context.renderer.sceneViewportSize();
    const center_ray = if (viewport_size[0] > 0 and viewport_size[1] > 0)
        camera.activeCameraRayFromViewportPixel(
            state,
            layer_context,
            .{ viewport_size[0] / 2, viewport_size[1] / 2 },
            viewport_size,
        )
    else
        null;

    try store.updateContext(.{
        .primary_selection = layer_context.renderer.selectedEntity(),
        .selected_entities = layer_context.renderer.selectedEntities(),
        .manipulation_mode = mapManipulationMode(state.manipulation_mode),
        .manipulation_entity = state.manipulation_entity,
        .transform_space = mapTransformSpace(state.transform_space),
        .viewport_size = viewport_size,
        .viewport_hovered = state.viewport_hovered,
        .viewport_focused = state.viewport_focused,
        .camera_transform = camera.activeCameraTransform(state, layer_context),
        .camera_projection = snapshotCameraProjection(camera.activeCameraComponent(state, layer_context)),
        .viewport_center_ray = center_ray,
        .drag_payload = buildDragPayload(state, layer_context),
        .selected_asset = buildSelectedAsset(state),
        .pending_viewport_drop = buildPendingViewportDrop(state),
    });
}

pub fn noteManipulationBegin(state: *EditorState) void {
    noteManipulationEvent(state, "manipulation_begin");
}

pub fn noteManipulationCommit(state: *EditorState, entity_id: engine.scene.EntityId) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={d} mode={s}",
        .{ entity_id, @tagName(mapManipulationMode(state.manipulation_mode)) },
    ) catch "manipulation commit";
    store.recordIntent(.human, "manipulation_commit", detail) catch |err| {
        std.log.warn("failed to record manipulation commit: {s}", .{@errorName(err)});
    };
}

pub fn noteManipulationCancel(state: *EditorState, entity_id: ?engine.scene.EntityId) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={any} mode={s}",
        .{ entity_id, @tagName(mapManipulationMode(state.manipulation_mode)) },
    ) catch "manipulation cancel";
    store.recordIntent(.human, "manipulation_cancel", detail) catch |err| {
        std.log.warn("failed to record manipulation cancel: {s}", .{@errorName(err)});
    };
}

pub fn drawViewportCollaborationOverlay(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const store = state.ai_collaboration orelse return;
    const snapshot = store.overlaySnapshot();
    if (!snapshot.active) {
        return;
    }

    drawPreviewPins(state, layer_context, snapshot);
    try drawPreviewCard(state, layer_context, store, snapshot);
}

fn drawPreviewCard(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    store: *collaboration_mod.Store,
    snapshot: collaboration_mod.OverlaySnapshot,
) !void {
    const card_pos = .{ state.viewport_origin[0] + 18.0, state.viewport_origin[1] + 18.0 };
    engine.ui.ImGui.setNextWindowPos(card_pos);
    engine.ui.ImGui.setNextWindowBgAlpha(0.92);
    _ = engine.ui.ImGui.beginWindowFlags(
        "AI Collaboration Overlay##ai_native_preview",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_saved_settings |
            engine.ui.ImGui.WindowFlags.no_move |
            engine.ui.ImGui.WindowFlags.always_auto_resize,
    );
    defer engine.ui.ImGui.endWindow();

    if (engine.ui.ImGui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
    }

    var header_buffer: [160]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "Ghost Preview  #{d}  [{s}]",
        .{ snapshot.transaction_id, @tagName(snapshot.source) },
    ) catch "Ghost Preview";
    engine.ui.ImGui.text(header);

    if (snapshot.label.len > 0) {
        engine.ui.ImGui.text(snapshot.label.slice());
    }
    if (snapshot.note.len > 0) {
        engine.ui.ImGui.textWrapped(snapshot.note.slice());
    }

    engine.ui.ImGui.separator();

    var summary_buffer: [192]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &summary_buffer,
        "commands: {d}   preview: {d}   errors: {d}",
        .{ snapshot.command_count, snapshot.preview_count, snapshot.error_count },
    ) catch "preview summary";
    engine.ui.ImGui.text(summary);

    if (engine.ui.ImGui.buttonEx("Apply Preview##ai_stage_apply", 136.0, 0.0)) {
        _ = try store.applyStagedTransaction(layer_context.world, .human);
        state.viewport_overlay_hovered = true;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx("Discard##ai_stage_discard", 112.0, 0.0)) {
        _ = store.discardStagedTransaction(.human);
        state.viewport_overlay_hovered = true;
    }
}

fn drawPreviewPins(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    snapshot: collaboration_mod.OverlaySnapshot,
) void {
    const draw_list = engine.ui.ImGui.getWindowDrawList();
    const label_limit = @min(snapshot.visible_entry_count, 12);

    for (0..snapshot.visible_entry_count) |index| {
        const entry = snapshot.entries[index];
        if (!entry.has_world_position) {
            continue;
        }
        const screen_pos = worldPointToViewportScreen(state, layer_context, entry.world_position) orelse continue;
        const color = previewColor(entry.action, entry.visible);
        draw_list.addCircleFilled(screen_pos, 5.5, color, 12);

        if (index >= label_limit) {
            continue;
        }
        const label_pos = .{ screen_pos[0] + 10.0, screen_pos[1] - 10.0 };
        draw_list.addRectFilled(
            .{ label_pos[0] - 4.0, label_pos[1] - 2.0 },
            .{ label_pos[0] + 12.0 + @as(f32, @floatFromInt(entry.name.len)) * 6.0, label_pos[1] + 16.0 },
            engine.ui.ImGui.getColorU32(.{ 0.05, 0.08, 0.07, 0.78 }),
            4.0,
            0,
        );
        draw_list.addText(label_pos, color, entry.name.slice());
    }
}

fn noteManipulationEvent(state: *EditorState, action: []const u8) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={any} mode={s}",
        .{ state.manipulation_entity, @tagName(mapManipulationMode(state.manipulation_mode)) },
    ) catch action;
    store.recordIntent(.human, action, detail) catch |err| {
        std.log.warn("failed to record manipulation intent: {s}", .{@errorName(err)});
    };
}

fn buildDragPayload(state: *EditorState, layer_context: *engine.core.LayerContext) ?collaboration_mod.DragPayload {
    const active = state.active_drag_payload orelse return null;
    var payload = switch (active.kind) {
        .entity => collaboration_mod.DragPayload{ .kind = .entity, .entity_id = active.entity_id },
        .asset_model => collaboration_mod.DragPayload{ .kind = .asset_model },
        .asset_material => collaboration_mod.DragPayload{ .kind = .asset_material },
        .asset_texture => collaboration_mod.DragPayload{ .kind = .asset_texture },
        .place_actor => collaboration_mod.DragPayload{ .kind = .place_actor },
    };

    if (active.entity_id) |entity_id| {
        if (layer_context.world.getEntityConst(entity_id)) |entity| {
            payload.asset_name.set(entity.name);
        }
    }
    if (active.asset_index) |asset_index| {
        if (asset_index < state.asset_entries.items.len) {
            const entry = state.asset_entries.items[asset_index];
            payload.asset_name.set(entry.name);
            payload.asset_path.set(entry.path);
        }
    }
    if (active.actor_kind) |actor_kind| {
        payload.actor_kind.set(placeActorKindLabel(actor_kind));
    }

    return payload;
}

fn buildSelectedAsset(state: *EditorState) ?collaboration_mod.SelectedAsset {
    const selected_index = state.selected_asset_index orelse return null;
    if (selected_index >= state.asset_entries.items.len) {
        return null;
    }
    const entry = state.asset_entries.items[selected_index];
    var asset = collaboration_mod.SelectedAsset{};
    asset.kind.set(assetKindLabel(entry.kind));
    asset.id.set(entry.id);
    asset.name.set(entry.name);
    asset.path.set(entry.path);
    return asset;
}

fn buildPendingViewportDrop(state: *EditorState) ?collaboration_mod.PendingViewportDrop {
    const pending = state.pending_viewport_drop orelse return null;
    var drop = switch (pending.source_kind) {
        .asset => collaboration_mod.PendingViewportDrop{ .kind = .asset },
        .place_actor => collaboration_mod.PendingViewportDrop{ .kind = .place_actor },
    };

    if (pending.asset_index) |asset_index| {
        if (asset_index < state.asset_entries.items.len) {
            drop.asset_name.set(state.asset_entries.items[asset_index].name);
        }
    }
    if (pending.actor_kind) |actor_kind| {
        drop.actor_kind.set(placeActorKindLabel(actor_kind));
    }
    if (pending.pixel) |pixel| {
        drop.pixel = pixel;
        drop.has_pixel = true;
    }
    if (pending.world_position) |world_position| {
        drop.world_position = world_position;
        drop.has_world_position = true;
    }
    drop.target_entity = pending.target_entity;
    return drop;
}

fn mapManipulationMode(mode: state_mod.ManipulationMode) collaboration_mod.ManipulationMode {
    return switch (mode) {
        .none => .none,
        .translate => .translate,
        .rotate => .rotate,
        .scale => .scale,
    };
}

fn mapTransformSpace(space: state_mod.TransformSpace) collaboration_mod.TransformSpace {
    return switch (space) {
        .local => .local,
        .world => .world,
    };
}

fn snapshotCameraProjection(camera_component: engine.scene.Camera) collaboration_mod.CameraProjection {
    return switch (camera_component.projection) {
        .perspective => |projection| .{
            .kind = .perspective,
            .fov_y_radians = projection.fov_y_radians,
            .near_clip = projection.near_clip,
            .far_clip = projection.far_clip,
        },
        .orthographic => |projection| .{
            .kind = .orthographic,
            .orthographic_size = projection.size,
            .near_clip = projection.near_clip,
            .far_clip = projection.far_clip,
        },
    };
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
    const ndc_y = -(clip[1] / clip[3]);
    if (ndc_x < -1.15 or ndc_x > 1.15 or ndc_y < -1.15 or ndc_y > 1.15) {
        return null;
    }

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn previewColor(action: collaboration_mod.PreviewAction, visible: bool) u32 {
    const alpha: f32 = if (visible) 0.96 else 0.55;
    return engine.ui.ImGui.getColorU32(switch (action) {
        .created => .{ 0.24, 0.90, 0.56, alpha },
        .updated => .{ 0.96, 0.78, 0.30, alpha },
        .deleted => .{ 0.98, 0.42, 0.42, alpha },
    });
}

fn assetKindLabel(kind: state_mod.AssetKind) []const u8 {
    return switch (kind) {
        .scene => "scene",
        .model => "model",
        .material => "material",
        .texture => "texture",
        .shader => "shader",
    };
}

fn placeActorKindLabel(kind: state_mod.PlaceActorKind) []const u8 {
    return switch (kind) {
        .empty => "empty",
        .camera => "camera",
        .cube => "cube",
        .sphere => "sphere",
        .plane => "plane",
        .point_light => "point_light",
        .spot_light => "spot_light",
        .directional_light => "directional_light",
        .vfx_fountain => "vfx_fountain",
        .vfx_orbit => "vfx_orbit",
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
