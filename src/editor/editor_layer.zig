const std = @import("std");
const engine = @import("guava");

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
    editor_camera: ?engine.scene.EntityId = null,
    scene_camera: ?engine.scene.EntityId = null,
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

    pub fn asLayer(self: *EditorLayer) engine.core.Layer {
        return .{
            .name = "Editor",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        self.scene_camera = layer_context.world.primaryCameraEntity();
        self.editor_camera = try layer_context.world.createEntity(.{
            .name = "EditorCamera",
            .camera = .{
                .is_primary = true,
            },
            .transform = .{
                .translation = .{ 0.0, 2.4, 8.0 },
                .rotation_euler = .{ self.pitch, self.yaw, 0.0 },
            },
        });
        _ = layer_context.world.setPrimaryCamera(self.editor_camera.?);
        try self.refreshWindowTitle(layer_context);
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        try self.pruneMissingSelection(layer_context);
        try self.handleEditingShortcuts(layer_context);
        self.applyManipulation(layer_context);
        self.handleCameraControls(layer_context);

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
        if (input.wasKeyPressed(.g)) {
            try self.beginManipulation(layer_context, .translate);
        }
        if (input.wasKeyPressed(.r)) {
            try self.beginManipulation(layer_context, .rotate);
        }
        if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
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
        if (!self.editor_camera_active or self.manipulation_mode != .none) {
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
        const entity = layer_context.world.getEntity(selected) orelse return;

        self.focus_pivot = entity.transform.translation;
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
        }
    }

    fn duplicateSelection(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        const selected = layer_context.renderer.selectedEntity() orelse return;
        if (self.editor_camera != null and selected == self.editor_camera.?) {
            return;
        }

        const duplicate_id = try layer_context.world.duplicateEntity(selected);
        if (layer_context.world.getEntity(duplicate_id)) |duplicate| {
            duplicate.transform.translation[0] += 0.65;
            duplicate.transform.translation[1] += 0.15;
        }
        try layer_context.renderer.replaceSelection(duplicate_id);
        self.focusSelection(layer_context);
    }

    fn spawnPrimitive(self: *EditorLayer, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive) !void {
        const spawn_transform = self.spawnTransform(layer_context);
        const entity_id = try layer_context.world.createPrimitiveEntity(primitive, spawn_transform);
        try layer_context.renderer.replaceSelection(entity_id);
        self.focusSelection(layer_context);
    }

    fn spawnPointLight(self: *EditorLayer, layer_context: *engine.core.LayerContext) !void {
        var transform = self.spawnTransform(layer_context);
        transform.translation[1] += 1.0;
        const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
        try layer_context.renderer.replaceSelection(entity_id);
        self.focusSelection(layer_context);
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
            if (layer_context.world.getEntity(camera_id)) |camera| {
                return camera.transform;
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
            "Guava Editor [{s}] Sel:{s} Mode:{s}/{s} | RMB fly | Alt+LMB orbit | MMB pan | Wheel dolly | G/R/S edit | X/Y/Z axis | Space apply | Esc cancel | 1 cube 2 sphere 3 plane | L light | F focus | Ctrl+D duplicate | Del delete | Tab camera",
            .{ camera_mode, selected_name, manipulation_mode, manipulation_axis },
        );
        defer layer_context.world.allocator.free(title);
        try layer_context.window.setTitle(layer_context.world.allocator, title);
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
        const entity = layer_context.world.getEntity(selected) orelse return;

        self.manipulation_mode = mode;
        self.manipulation_axis = .free;
        self.manipulation_entity = selected;
        self.manipulation_origin = entity.transform;
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
        if (layer_context.world.getEntity(entity_id)) |entity| {
            entity.transform = self.manipulation_origin;
        }
        self.endManipulation();
    }

    fn applyManipulation(self: *EditorLayer, layer_context: *engine.core.LayerContext) void {
        const entity_id = self.manipulation_entity orelse return;
        const entity = layer_context.world.getEntity(entity_id) orelse {
            self.endManipulation();
            return;
        };
        const input = layer_context.input;
        if (@abs(input.mouse_delta[0]) < 0.0001 and @abs(input.mouse_delta[1]) < 0.0001) {
            return;
        }

        switch (self.manipulation_mode) {
            .none => {},
            .translate => self.applyTranslate(layer_context, entity),
            .rotate => self.applyRotate(input, entity),
            .scale => self.applyScale(input, entity),
        }
    }

    fn applyTranslate(
        self: *const EditorLayer,
        layer_context: *engine.core.LayerContext,
        entity: *engine.scene.Entity,
    ) void {
        const input = layer_context.input;
        const camera_transform = self.activeCameraTransform(layer_context);
        const right = rightFromYaw(camera_transform.rotation_euler[1]);
        const forward = forwardFromAngles(camera_transform.rotation_euler[1], camera_transform.rotation_euler[0]);
        const up = normalizeVec3(cross(right, forward));
        const distance = @max(lengthVec3(subVec3(camera_transform.translation, entity.transform.translation)), 1.0);
        const move_scale = distance * 0.0025;

        switch (self.manipulation_axis) {
            .free => {
                const delta = addVec3(
                    scaleVec3(right, input.mouse_delta[0] * move_scale),
                    scaleVec3(up, -input.mouse_delta[1] * move_scale),
                );
                entity.transform.translation = addVec3(entity.transform.translation, delta);
            },
            .x, .y, .z => {
                const axis = axisVector(self.manipulation_axis);
                const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * move_scale;
                entity.transform.translation = addVec3(entity.transform.translation, scaleVec3(axis, scalar));
            },
        }
    }

    fn applyRotate(self: *const EditorLayer, input: *const engine.core.InputState, entity: *engine.scene.Entity) void {
        const scalar = (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
        switch (self.manipulation_axis) {
            .free => {
                entity.transform.rotation_euler[1] -= input.mouse_delta[0] * 0.01;
                entity.transform.rotation_euler[0] -= input.mouse_delta[1] * 0.01;
            },
            .x => entity.transform.rotation_euler[0] += scalar,
            .y => entity.transform.rotation_euler[1] += scalar,
            .z => entity.transform.rotation_euler[2] += scalar,
        }
    }

    fn applyScale(self: *const EditorLayer, input: *const engine.core.InputState, entity: *engine.scene.Entity) void {
        const scalar = 1.0 + (input.mouse_delta[0] - input.mouse_delta[1]) * 0.01;
        switch (self.manipulation_axis) {
            .free => {
                entity.transform.scale = .{
                    clampScale(entity.transform.scale[0] * scalar),
                    clampScale(entity.transform.scale[1] * scalar),
                    clampScale(entity.transform.scale[2] * scalar),
                };
            },
            .x => entity.transform.scale[0] = clampScale(entity.transform.scale[0] * scalar),
            .y => entity.transform.scale[1] = clampScale(entity.transform.scale[1] * scalar),
            .z => entity.transform.scale[2] = clampScale(entity.transform.scale[2] * scalar),
        }
    }
};

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
