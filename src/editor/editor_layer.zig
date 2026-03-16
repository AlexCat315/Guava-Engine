const std = @import("std");
const engine = @import("guava");

const autosave_path = "assets/scenes/editor_autosave.guava_scene";
const entity_drag_payload = "guava.scene.entity";

const AssetKind = enum {
    scene,
    model,
    texture,
    shader,
};

const AssetEntry = struct {
    path: []u8,
    name: []u8,
    kind: AssetKind,
};

const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

const AxisConstraint = enum {
    free,
    x,
    y,
    z,
};

pub const EditorLayer = struct {
    allocator: ?std.mem.Allocator = null,
    editor_camera: ?engine.scene.EntityId = null,
    scene_camera: ?engine.scene.EntityId = null,
    inspector_name_entity: ?engine.scene.EntityId = null,
    inspector_name_buffer: [256]u8 = [_]u8{0} ** 256,
    editor_camera_active: bool = true,
    focus_pivot: [3]f32 = .{ 0.0, 1.0, 0.0 },
    yaw: f32 = 0.0,
    pitch: f32 = -0.18,
    orbit_distance: f32 = 8.0,
    look_sensitivity: f32 = 0.008,
    orbit_sensitivity: f32 = 0.01,
    pan_sensitivity: f32 = 0.01,
    wheel_speed: f32 = 1.2,
    move_speed: f32 = 6.0,
    title_frame_interval: usize = 8,
    manipulation_mode: ManipulationMode = .none,
    manipulation_axis: AxisConstraint = .free,
    manipulation_entity: ?engine.scene.EntityId = null,
    manipulation_origin: engine.scene.Transform = .{},
    snapshot_history: std.ArrayList([]u8) = .empty,
    snapshot_cursor: usize = 0,
    max_snapshots: usize = 64,
    asset_entries: std.ArrayList(AssetEntry) = .empty,
    selected_asset_index: ?usize = null,
    scene_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    asset_filter_buffer: [128]u8 = [_]u8{0} ** 128,

    pub fn asLayer(self: *EditorLayer) engine.core.Layer {
        return .{
            .name = "Editor",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_detach = onDetach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        self.allocator = layer_context.world.allocator;
        try engine.ui.ImGui.init(layer_context.window, layer_context.rhi());
        self.scene_camera = layer_context.world.primaryCameraEntity();
        try self.createEditorCamera(layer_context);
        self.syncGizmoState(layer_context);
        self.syncInspectorNameBuffer(layer_context);
        try self.resetSnapshotHistory(layer_context);
        try self.refreshAssetBrowser();
        try self.refreshWindowTitle(layer_context);
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        self.clearAssetBrowser();
        self.clearSnapshotHistory();
        engine.ui.ImGui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        try self.pruneMissingSelection(layer_context);
        self.syncInspectorNameBuffer(layer_context);
        engine.ui.ImGui.beginDockspace();
        try self.drawEditorUi(layer_context);
        try self.handleEditingShortcuts(layer_context);
        self.applyManipulation(layer_context);
        self.handleCameraControls(layer_context);
        self.syncGizmoState(layer_context);

        if (layer_context.frame_index % self.title_frame_interval == 0) {
            try self.refreshWindowTitle(layer_context);
        }
    }

    fn pruneMissingSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = self;
        if (layer_context.renderer.selectedEntity()) |selected| {
            if (!layer_context.world.hasEntity(selected)) {
                try layer_context.renderer.replaceSelection(null);
            }
        }
    }

    fn handleEditingShortcuts(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const input = layer_context.input;

        if (engine.ui.ImGui.wantsCaptureKeyboard()) {
            return;
        }

        if (input.modifiers.ctrl and input.wasKeyPressed(.z)) {
            try self.undo(layer_context);
            return;
        }
        if (input.modifiers.ctrl and input.wasKeyPressed(.y)) {
            try self.redo(layer_context);
            return;
        }

        if (self.manipulation_mode != .none) {
            if (input.wasKeyPressed(.x)) {
                self.manipulation_axis = .x;
            }
            if (input.wasKeyPressed(.y)) {
                self.manipulation_axis = .y;
            }
            if (input.wasKeyPressed(.z)) {
                self.manipulation_axis = .z;
            }
            if (input.wasKeyPressed(.space)) {
                self.endManipulation();
                try self.captureSnapshot(layer_context);
            }
            if (input.wasKeyPressed(.escape)) {
                self.cancelManipulation(layer_context);
            }
            if (input.wasKeyPressed(.g)) {
                try self.beginManipulation(layer_context, .translate);
            }
            if (input.wasKeyPressed(.r)) {
                try self.beginManipulation(layer_context, .rotate);
            }
            if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
                try self.beginManipulation(layer_context, .scale);
            }
            return;
        }

        if (input.modifiers.ctrl and input.wasKeyPressed(.s)) {
            self.saveScene(layer_context);
            return;
        }
        if (input.modifiers.ctrl and input.wasKeyPressed(.o)) {
            try self.loadScene(layer_context);
            return;
        }

        if (input.wasKeyPressed(.tab)) {
            self.toggleCameraMode(layer_context);
        }
        if (input.wasKeyPressed(.f)) {
            self.focusSelection(layer_context);
        }

        if (input.wasKeyPressed(.delete) or input.wasKeyPressed(.backspace)) {
            try self.deleteSelection(layer_context);
        }
        if (input.modifiers.ctrl and input.wasKeyPressed(.d)) {
            try self.duplicateSelection(layer_context);
        }
        if (input.wasKeyPressed(.p)) {
            if (input.modifiers.shift) {
                try self.unparentSelection(layer_context);
            } else {
                try self.parentSelection(layer_context);
            }
        }
        if (input.wasKeyPressed(.g)) {
            try self.beginManipulation(layer_context, .translate);
        }
        if (input.wasKeyPressed(.r)) {
            try self.beginManipulation(layer_context, .rotate);
        }
        if (input.wasKeyPressed(.s) and !input.modifiers.ctrl and !input.isMouseDown(.right)) {
            try self.beginManipulation(layer_context, .scale);
        }
        if (input.wasKeyPressed(.one)) {
            try self.spawnPrimitive(layer_context, .cube);
        }
        if (input.wasKeyPressed(.two)) {
            try self.spawnPrimitive(layer_context, .sphere);
        }
        if (input.wasKeyPressed(.three)) {
            try self.spawnPrimitive(layer_context, .plane);
        }
        if (input.wasKeyPressed(.l)) {
            try self.spawnPointLight(layer_context);
        }
    }

    fn handleCameraControls(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        if (!self.editor_camera_active or self.manipulation_mode != .none or engine.ui.ImGui.wantsCaptureMouse() or engine.ui.ImGui.wantsCaptureKeyboard()) {
            return;
        }

        const camera_id = self.editor_camera orelse return;
        const camera = layer_context.world.getEntity(camera_id) orelse return;
        const input = layer_context.input;

        if (input.modifiers.alt and input.isMouseDown(.left)) {
            self.yaw -= input.mouse_delta[0] * self.orbit_sensitivity;
            self.pitch = clampPitch(self.pitch - input.mouse_delta[1] * self.orbit_sensitivity);
            const forward = forwardFromAngles(self.yaw, self.pitch);
            camera.transform.rotation_euler = .{ self.pitch, self.yaw, 0.0 };
            camera.transform.translation = subVec3(self.focus_pivot, scaleVec3(forward, self.orbit_distance));
        } else {
            if (input.isMouseDown(.right)) {
                self.yaw -= input.mouse_delta[0] * self.look_sensitivity;
                self.pitch = clampPitch(self.pitch - input.mouse_delta[1] * self.look_sensitivity);
            }

            camera.transform.rotation_euler = .{ self.pitch, self.yaw, 0.0 };

            if (input.isMouseDown(.right)) {
                const forward = forwardFromAngles(self.yaw, self.pitch);
                const right = rightFromYaw(self.yaw);
                const move_up = [3]f32{ 0.0, 1.0, 0.0 };
                const boost: f32 = if (input.modifiers.shift) 3.5 else 1.0;
                const step = self.moveSpeed(layer_context.delta_seconds) * boost;
                var movement = [3]f32{ 0.0, 0.0, 0.0 };

                if (input.isKeyDown(.w)) movement = addVec3(movement, scaleVec3(forward, step));
                if (input.isKeyDown(.s)) movement = subVec3(movement, scaleVec3(forward, step));
                if (input.isKeyDown(.d)) movement = addVec3(movement, scaleVec3(right, step));
                if (input.isKeyDown(.a)) movement = subVec3(movement, scaleVec3(right, step));
                if (input.isKeyDown(.e)) movement = addVec3(movement, scaleVec3(move_up, step));
                if (input.isKeyDown(.q)) movement = subVec3(movement, scaleVec3(move_up, step));

                camera.transform.translation = addVec3(camera.transform.translation, movement);
                self.focus_pivot = addVec3(camera.transform.translation, scaleVec3(forward, self.orbit_distance));
            }
        }

        if (input.isMouseDown(.middle)) {
            const forward = forwardFromAngles(self.yaw, self.pitch);
            const right = rightFromYaw(self.yaw);
            const up = normalizeVec3(cross(right, forward));
            const pan_scale = @max(self.orbit_distance, 1.0) * self.pan_sensitivity * 0.05;
            const pan = addVec3(
                scaleVec3(right, -input.mouse_delta[0] * pan_scale),
                scaleVec3(up, input.mouse_delta[1] * pan_scale),
            );
            camera.transform.translation = addVec3(camera.transform.translation, pan);
            self.focus_pivot = addVec3(self.focus_pivot, pan);
        }

        if (@abs(input.mouse_wheel[1]) > 0.001) {
            const forward = forwardFromAngles(self.yaw, self.pitch);
            const zoom_step = input.mouse_wheel[1] * self.wheel_speed * @max(self.orbit_distance * 0.2, 0.8);
            camera.transform.translation = addVec3(camera.transform.translation, scaleVec3(forward, zoom_step));
            self.orbit_distance = clampDistance(lengthVec3(subVec3(self.focus_pivot, camera.transform.translation)));
        }

        camera.transform.rotation_euler = .{ self.pitch, self.yaw, 0.0 };
    }

    fn toggleCameraMode(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        if (self.manipulation_mode != .none) {
            return;
        }
        if (self.editor_camera_active) {
            if (self.scene_camera) |scene_camera_id| {
                if (layer_context.world.hasEntity(scene_camera_id)) {
                    _ = layer_context.world.setPrimaryCamera(scene_camera_id);
                    self.editor_camera_active = false;
                }
            }
            return;
        }

        if (self.editor_camera) |editor_camera_id| {
            if (layer_context.world.hasEntity(editor_camera_id)) {
                _ = layer_context.world.setPrimaryCamera(editor_camera_id);
                self.editor_camera_active = true;
            }
        }
    }

    fn focusSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        const selected = layer_context.renderer.selectedEntity() orelse return;
        const camera_id = self.editor_camera orelse return;
        const camera = layer_context.world.getEntity(camera_id) orelse return;
        const entity_transform = layer_context.world.worldTransform(selected) orelse return;

        self.focus_pivot = entity_transform.translation;
        if (!self.editor_camera_active) {
            return;
        }

        const forward = forwardFromAngles(self.yaw, self.pitch);
        self.orbit_distance = clampDistance(self.orbit_distance);
        camera.transform.translation = subVec3(self.focus_pivot, scaleVec3(forward, self.orbit_distance));
    }

    fn deleteSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selected = layer_context.renderer.selectedEntity() orelse return;
        if (self.editor_camera != null and selected == self.editor_camera.?) {
            return;
        }
        self.endManipulation();
        if (layer_context.world.destroyEntity(selected)) {
            try layer_context.renderer.replaceSelection(null);
            try self.captureSnapshot(layer_context);
        }
    }

    fn duplicateSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selected = layer_context.renderer.selectedEntity() orelse return;
        if (self.editor_camera != null and selected == self.editor_camera.?) {
            return;
        }

        const duplicate_id = try layer_context.world.duplicateEntity(selected);
        if (layer_context.world.worldTransform(duplicate_id)) |duplicate_transform| {
            var moved = duplicate_transform;
            moved.translation[0] += 0.65;
            moved.translation[1] += 0.15;
            _ = layer_context.world.setEntityWorldTransform(duplicate_id, moved);
        }
        try layer_context.renderer.replaceSelection(duplicate_id);
        self.syncInspectorNameBuffer(layer_context);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnEmptyEntity(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const entity_id = try layer_context.world.createEmptyEntity(self.spawnTransform(layer_context));
        try layer_context.renderer.replaceSelection(entity_id);
        self.syncInspectorNameBuffer(layer_context);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnCameraEntity(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const entity_id = try layer_context.world.createCameraEntity(self.activeCameraTransform(layer_context));
        try layer_context.renderer.replaceSelection(entity_id);
        self.scene_camera = entity_id;
        self.syncInspectorNameBuffer(layer_context);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnPrimitive(self: *EditorLayer, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive) !void {
        const spawn_transform = self.spawnTransform(layer_context);
        const entity_id = try layer_context.world.createPrimitiveEntity(primitive, spawn_transform);
        try layer_context.renderer.replaceSelection(entity_id);
        self.syncInspectorNameBuffer(layer_context);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnPointLight(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        var transform = self.spawnTransform(layer_context);
        transform.translation[1] += 1.0;
        const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
        try layer_context.renderer.replaceSelection(entity_id);
        self.syncInspectorNameBuffer(layer_context);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnTransform(self: *EditorLayer, layer_context: *engine.core.LayerContext) engine.scene.Transform {
        const camera_transform = self.activeCameraTransform(layer_context);
        const forward = forwardFromAngles(camera_transform.rotation_euler[1], camera_transform.rotation_euler[0]);
        const spawn_position = addVec3(camera_transform.translation, scaleVec3(forward, 3.0));

        return .{
            .translation = spawn_position,
        };
    }

    fn activeCameraTransform(self: *const EditorLayer, layer_context: *engine.core.LayerContext) engine.scene.Transform {
        const active_camera_id = if (self.editor_camera_active) self.editor_camera else layer_context.world.primaryCameraEntity();
        if (active_camera_id) |camera_id| {
            if (layer_context.world.worldTransform(camera_id)) |camera_transform| {
                return camera_transform;
            }
        }
        return .{
            .translation = .{ 0.0, 2.0, 6.0 },
        };
    }

    fn moveSpeed(self: *const EditorLayer, delta_seconds: f32) f32 {
        return self.move_speed * @max(delta_seconds, 0.001);
    }

    fn refreshWindowTitle(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selected_name = if (layer_context.renderer.selectedEntity()) |selected| blk: {
            if (layer_context.world.getEntity(selected)) |entity| break :blk entity.name;
            break :blk "None";
        } else "None";
        const camera_mode = if (self.editor_camera_active) "EditorCam" else "SceneCam";
        const manipulation_mode = switch (self.manipulation_mode) {
            .none => "Idle",
            .translate => "Move",
            .rotate => "Rotate",
            .scale => "Scale",
        };
        const manipulation_axis = switch (self.manipulation_axis) {
            .free => "Free",
            .x => "X",
            .y => "Y",
            .z => "Z",
        };

        const title = try std.fmt.allocPrint(
            layer_context.world.allocator,
            "Guava Editor [{s}] Sel:{s} Mode:{s}/{s} | RMB fly | Alt+LMB orbit | MMB pan | Wheel dolly | G/R/S edit | X/Y/Z axis | Space apply | Esc cancel | P parent | Shift+P unparent | Ctrl+S save | Ctrl+O load | 1 cube 2 sphere 3 plane | L light | F focus | Ctrl+D duplicate | Del delete | Tab camera",
            .{ camera_mode, selected_name, manipulation_mode, manipulation_axis },
        );
        defer layer_context.world.allocator.free(title);
        try layer_context.window.setTitle(layer_context.world.allocator, title);
    }

    fn createEditorCamera(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const transform = self.editorCameraTransform();
        self.editor_camera = try layer_context.world.createEntity(.{
            .name = "EditorCamera",
            .camera = .{
                .is_primary = true,
            },
            .transform = transform,
            .editor_only = true,
        });
        if (self.editor_camera_active) {
            _ = layer_context.world.setPrimaryCamera(self.editor_camera.?);
        }
    }

    fn editorCameraTransform(self: *const EditorLayer) engine.scene.Transform {
        return .{
            .translation = subVec3(self.focus_pivot, scaleVec3(forwardFromAngles(self.yaw, self.pitch), self.orbit_distance)),
            .rotation_euler = .{ self.pitch, self.yaw, 0.0 },
        };
    }

    fn saveScene(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        self.saveScenePath(layer_context, autosave_path);
    }

    fn saveScenePath(self: *EditorLayer, layer_context: *engine.core.LayerContext, path: []const u8) void {
        engine.scene.saveWorldToPath(layer_context.world.allocator, layer_context.world, path) catch |err| {
            std.log.err("failed to save scene to {s}: {}", .{ path, err });
            return;
        };
        self.refreshAssetBrowser() catch |err| {
            std.log.warn("failed to refresh asset browser after save: {}", .{err});
        };
    }

    fn loadScene(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        try self.loadScenePath(layer_context, autosave_path);
    }

    fn loadScenePath(self: *EditorLayer, layer_context: *engine.core.LayerContext, path: []const u8) !void {
        self.endManipulation();
        engine.scene.loadWorldFromPath(layer_context.world.allocator, layer_context.world, path) catch |err| {
            std.log.err("failed to load scene from {s}: {}", .{ path, err });
            return;
        };

        try layer_context.renderer.resetSceneState();
        self.scene_camera = layer_context.world.primaryCameraEntity();
        self.editor_camera = null;
        try self.createEditorCamera(layer_context);
        if (!self.editor_camera_active) {
            if (self.scene_camera) |scene_camera_id| {
                _ = layer_context.world.setPrimaryCamera(scene_camera_id);
            }
        }
        try layer_context.renderer.replaceSelection(null);
        self.syncInspectorNameBuffer(layer_context);
        try self.resetSnapshotHistory(layer_context);
        try self.refreshWindowTitle(layer_context);
    }

    fn importModelPath(self: *EditorLayer, layer_context: *engine.core.LayerContext, path: []const u8) !void {
        const report = try layer_context.world.importGltfStaticModelInstance(path, self.spawnTransform(layer_context));
        if (report.root_entity) |root_entity| {
            try layer_context.renderer.replaceSelection(root_entity);
            self.syncInspectorNameBuffer(layer_context);
            self.focusSelection(layer_context);
        }
        try self.captureSnapshot(layer_context);
        try self.refreshWindowTitle(layer_context);
    }

    fn refreshAssetBrowser(self: *EditorLayer) !void {
        const allocator = self.allocator orelse return;
        self.clearAssetBrowser();

        var assets_dir = std.fs.cwd().openDir("assets", .{ .iterate = true }) catch |err| {
            std.log.warn("failed to open assets directory: {}", .{err});
            return;
        };
        defer assets_dir.close();

        var walker = try assets_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const kind = assetKindForPath(entry.path) orelse continue;
            const relative_path = try std.fs.path.join(allocator, &.{ "assets", entry.path });
            errdefer allocator.free(relative_path);
            const name = try allocator.dupe(u8, std.fs.path.basename(entry.path));
            errdefer allocator.free(name);

            try self.asset_entries.append(allocator, .{
                .path = relative_path,
                .name = name,
                .kind = kind,
            });
        }

        std.sort.heap(AssetEntry, self.asset_entries.items, {}, lessThanAssetEntry);
        if (self.selected_asset_index) |selected_index| {
            if (selected_index >= self.asset_entries.items.len) {
                self.selected_asset_index = null;
            }
        }
    }

    fn clearAssetBrowser(self: *EditorLayer) void {
        const allocator = self.allocator orelse return;
        for (self.asset_entries.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.name);
        }
        self.asset_entries.deinit(allocator);
        self.asset_entries = .empty;
        self.selected_asset_index = null;
    }

    fn selectedAsset(self: *EditorLayer) ?*const AssetEntry {
        const index = self.selected_asset_index orelse return null;
        if (index >= self.asset_entries.items.len) {
            self.selected_asset_index = null;
            return null;
        }
        return &self.asset_entries.items[index];
    }

    fn selectedAssetCanLoadScene(self: *EditorLayer) bool {
        const entry = self.selectedAsset() orelse return false;
        return entry.kind == .scene;
    }

    fn selectedAssetCanImportModel(self: *EditorLayer) bool {
        const entry = self.selectedAsset() orelse return false;
        return entry.kind == .model;
    }

    fn instantiateSelectedAsset(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const entry = self.selectedAsset() orelse return;
        switch (entry.kind) {
            .scene => try self.loadScenePath(layer_context, entry.path),
            .model => try self.importModelPath(layer_context, entry.path),
            else => {},
        }
    }

    fn captureSnapshot(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const allocator = self.allocator orelse return;
        const snapshot = try engine.scene.serializeWorldAlloc(allocator, layer_context.world);
        errdefer allocator.free(snapshot);

        if (self.snapshot_history.items.len > 0) {
            const current = self.snapshot_history.items[self.snapshot_cursor];
            if (std.mem.eql(u8, current, snapshot)) {
                allocator.free(snapshot);
                return;
            }
        }

        while (self.snapshot_history.items.len > self.snapshot_cursor + 1) {
            const removed = self.snapshot_history.pop().?;
            allocator.free(removed);
        }

        try self.snapshot_history.append(allocator, snapshot);
        self.snapshot_cursor = self.snapshot_history.items.len - 1;

        while (self.snapshot_history.items.len > self.max_snapshots) {
            const removed = self.snapshot_history.orderedRemove(0);
            allocator.free(removed);
            if (self.snapshot_cursor > 0) {
                self.snapshot_cursor -= 1;
            }
        }
    }

    fn resetSnapshotHistory(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        self.clearSnapshotHistory();
        try self.captureSnapshot(layer_context);
    }

    fn clearSnapshotHistory(self: *EditorLayer) void {
        const allocator = self.allocator orelse return;
        for (self.snapshot_history.items) |snapshot| {
            allocator.free(snapshot);
        }
        self.snapshot_history.deinit(allocator);
        self.snapshot_history = .empty;
        self.snapshot_cursor = 0;
    }

    fn undo(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        if (self.snapshot_history.items.len == 0 or self.snapshot_cursor == 0) {
            return;
        }
        self.snapshot_cursor -= 1;
        try self.restoreSnapshot(layer_context, self.snapshot_cursor);
    }

    fn redo(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        if (self.snapshot_history.items.len == 0 or self.snapshot_cursor + 1 >= self.snapshot_history.items.len) {
            return;
        }
        self.snapshot_cursor += 1;
        try self.restoreSnapshot(layer_context, self.snapshot_cursor);
    }

    fn restoreSnapshot(self: *EditorLayer, layer_context: *engine.core.LayerContext, index: usize) !void {
        if (index >= self.snapshot_history.items.len) {
            return;
        }

        self.endManipulation();
        const snapshot = self.snapshot_history.items[index];
        try engine.scene.deserializeWorldFromSlice(layer_context.world.allocator, layer_context.world, snapshot);
        try layer_context.renderer.resetSceneState();
        self.scene_camera = layer_context.world.primaryCameraEntity();
        self.editor_camera = null;
        try self.createEditorCamera(layer_context);
        if (!self.editor_camera_active) {
            if (self.scene_camera) |scene_camera_id| {
                _ = layer_context.world.setPrimaryCamera(scene_camera_id);
            }
        }
        try layer_context.renderer.replaceSelection(null);
        self.syncInspectorNameBuffer(layer_context);
        try self.refreshWindowTitle(layer_context);
    }

    fn beginManipulation(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        mode: ManipulationMode,
    ) !void {
        const selected = layer_context.renderer.selectedEntity() orelse return;
        if (self.editor_camera != null and selected == self.editor_camera.?) {
            return;
        }

        self.manipulation_mode = mode;
        self.manipulation_axis = .free;
        self.manipulation_entity = selected;
        self.manipulation_origin = layer_context.world.worldTransform(selected) orelse return;
        self.syncGizmoState(layer_context);
        try self.refreshWindowTitle(layer_context);
    }

    fn endManipulation(self: *EditorLayer) void {
        self.manipulation_mode = .none;
        self.manipulation_axis = .free;
        self.manipulation_entity = null;
    }

    fn cancelManipulation(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        const entity_id = self.manipulation_entity orelse {
            self.endManipulation();
            return;
        };
        _ = layer_context.world.setEntityWorldTransform(entity_id, self.manipulation_origin);
        self.endManipulation();
        self.syncGizmoState(layer_context);
    }

    fn applyManipulation(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        const entity_id = self.manipulation_entity orelse return;
        var entity_transform = layer_context.world.worldTransform(entity_id) orelse {
            self.endManipulation();
            return;
        };
        const input = layer_context.input;
        if (@abs(input.mouse_delta[0]) < 0.0001 and @abs(input.mouse_delta[1]) < 0.0001) {
            return;
        }

        switch (self.manipulation_mode) {
            .none => {},
            .translate => self.applyTranslate(layer_context, &entity_transform),
            .rotate => self.applyRotate(input, &entity_transform),
            .scale => self.applyScale(input, &entity_transform),
        }

        _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform);
    }

    fn applyTranslate(
        self: *const EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity_transform: *engine.scene.Transform,
    ) void {
        const input = layer_context.input;
        const camera_transform = self.activeCameraTransform(layer_context);
        const right = rightFromYaw(camera_transform.rotation_euler[1]);
        const forward = forwardFromAngles(camera_transform.rotation_euler[1], camera_transform.rotation_euler[0]);
        const up = normalizeVec3(cross(right, forward));
        const distance = @max(lengthVec3(subVec3(camera_transform.translation, entity_transform.translation)), 1.0);
        const move_scale = distance * 0.0025;

        switch (self.manipulation_axis) {
            .free => {
                const delta = addVec3(
                    scaleVec3(right, input.mouse_delta[0] * move_scale),
                    scaleVec3(up, -input.mouse_delta[1] * move_scale),
                );
                entity_transform.translation = addVec3(entity_transform.translation, delta);
            },
            .x, .y, .z => {
                const axis = axisVector(self.manipulation_axis);
                const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * move_scale;
                entity_transform.translation = addVec3(entity_transform.translation, scaleVec3(axis, scalar));
            },
        }
    }

    fn applyRotate(self: *const EditorLayer, input: *const engine.core.InputState, entity_transform: *engine.scene.Transform) void {
        const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
        switch (self.manipulation_axis) {
            .free => {
                entity_transform.rotation_euler[1] -= input.mouse_delta[0] * 0.01;
                entity_transform.rotation_euler[0] -= input.mouse_delta[1] * 0.01;
            },
            .x => entity_transform.rotation_euler[0] += scalar,
            .y => entity_transform.rotation_euler[1] += scalar,
            .z => entity_transform.rotation_euler[2] += scalar,
        }
    }

    fn applyScale(self: *const EditorLayer, input: *const engine.core.InputState, entity_transform: *engine.scene.Transform) void {
        const scalar = 1.0 + (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
        switch (self.manipulation_axis) {
            .free => {
                entity_transform.scale = .{
                    clampScale(entity_transform.scale[0] * scalar),
                    clampScale(entity_transform.scale[1] * scalar),
                    clampScale(entity_transform.scale[2] * scalar),
                };
            },
            .x => entity_transform.scale[0] = clampScale(entity_transform.scale[0] * scalar),
            .y => entity_transform.scale[1] = clampScale(entity_transform.scale[1] * scalar),
            .z => entity_transform.scale[2] = clampScale(entity_transform.scale[2] * scalar),
        }
    }

    fn parentSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selection = layer_context.renderer.selectedEntities();
        if (selection.len < 2) {
            return;
        }

        const parent_id = layer_context.renderer.selectedEntity() orelse return;
        if (self.editor_camera != null and parent_id == self.editor_camera.?) {
            return;
        }

        var changed = false;
        for (selection) |entity_id| {
            if (entity_id == parent_id) {
                continue;
            }
            if (self.editor_camera != null and entity_id == self.editor_camera.?) {
                continue;
            }
            changed = (try layer_context.world.setParent(entity_id, parent_id)) or changed;
        }

        if (changed) {
            try self.captureSnapshot(layer_context);
        }
    }

    fn unparentSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selection = layer_context.renderer.selectedEntities();
        if (selection.len == 0) {
            return;
        }

        var changed = false;
        for (selection) |entity_id| {
            if (self.editor_camera != null and entity_id == self.editor_camera.?) {
                continue;
            }
            changed = (try layer_context.world.setParent(entity_id, null)) or changed;
        }

        if (changed) {
            try self.captureSnapshot(layer_context);
        }
    }

    fn reparentEntity(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        child_id: engine.scene.EntityId,
        parent_id: ?engine.scene.EntityId,
    ) !void {
        if (self.editor_camera != null and child_id == self.editor_camera.?) {
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
        self.syncInspectorNameBuffer(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn setPrimitiveMeshComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity: *engine.scene.Entity,
        primitive: engine.scene.Primitive,
    ) !void {
        const mesh_handle = try layer_context.world.assets().ensurePrimitiveMesh(primitive);
        const material_handle = try layer_context.world.assets().ensureDefaultMaterial();
        entity.mesh = .{
            .handle = mesh_handle,
            .primitive = primitive,
        };
        if (entity.material) |*material| {
            if (material.handle == null) {
                material.handle = material_handle;
            }
        } else {
            entity.material = .{
                .handle = material_handle,
            };
        }
        try self.captureSnapshot(layer_context);
    }

    fn clearMeshComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity: *engine.scene.Entity,
    ) !void {
        if (entity.mesh == null and entity.material == null) {
            return;
        }
        entity.mesh = null;
        entity.material = null;
        try self.captureSnapshot(layer_context);
    }

    fn addCameraComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        selected: engine.scene.EntityId,
        entity: *engine.scene.Entity,
    ) !void {
        if (entity.camera != null) {
            return;
        }
        const had_primary = layer_context.world.primaryCameraEntity() != null;
        entity.camera = .{};
        if (!had_primary) {
            _ = layer_context.world.setPrimaryCamera(selected);
        }
        self.scene_camera = layer_context.world.primaryCameraEntity();
        try self.captureSnapshot(layer_context);
    }

    fn removeCameraComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        selected: engine.scene.EntityId,
        entity: *engine.scene.Entity,
    ) !void {
        _ = selected;
        if (entity.camera == null) {
            return;
        }
        entity.camera = null;
        self.scene_camera = layer_context.world.primaryCameraEntity();
        try self.captureSnapshot(layer_context);
    }

    fn setLightComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity: *engine.scene.Entity,
        kind: engine.scene.LightKind,
    ) !void {
        entity.light = .{
            .kind = kind,
            .intensity = switch (kind) {
                .directional => 4.0,
                .point => 24.0,
                .spot => 18.0,
            },
            .range = switch (kind) {
                .directional => 10.0,
                .point => 12.0,
                .spot => 14.0,
            },
        };
        try self.captureSnapshot(layer_context);
    }

    fn removeLightComponent(
        self: *EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity: *engine.scene.Entity,
    ) !void {
        if (entity.light == null) {
            return;
        }
        entity.light = null;
        try self.captureSnapshot(layer_context);
    }

    fn drawEditorUi(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        try self.drawMenuBar(layer_context);
        try self.drawViewportToolbar(layer_context);
        try self.drawStatsWindow(layer_context);
        try self.drawSceneWindow(layer_context);
        try self.drawInspectorWindow(layer_context);
        try self.drawContentBrowser(layer_context);
    }

    fn drawViewportToolbar(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = engine.ui.ImGui.beginWindow("Viewport Toolbar 视口工具条");
        defer engine.ui.ImGui.endWindow();

        engine.ui.ImGui.labelText("Camera 相机", if (self.editor_camera_active) "Editor" else "Scene");
        var mode_buffer: [32]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buffer, "{s}", .{
            switch (self.manipulation_mode) {
                .none => "Idle",
                .translate => "Move",
                .rotate => "Rotate",
                .scale => "Scale",
            },
        });
        engine.ui.ImGui.labelText("Mode 模式", mode_text);

        if (engine.ui.ImGui.button("Toggle Camera")) {
            self.toggleCameraMode(layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Focus")) {
            self.focusSelection(layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Move")) {
            try self.beginManipulation(layer_context, .translate);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Rotate")) {
            try self.beginManipulation(layer_context, .rotate);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Scale")) {
            try self.beginManipulation(layer_context, .scale);
        }

        if (engine.ui.ImGui.button("Empty")) {
            try self.spawnEmptyEntity(layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Camera")) {
            try self.spawnCameraEntity(layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Cube")) {
            try self.spawnPrimitive(layer_context, .cube);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Sphere")) {
            try self.spawnPrimitive(layer_context, .sphere);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Light")) {
            try self.spawnPointLight(layer_context);
        }

        if (self.selectedAsset()) |entry| {
            engine.ui.ImGui.labelText("Asset 资源", entry.name);
            if ((entry.kind == .model or entry.kind == .scene) and engine.ui.ImGui.button("Instantiate / Load")) {
                try self.instantiateSelectedAsset(layer_context);
            }
        } else {
            engine.ui.ImGui.text("Select a model or scene in Content Browser to instantiate/load it.");
        }

        engine.ui.ImGui.text("The realtime viewport is still rendered in the central dockspace background.");
    }

    fn drawStatsWindow(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = self;
        _ = engine.ui.ImGui.beginWindow("Stats 状态");
        defer engine.ui.ImGui.endWindow();

        const runtime = layer_context.renderer.runtimeInfo();
        const summary = layer_context.world.summary();
        const fps = if (layer_context.delta_seconds > 0.0001) 1.0 / layer_context.delta_seconds else 0.0;

        var fps_buffer: [64]u8 = undefined;
        const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
        engine.ui.ImGui.labelText("FPS", fps_text);
        engine.ui.ImGui.labelText("Backend", engine.render.graphicsApiName(layer_context.renderer.backendApi()));
        engine.ui.ImGui.labelText("Device", runtime.deviceName());

        var draw_size_buffer: [64]u8 = undefined;
        const draw_size_text = try std.fmt.bufPrint(
            &draw_size_buffer,
            "{d} x {d}",
            .{ runtime.drawable_width, runtime.drawable_height },
        );
        engine.ui.ImGui.labelText("Drawable", draw_size_text);

        var entities_buffer: [32]u8 = undefined;
        const entities_text = try std.fmt.bufPrint(&entities_buffer, "{d}", .{summary.entity_count});
        engine.ui.ImGui.labelText("Entities", entities_text);

        var meshes_buffer: [32]u8 = undefined;
        const meshes_text = try std.fmt.bufPrint(&meshes_buffer, "{d}", .{summary.mesh_count});
        engine.ui.ImGui.labelText("Meshes", meshes_text);

        var lights_buffer: [32]u8 = undefined;
        const lights_text = try std.fmt.bufPrint(&lights_buffer, "{d}", .{summary.light_count});
        engine.ui.ImGui.labelText("Lights", lights_text);

        var cameras_buffer: [32]u8 = undefined;
        const cameras_text = try std.fmt.bufPrint(&cameras_buffer, "{d}", .{summary.camera_count});
        engine.ui.ImGui.labelText("Cameras", cameras_text);
    }

    fn drawMenuBar(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        if (!engine.ui.ImGui.beginMainMenuBar()) {
            return;
        }
        defer engine.ui.ImGui.endMainMenuBar();

        if (engine.ui.ImGui.beginMenu("File")) {
            defer engine.ui.ImGui.endMenu();
            if (engine.ui.ImGui.menuItem("Save Scene", "Ctrl+S", false, true)) {
                self.saveScene(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Load Scene", "Ctrl+O", false, true)) {
                try self.loadScene(layer_context);
            }
        }

        if (engine.ui.ImGui.beginMenu("Create")) {
            defer engine.ui.ImGui.endMenu();
            if (engine.ui.ImGui.menuItem("Empty", null, false, true)) {
                try self.spawnEmptyEntity(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Camera", null, false, true)) {
                try self.spawnCameraEntity(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Cube", "1", false, true)) {
                try self.spawnPrimitive(layer_context, .cube);
            }
            if (engine.ui.ImGui.menuItem("Sphere", "2", false, true)) {
                try self.spawnPrimitive(layer_context, .sphere);
            }
            if (engine.ui.ImGui.menuItem("Plane", "3", false, true)) {
                try self.spawnPrimitive(layer_context, .plane);
            }
            if (engine.ui.ImGui.menuItem("Point Light", "L", false, true)) {
                try self.spawnPointLight(layer_context);
            }
        }

        if (engine.ui.ImGui.beginMenu("Edit")) {
            defer engine.ui.ImGui.endMenu();
            const has_selection = layer_context.renderer.selectedEntity() != null;
            if (engine.ui.ImGui.menuItem("Duplicate", "Ctrl+D", false, has_selection)) {
                try self.duplicateSelection(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Delete", "Del", false, has_selection)) {
                try self.deleteSelection(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Parent To Active", "P", false, layer_context.renderer.selectedEntities().len > 1)) {
                try self.parentSelection(layer_context);
            }
            if (engine.ui.ImGui.menuItem("Unparent", "Shift+P", false, has_selection)) {
                try self.unparentSelection(layer_context);
            }
        }
    }

    fn drawSceneWindow(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = engine.ui.ImGui.beginWindow("Scene 场景");
        defer engine.ui.ImGui.endWindow();

        _ = engine.ui.ImGui.inputText("Scene Filter 过滤", self.scene_filter_buffer[0..]);
        if (engine.ui.ImGui.button("Scene Root 根节点") and layer_context.renderer.selectedEntities().len > 0) {
            try self.unparentSelection(layer_context);
        }
        var dropped_root: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(entity_drag_payload, &dropped_root)) {
            try self.reparentEntity(layer_context, dropped_root, null);
        }
        engine.ui.ImGui.separator();

        for (layer_context.world.entities.items) |entity| {
            if (entity.editor_only or entity.parent != null) {
                continue;
            }
            if (!self.shouldShowEntityInSceneTree(layer_context.world, entity.id)) {
                continue;
            }
            try self.drawHierarchyNode(layer_context, entity.id);
        }
    }

    fn drawHierarchyNode(self: *EditorLayer, layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) !void {
        const entity = layer_context.world.getEntityConst(entity_id) orelse return;
        if (entity.editor_only) {
            return;
        }

        const is_selected = self.isEntitySelected(layer_context, entity_id);
        const leaf = !self.hasVisibleChildren(layer_context.world, entity_id);
        const is_open = engine.ui.ImGui.treeNodeEntity(entity_id, entity.name, is_selected, leaf, false);

        if (engine.ui.ImGui.isItemClicked()) {
            if (layer_context.input.modifiers.shift or layer_context.input.modifiers.ctrl or layer_context.input.modifiers.super) {
                try layer_context.renderer.toggleSelection(entity_id);
            } else {
                try layer_context.renderer.replaceSelection(entity_id);
            }
            self.syncInspectorNameBuffer(layer_context);
        }

        _ = engine.ui.ImGui.dragDropSourceU64(entity_drag_payload, entity_id, entity.name);
        var dropped_child: u64 = 0;
        if (engine.ui.ImGui.acceptDragDropPayloadU64(entity_drag_payload, &dropped_child)) {
            try self.reparentEntity(layer_context, dropped_child, entity_id);
        }

        if (!leaf and is_open) {
            for (layer_context.world.entities.items) |child| {
                if (child.editor_only or child.parent != entity_id) {
                    continue;
                }
                if (!self.shouldShowEntityInSceneTree(layer_context.world, child.id)) {
                    continue;
                }
                try self.drawHierarchyNode(layer_context, child.id);
            }
            engine.ui.ImGui.treePop();
        }
    }

    fn drawInspectorWindow(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = engine.ui.ImGui.beginWindow("Details 细节");
        defer engine.ui.ImGui.endWindow();

        const selected = layer_context.renderer.selectedEntity() orelse {
            engine.ui.ImGui.text("No entity selected. 未选择对象。");
            return;
        };
        const selection_count = layer_context.renderer.selectedEntities().len;

        const entity = layer_context.world.getEntity(selected) orelse {
            engine.ui.ImGui.text("Selection is stale. 选择已失效。");
            return;
        };
        const world_transform = layer_context.world.worldTransform(selected) orelse entity.transform;

        var selection_count_buffer: [32]u8 = undefined;
        const selection_count_text = try std.fmt.bufPrint(&selection_count_buffer, "{d}", .{selection_count});
        engine.ui.ImGui.labelText("Selection Count 选择数量", selection_count_text);

        if (engine.ui.ImGui.collapsingHeader("Identity 标识", true)) {
            var entity_id_buffer: [32]u8 = undefined;
            const entity_id_text = try std.fmt.bufPrint(&entity_id_buffer, "{d}", .{selected});
            engine.ui.ImGui.labelText("Entity ID", entity_id_text);

            var editor_only = entity.editor_only;
            if (engine.ui.ImGui.checkbox("Editor Only 仅编辑器", &editor_only)) {
                entity.editor_only = editor_only;
                try self.captureSnapshot(layer_context);
            }
        }

        if (engine.ui.ImGui.collapsingHeader("Components 组件", true)) {
            if (entity.mesh == null) {
                if (engine.ui.ImGui.button("Add Cube Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .cube);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Add Sphere Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .sphere);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Add Plane Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .plane);
                }
            } else {
                if (engine.ui.ImGui.button("Set Cube Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .cube);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Set Sphere Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .sphere);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Set Plane Mesh")) {
                    try self.setPrimitiveMeshComponent(layer_context, entity, .plane);
                }
                if (engine.ui.ImGui.button("Remove Mesh Component")) {
                    try self.clearMeshComponent(layer_context, entity);
                    return;
                }
            }

            if (entity.camera == null) {
                if (engine.ui.ImGui.button("Add Camera Component")) {
                    try self.addCameraComponent(layer_context, selected, entity);
                }
            } else if (engine.ui.ImGui.button("Remove Camera Component")) {
                try self.removeCameraComponent(layer_context, selected, entity);
                return;
            }

            if (entity.light == null) {
                if (engine.ui.ImGui.button("Add Directional Light")) {
                    try self.setLightComponent(layer_context, entity, .directional);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Add Point Light")) {
                    try self.setLightComponent(layer_context, entity, .point);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Add Spot Light")) {
                    try self.setLightComponent(layer_context, entity, .spot);
                }
            } else if (engine.ui.ImGui.button("Remove Light Component")) {
                try self.removeLightComponent(layer_context, entity);
                return;
            }

            engine.ui.ImGui.separator();
        }

        if (entity.mesh) |mesh_component| {
            if (engine.ui.ImGui.collapsingHeader("Mesh 网格", true)) {
                engine.ui.ImGui.labelText("Primitive", primitiveLabel(mesh_component.primitive));
                if (mesh_component.handle) |mesh_handle| {
                    if (layer_context.world.assets().mesh(mesh_handle)) |mesh_resource| {
                        engine.ui.ImGui.labelText("Resource 资源", mesh_resource.name);

                        var vertices_buffer: [32]u8 = undefined;
                        const vertices_text = try std.fmt.bufPrint(&vertices_buffer, "{d}", .{mesh_resource.vertices.len});
                        engine.ui.ImGui.labelText("Vertices 顶点", vertices_text);

                        var indices_buffer: [32]u8 = undefined;
                        const indices_text = try std.fmt.bufPrint(&indices_buffer, "{d}", .{mesh_resource.indices.len});
                        engine.ui.ImGui.labelText("Indices 索引", indices_text);

                        var triangles_buffer: [32]u8 = undefined;
                        const triangles_text = try std.fmt.bufPrint(&triangles_buffer, "{d}", .{mesh_resource.indices.len / 3});
                        engine.ui.ImGui.labelText("Triangles 三角形", triangles_text);
                    }
                } else {
                    engine.ui.ImGui.text("Mesh component has no bound resource.");
                }
            }
        }

        if (entity.material) |*material_component| {
            if (engine.ui.ImGui.collapsingHeader("Material 材质", true)) {
                var effective_shading = material_component.shading;
                var effective_color = material_component.base_color_factor;
                if (material_component.handle) |material_handle| {
                    if (layer_context.world.assets().material(material_handle)) |material_resource| {
                        effective_shading = material_resource.shading;
                        effective_color = material_resource.base_color_factor;
                        engine.ui.ImGui.labelText("Resource 资源", material_resource.name);
                        if (material_resource.base_color_texture) |texture_handle| {
                            if (layer_context.world.assets().texture(texture_handle)) |texture_resource| {
                                engine.ui.ImGui.labelText("Texture 贴图", texture_resource.name);
                            }
                        } else {
                            engine.ui.ImGui.labelText("Texture 贴图", "None");
                        }
                    }
                } else {
                    engine.ui.ImGui.labelText("Resource 资源", "Embedded");
                }

                if (engine.ui.ImGui.button("Unlit")) {
                    effective_shading = .unlit;
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Lambert")) {
                    effective_shading = .lambert;
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("PBR")) {
                    effective_shading = .pbr_metallic_roughness;
                }

                if (effective_shading != material_component.shading) {
                    material_component.shading = effective_shading;
                    if (material_component.handle) |material_handle| {
                        if (layer_context.world.assets().material(material_handle)) |material_resource| {
                            @constCast(material_resource).shading = effective_shading;
                        }
                    }
                    try self.captureSnapshot(layer_context);
                }
                engine.ui.ImGui.labelText("Shading 着色", shadingLabel(effective_shading));

                var base_color_rgb: [3]f32 = .{ effective_color[0], effective_color[1], effective_color[2] };
                if (engine.ui.ImGui.dragFloat3("Base Color 基色", &base_color_rgb, 0.01, 0.0, 1.0)) {
                    effective_color[0] = std.math.clamp(base_color_rgb[0], 0.0, 1.0);
                    effective_color[1] = std.math.clamp(base_color_rgb[1], 0.0, 1.0);
                    effective_color[2] = std.math.clamp(base_color_rgb[2], 0.0, 1.0);
                    material_component.base_color_factor = effective_color;
                    if (material_component.handle) |material_handle| {
                        if (layer_context.world.assets().material(material_handle)) |material_resource| {
                            @constCast(material_resource).base_color_factor = effective_color;
                        }
                    }
                    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                        try self.captureSnapshot(layer_context);
                    }
                }

                var alpha = effective_color[3];
                if (engine.ui.ImGui.dragFloat("Opacity 不透明度", &alpha, 0.01, 0.0, 1.0)) {
                    effective_color[3] = std.math.clamp(alpha, 0.0, 1.0);
                    material_component.base_color_factor = effective_color;
                    if (material_component.handle) |material_handle| {
                        if (layer_context.world.assets().material(material_handle)) |material_resource| {
                            @constCast(material_resource).base_color_factor = effective_color;
                        }
                    }
                    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                        try self.captureSnapshot(layer_context);
                    }
                }
            }
        }

        if (engine.ui.ImGui.button("Focus")) {
            self.focusSelection(layer_context);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Duplicate")) {
            try self.duplicateSelection(layer_context);
            return;
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Delete")) {
            try self.deleteSelection(layer_context);
            return;
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Move")) {
            try self.beginManipulation(layer_context, .translate);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Rotate")) {
            try self.beginManipulation(layer_context, .rotate);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Scale")) {
            try self.beginManipulation(layer_context, .scale);
        }

        if (engine.ui.ImGui.inputText("Name", self.inspector_name_buffer[0..])) {
            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                const next_name = zeroTerminatedSlice(self.inspector_name_buffer[0..]);
                if (next_name.len > 0) {
                    if (try layer_context.world.renameEntity(selected, next_name)) {
                        self.syncInspectorNameBuffer(layer_context);
                        try self.captureSnapshot(layer_context);
                        try self.refreshWindowTitle(layer_context);
                    }
                }
            }
        }

        if (entity.parent) |parent_id| {
            if (layer_context.world.getEntityConst(parent_id)) |parent| {
                engine.ui.ImGui.labelText("Parent", parent.name);
            }
            if (engine.ui.ImGui.button("Unparent Selected")) {
                try self.unparentSelection(layer_context);
                return;
            }
        } else {
            engine.ui.ImGui.labelText("Parent", "Root");
        }

        var local_translation = entity.transform.translation;
        if (engine.ui.ImGui.dragFloat3("Local Translation", &local_translation, 0.05, -500.0, 500.0)) {
            entity.transform.translation = local_translation;
            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                try self.captureSnapshot(layer_context);
            }
        }

        var local_rotation = entity.transform.rotation_euler;
        if (engine.ui.ImGui.dragFloat3("Local Rotation", &local_rotation, 0.01, -std.math.tau, std.math.tau)) {
            entity.transform.rotation_euler = local_rotation;
            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                try self.captureSnapshot(layer_context);
            }
        }

        var local_scale = entity.transform.scale;
        if (engine.ui.ImGui.dragFloat3("Local Scale", &local_scale, 0.01, 0.05, 100.0)) {
            entity.transform.scale = .{
                clampScale(local_scale[0]),
                clampScale(local_scale[1]),
                clampScale(local_scale[2]),
            };
            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                try self.captureSnapshot(layer_context);
            }
        }

        var world_translation_buffer: [96]u8 = undefined;
        const world_translation = try std.fmt.bufPrint(
            &world_translation_buffer,
            "{d:.2}, {d:.2}, {d:.2}",
            .{ world_transform.translation[0], world_transform.translation[1], world_transform.translation[2] },
        );
        engine.ui.ImGui.labelText("World Translation", world_translation);

        var world_rotation_buffer: [96]u8 = undefined;
        const world_rotation = try std.fmt.bufPrint(
            &world_rotation_buffer,
            "{d:.2}, {d:.2}, {d:.2}",
            .{ world_transform.rotation_euler[0], world_transform.rotation_euler[1], world_transform.rotation_euler[2] },
        );
        engine.ui.ImGui.labelText("World Rotation", world_rotation);

        var world_scale_buffer: [96]u8 = undefined;
        const world_scale = try std.fmt.bufPrint(
            &world_scale_buffer,
            "{d:.2}, {d:.2}, {d:.2}",
            .{ world_transform.scale[0], world_transform.scale[1], world_transform.scale[2] },
        );
        engine.ui.ImGui.labelText("World Scale", world_scale);

        if (entity.camera) |*camera| {
            if (engine.ui.ImGui.collapsingHeader("Camera", true)) {
                if (camera.is_primary) {
                    engine.ui.ImGui.text("Primary scene camera");
                } else if (engine.ui.ImGui.button("Make Primary Camera")) {
                    _ = layer_context.world.setPrimaryCamera(selected);
                    try self.captureSnapshot(layer_context);
                }

                if (engine.ui.ImGui.button("Use Perspective")) {
                    camera.projection = .{ .perspective = .{} };
                    try self.captureSnapshot(layer_context);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Use Orthographic")) {
                    camera.projection = .{ .orthographic = .{} };
                    try self.captureSnapshot(layer_context);
                }

                switch (camera.projection) {
                    .perspective => |projection| {
                        var edited = projection;
                        var fov_degrees = radiansToDegrees(edited.fov_y_radians);
                        if (engine.ui.ImGui.dragFloat("FOV Y", &fov_degrees, 0.25, 10.0, 170.0)) {
                            edited.fov_y_radians = degreesToRadians(fov_degrees);
                            camera.projection = .{ .perspective = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }

                        if (engine.ui.ImGui.dragFloat("Near Clip", &edited.near_clip, 0.01, 0.001, 100.0)) {
                            edited.near_clip = std.math.clamp(edited.near_clip, 0.001, 100.0);
                            edited.far_clip = @max(edited.far_clip, edited.near_clip + 0.01);
                            camera.projection = .{ .perspective = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }

                        if (engine.ui.ImGui.dragFloat("Far Clip", &edited.far_clip, 1.0, 0.1, 5000.0)) {
                            edited.near_clip = @min(edited.near_clip, edited.far_clip - 0.01);
                            edited.far_clip = std.math.clamp(edited.far_clip, edited.near_clip + 0.01, 5000.0);
                            camera.projection = .{ .perspective = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }
                    },
                    .orthographic => |projection| {
                        var edited = projection;
                        if (engine.ui.ImGui.dragFloat("Size", &edited.size, 0.1, 0.01, 500.0)) {
                            edited.size = std.math.clamp(edited.size, 0.01, 500.0);
                            camera.projection = .{ .orthographic = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }

                        if (engine.ui.ImGui.dragFloat("Near Clip", &edited.near_clip, 0.05, -1000.0, 1000.0)) {
                            edited.near_clip = std.math.clamp(edited.near_clip, -1000.0, edited.far_clip - 0.01);
                            camera.projection = .{ .orthographic = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }

                        if (engine.ui.ImGui.dragFloat("Far Clip", &edited.far_clip, 0.05, -1000.0, 1000.0)) {
                            edited.far_clip = std.math.clamp(edited.far_clip, edited.near_clip + 0.01, 1000.0);
                            camera.projection = .{ .orthographic = edited };
                            if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                                try self.captureSnapshot(layer_context);
                            }
                        }
                    },
                }
            }
        }

        if (entity.light) |*light| {
            if (engine.ui.ImGui.collapsingHeader("Light", true)) {
                if (engine.ui.ImGui.button("Directional")) {
                    light.kind = .directional;
                    try self.captureSnapshot(layer_context);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Point")) {
                    light.kind = .point;
                    try self.captureSnapshot(layer_context);
                }
                engine.ui.ImGui.sameLine();
                if (engine.ui.ImGui.button("Spot")) {
                    light.kind = .spot;
                    try self.captureSnapshot(layer_context);
                }

                var light_color = light.color;
                if (engine.ui.ImGui.dragFloat3("Color", &light_color, 0.01, 0.0, 10.0)) {
                    light.color = light_color;
                    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                        try self.captureSnapshot(layer_context);
                    }
                }

                var intensity = light.intensity;
                if (engine.ui.ImGui.dragFloat("Intensity", &intensity, 0.1, 0.0, 100.0)) {
                    light.intensity = intensity;
                    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                        try self.captureSnapshot(layer_context);
                    }
                }

                if (light.kind != .directional) {
                    var range = light.range;
                    if (engine.ui.ImGui.dragFloat("Range", &range, 0.1, 0.1, 100.0)) {
                        light.range = range;
                        if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
                            try self.captureSnapshot(layer_context);
                        }
                    }
                }
            }
        }
    }

    fn drawContentBrowser(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = engine.ui.ImGui.beginWindow("Content Browser 资源浏览");
        defer engine.ui.ImGui.endWindow();

        if (engine.ui.ImGui.button("Refresh 刷新")) {
            try self.refreshAssetBrowser();
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Quick Save 快速保存")) {
            self.saveScene(layer_context);
        }

        if (self.selectedAsset()) |entry| {
            engine.ui.ImGui.labelText("Selected 已选", entry.name);
            engine.ui.ImGui.labelText("Type 类型", assetKindLabel(entry.kind));
            engine.ui.ImGui.labelText("Path 路径", entry.path);

            if (self.selectedAssetCanLoadScene() and engine.ui.ImGui.button("Save Over Selected Scene 覆盖保存")) {
                self.saveScenePath(layer_context, entry.path);
            }
            if (self.selectedAssetCanLoadScene() and engine.ui.ImGui.button("Load Selected Scene 加载场景")) {
                try self.loadScenePath(layer_context, entry.path);
                return;
            }
            if (self.selectedAssetCanImportModel() and engine.ui.ImGui.button("Instantiate Selected Model 实例化模型")) {
                try self.importModelPath(layer_context, entry.path);
            }
        } else {
            engine.ui.ImGui.text("No asset selected. 未选择资源。");
        }

        engine.ui.ImGui.separator();
        _ = engine.ui.ImGui.inputText("Asset Filter 过滤", self.asset_filter_buffer[0..]);
        try self.drawAssetGroup("Scenes 场景", .scene);
        try self.drawAssetGroup("Models 模型", .model);
        try self.drawAssetGroup("Textures 贴图", .texture);
        try self.drawAssetGroup("Shaders 着色器", .shader);
    }

    fn drawAssetGroup(self: *EditorLayer, title: []const u8, kind: AssetKind) !void {
        if (!engine.ui.ImGui.collapsingHeader(title, kind == .scene or kind == .model)) {
            return;
        }

        for (self.asset_entries.items, 0..) |entry, index| {
            if (entry.kind != kind) {
                continue;
            }
            if (!self.assetMatchesFilter(entry)) {
                continue;
            }

            var label_buffer: [320]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &label_buffer,
                "{s}{s}",
                .{ if (self.selected_asset_index == index) "> " else "", entry.name },
            );
            if (engine.ui.ImGui.button(label)) {
                self.selected_asset_index = index;
            }
            engine.ui.ImGui.sameLine();
            engine.ui.ImGui.text(entry.path);
        }
    }

    fn hasVisibleChildren(self: *const EditorLayer, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
        _ = self;
        for (world.entities.items) |entity| {
            if (!entity.editor_only and entity.parent == entity_id) {
                return true;
            }
        }
        return false;
    }

    fn shouldShowEntityInSceneTree(self: *const EditorLayer, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
        const filter = zeroTerminatedSlice(self.scene_filter_buffer[0..]);
        if (filter.len == 0) {
            return true;
        }
        return self.entityMatchesFilterRecursive(world, entity_id, filter);
    }

    fn entityMatchesFilterRecursive(
        self: *const EditorLayer,
        world: *const engine.scene.World,
        entity_id: engine.scene.EntityId,
        filter: []const u8,
    ) bool {
        const entity = world.getEntityConst(entity_id) orelse return false;
        if (containsAsciiInsensitive(entity.name, filter)) {
            return true;
        }
        for (world.entities.items) |child| {
            if (!child.editor_only and child.parent == entity_id and self.entityMatchesFilterRecursive(world, child.id, filter)) {
                return true;
            }
        }
        return false;
    }

    fn isEntitySelected(self: *const EditorLayer, layer_context: *const engine.core.LayerContext, entity_id: engine.scene.EntityId) bool {
        _ = self;
        for (layer_context.renderer.selectedEntities()) |selected_id| {
            if (selected_id == entity_id) {
                return true;
            }
        }
        return false;
    }

    fn assetMatchesFilter(self: *const EditorLayer, entry: AssetEntry) bool {
        const filter = zeroTerminatedSlice(self.asset_filter_buffer[0..]);
        if (filter.len == 0) {
            return true;
        }
        return containsAsciiInsensitive(entry.name, filter) or containsAsciiInsensitive(entry.path, filter);
    }

    fn syncInspectorNameBuffer(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        const selected = layer_context.renderer.selectedEntity();
        if (selected == self.inspector_name_entity) {
            return;
        }

        @memset(self.inspector_name_buffer[0..], 0);
        if (selected) |selected_id| {
            if (layer_context.world.getEntityConst(selected_id)) |entity| {
                const copy_len = @min(entity.name.len, self.inspector_name_buffer.len - 1);
                @memcpy(self.inspector_name_buffer[0..copy_len], entity.name[0..copy_len]);
            }
        }
        self.inspector_name_entity = selected;
    }

    fn syncGizmoState(self: *const EditorLayer, layer_context: *engine.core.LayerContext) void {
        layer_context.renderer.setEditorGizmoState(.{
            .mode = switch (self.manipulation_mode) {
                .none => .idle,
                .translate => .translate,
                .rotate => .rotate,
                .scale => .scale,
            },
            .axis = switch (self.manipulation_axis) {
                .free => .free,
                .x => .x,
                .y => .y,
                .z => .z,
            },
        });
    }
};

fn assetKindForPath(path: []const u8) ?AssetKind {
    if (std.mem.endsWith(u8, path, ".guava_scene")) {
        return .scene;
    }
    if (std.mem.endsWith(u8, path, ".gltf")) {
        return .model;
    }
    if (std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
        return .texture;
    }
    if (std.mem.endsWith(u8, path, ".glsl") or std.mem.endsWith(u8, path, ".spv") or std.mem.endsWith(u8, path, ".json")) {
        return .shader;
    }
    return null;
}

fn assetKindLabel(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => "Scene",
        .model => "Model",
        .texture => "Texture",
        .shader => "Shader",
    };
}

