const std = @import("std");
const engine = @import("guava");

const autosave_path = "assets/scenes/editor_autosave.guava_scene";

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
        try self.refreshWindowTitle(layer_context);
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
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

    fn spawnPrimitive(self: *EditorLayer, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive) !void {
        const spawn_transform = self.spawnTransform(layer_context);
        const entity_id = try layer_context.world.createPrimitiveEntity(primitive, spawn_transform);
        try layer_context.renderer.replaceSelection(entity_id);
        self.focusSelection(layer_context);
        try self.captureSnapshot(layer_context);
    }

    fn spawnPointLight(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        var transform = self.spawnTransform(layer_context);
        transform.translation[1] += 1.0;
        const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
        try layer_context.renderer.replaceSelection(entity_id);
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
        _ = self;
        engine.scene.saveWorldToPath(layer_context.world.allocator, layer_context.world, autosave_path) catch |err| {
            std.log.err("failed to save scene to {s}: {}", .{ autosave_path, err });
            return;
        };
    }

    fn loadScene(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        self.endManipulation();
        engine.scene.loadWorldFromPath(layer_context.world.allocator, layer_context.world, autosave_path) catch |err| {
            std.log.err("failed to load scene from {s}: {}", .{ autosave_path, err });
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

    fn drawEditorUi(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        try self.drawMenuBar(layer_context);
        try self.drawStatsWindow(layer_context);
        try self.drawSceneWindow(layer_context);
        try self.drawInspectorWindow(layer_context);
    }

    fn drawStatsWindow(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = self;
        _ = engine.ui.ImGui.beginWindow("Stats");
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
        _ = engine.ui.ImGui.beginWindow("Scene");
        defer engine.ui.ImGui.endWindow();

        for (layer_context.world.entities.items) |entity| {
            if (entity.editor_only or entity.parent != null) {
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

        const is_selected = layer_context.renderer.selectedEntity() == entity_id;
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

        if (!leaf and is_open) {
            for (layer_context.world.entities.items) |child| {
                if (child.editor_only or child.parent != entity_id) {
                    continue;
                }
                try self.drawHierarchyNode(layer_context, child.id);
            }
            engine.ui.ImGui.treePop();
        }
    }

    fn drawInspectorWindow(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        _ = engine.ui.ImGui.beginWindow("Inspector");
        defer engine.ui.ImGui.endWindow();

        const selected = layer_context.renderer.selectedEntity() orelse {
            engine.ui.ImGui.text("No entity selected.");
            return;
        };

        const entity = layer_context.world.getEntity(selected) orelse {
            engine.ui.ImGui.text("Selection is stale.");
            return;
        };
        const world_transform = layer_context.world.worldTransform(selected) orelse entity.transform;

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

        if (entity.camera != null and engine.ui.ImGui.collapsingHeader("Camera", true)) {
            if (entity.camera.?.is_primary) {
                engine.ui.ImGui.text("Primary scene camera");
            } else if (engine.ui.ImGui.button("Make Primary Camera")) {
                _ = layer_context.world.setPrimaryCamera(selected);
                try self.captureSnapshot(layer_context);
            }
        }

        if (entity.light) |*light| {
            if (engine.ui.ImGui.collapsingHeader("Light", true)) {
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

    fn hasVisibleChildren(self: *const EditorLayer, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
        _ = self;
        for (world.entities.items) |entity| {
            if (!entity.editor_only and entity.parent == entity_id) {
                return true;
            }
        }
        return false;
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