fn primitiveLabel(primitive: engine.scene.Primitive) []const u8 {
    return switch (primitive) {
        .cube => "Cube",
        .sphere => "Sphere",
        .plane => "Plane",
        .custom => "Custom",
    };
}

fn shadingLabel(shading: engine.scene.ShadingModel) []const u8 {
    return switch (shading) {
        .unlit => "Unlit",
        .lambert => "Lambert",
        .pbr_metallic_roughness => "PBR",
    };
}

fn lessThanAssetEntry(_: void, lhs: AssetEntry, rhs: AssetEntry) bool {
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matches = false;
                break;
            }
        }
        if (matches) {
            return true;
        }
    }
    return false;
}

fn zeroTerminatedSlice(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

fn forwardFromAngles(yaw: f32, pitch: f32) [3]f32 {
    const cos_pitch = std.math.cos(pitch);
    return normalizeVec3(.{
        -std.math.sin(yaw) * cos_pitch,
        std.math.sin(pitch),
        -std.math.cos(yaw) * cos_pitch,
    });
}

fn rightFromYaw(yaw: f32) [3]f32 {
    return normalizeVec3(.{
        std.math.cos(yaw),
        0.0,
        -std.math.sin(yaw),
    });
}

fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -1.45, 1.45);
}

fn clampDistance(distance: f32) f32 {
    return std.math.clamp(distance, 1.5, 40.0);
}

fn clampScale(scale: f32) f32 {
    return std.math.clamp(scale, 0.05, 100.0);
}

fn degreesToRadians(degrees: f32) f32 {
    return degrees * std.math.pi / 180.0;
}

fn radiansToDegrees(radians: f32) f32 {
    return radians * 180.0 / std.math.pi;
}

fn axisVector(axis: AxisConstraint) [3]f32 {
    return switch (axis) {
        .free => .{ 0.0, 0.0, 0.0 },
        .x => .{ 1.0, 0.0, 0.0 },
        .y => .{ 0.0, 1.0, 0.0 },
        .z => .{ 0.0, 0.0, 1.0 },
    };
}

fn addVec3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn subVec3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn scaleVec3(vector: [3]f32, scalar: f32) [3]f32 {
    return .{ vector[0] * scalar, vector[1] * scalar, vector[2] * scalar };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn lengthVec3(vector: [3]f32) f32 {
    return std.math.sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
}

fn normalizeVec3(vector: [3]f32) [3]f32 {
    const length = lengthVec3(vector);
    if (length <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return .{
        vector[0] / length,
        vector[1] / length,
        vector[2] / length,
    };
}
