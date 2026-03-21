const std = @import("std");
const math = @import("../math/mat4.zig");
const axis_mod = @import("../math/axis.zig");
const components = @import("../scene/components.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const shader_support = @import("shader_support.zig");

pub const EditorGizmoMode = enum {
    idle,
    translate,
    rotate,
    scale,
};

pub const EditorGizmoAxis = axis_mod.Axis3;

pub const EditorGizmoSpace = enum {
    local,
    world,
};

pub const EditorGizmoState = struct {
    mode: EditorGizmoMode = .idle,
    axis: EditorGizmoAxis = .free,
    space: EditorGizmoSpace = .local,
};

pub const WorldLineVertex = extern struct {
    position: [3]f32,
};

const GizmoVertex = WorldLineVertex;

const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
};

const FragmentUniforms = extern struct {
    color: [4]f32,
};

const ring_segment_count = 48;

const axis_vertices = [_]GizmoVertex{
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 1.0 } },
};

const translate_arrow_vertices = [_]GizmoVertex{
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.82, 0.08, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.82, -0.08, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ 0.08, 0.82, 0.0 } },
    .{ .position = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ -0.08, 0.82, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.0, 0.08, 0.82 } },
    .{ .position = .{ 0.0, 0.0, 1.0 } },
    .{ .position = .{ 0.0, -0.08, 0.82 } },
};

const center_cross_vertices = [_]GizmoVertex{
    .{ .position = .{ -0.18, 0.0, 0.0 } },
    .{ .position = .{ 0.18, 0.0, 0.0 } },
    .{ .position = .{ 0.0, -0.18, 0.0 } },
    .{ .position = .{ 0.0, 0.18, 0.0 } },
    .{ .position = .{ 0.0, 0.0, -0.18 } },
    .{ .position = .{ 0.0, 0.0, 0.18 } },
};

const box_vertices = [_]GizmoVertex{
    .{ .position = .{ -0.24, -0.24, -0.24 } },
    .{ .position = .{ 0.24, -0.24, -0.24 } },
    .{ .position = .{ 0.24, -0.24, -0.24 } },
    .{ .position = .{ 0.24, 0.24, -0.24 } },
    .{ .position = .{ 0.24, 0.24, -0.24 } },
    .{ .position = .{ -0.24, 0.24, -0.24 } },
    .{ .position = .{ -0.24, 0.24, -0.24 } },
    .{ .position = .{ -0.24, -0.24, -0.24 } },
    .{ .position = .{ -0.24, -0.24, 0.24 } },
    .{ .position = .{ 0.24, -0.24, 0.24 } },
    .{ .position = .{ 0.24, -0.24, 0.24 } },
    .{ .position = .{ 0.24, 0.24, 0.24 } },
    .{ .position = .{ 0.24, 0.24, 0.24 } },
    .{ .position = .{ -0.24, 0.24, 0.24 } },
    .{ .position = .{ -0.24, 0.24, 0.24 } },
    .{ .position = .{ -0.24, -0.24, 0.24 } },
    .{ .position = .{ -0.24, -0.24, -0.24 } },
    .{ .position = .{ -0.24, -0.24, 0.24 } },
    .{ .position = .{ 0.24, -0.24, -0.24 } },
    .{ .position = .{ 0.24, -0.24, 0.24 } },
    .{ .position = .{ 0.24, 0.24, -0.24 } },
    .{ .position = .{ 0.24, 0.24, 0.24 } },
    .{ .position = .{ -0.24, 0.24, -0.24 } },
    .{ .position = .{ -0.24, 0.24, 0.24 } },
};

const ring_vertices = buildRingVertices();

pub const GizmoPass = struct {
    axis_vertex_buffer: ?rhi_mod.Buffer = null,
    translate_arrow_vertex_buffer: ?rhi_mod.Buffer = null,
    center_cross_vertex_buffer: ?rhi_mod.Buffer = null,
    box_vertex_buffer: ?rhi_mod.Buffer = null,
    ring_vertex_buffer: ?rhi_mod.Buffer = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !GizmoPass {
        var pass = GizmoPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *GizmoPass, device: *rhi_mod.RhiDevice) void {
        if (self.ring_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.box_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.center_cross_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.translate_arrow_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const GizmoPass) bool {
        return self.pipeline != null and
            self.axis_vertex_buffer != null and
            self.translate_arrow_vertex_buffer != null and
            self.center_cross_vertex_buffer != null and
            self.box_vertex_buffer != null and
            self.ring_vertex_buffer != null;
    }

    pub fn draw(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        selected_transform: components.Transform,
        state: EditorGizmoState,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const gizmo_scale = scaleForSelection(prepared_scene.camera_world_position, selected_transform.translation);
        const base_translation = selected_transform.translation;
        const base_rotation = rotationForSpace(selected_transform, state.space);

        device.bindGraphicsPipeline(pass, &self.pipeline.?);

        switch (state.mode) {
            .idle => {
                self.drawTranslateAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.92, state.axis, false, &stats);
                self.drawCenterCross(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, centerColor(.idle), &stats);
            },
            .translate => {
                self.drawTranslateAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, true, &stats);
                self.drawCenterCross(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, centerColor(.translate), &stats);
            },
            .rotate => {
                self.drawRotateRings(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, &stats);
                self.drawCenterCross(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.9, centerColor(.rotate), &stats);
            },
            .scale => {
                self.drawScaleAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, &stats);
                self.drawScaleBox(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, &stats);
            },
        }

        return stats;
    }

    pub fn drawWorldLines(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        vertices: []const WorldLineVertex,
        color: [4]f32,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or vertices.len == 0) {
            return stats;
        }

        const buffer = try createVertexBuffer(device, vertices);
        defer {
            var owned = buffer;
            device.releaseBuffer(&owned);
        }

        const model = math.identity();
        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        self.drawShape(device, frame, pass, buffer, 0, vertices.len, view_projection, model, color, &stats);
        return stats;
    }

    fn createResources(self: *GizmoPass, device: *rhi_mod.RhiDevice) !void {
        self.axis_vertex_buffer = try createVertexBuffer(device, axis_vertices[0..]);
        errdefer if (self.axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.translate_arrow_vertex_buffer = try createVertexBuffer(device, translate_arrow_vertices[0..]);
        errdefer if (self.translate_arrow_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.center_cross_vertex_buffer = try createVertexBuffer(device, center_cross_vertices[0..]);
        errdefer if (self.center_cross_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.box_vertex_buffer = try createVertexBuffer(device, box_vertices[0..]);
        errdefer if (self.box_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.ring_vertex_buffer = try createVertexBuffer(device, ring_vertices[0..]);
        errdefer if (self.ring_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.stages = try shader_support.loadProgramStages(device, "gizmo");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(GizmoVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(GizmoVertex, "position"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = null,
            .primitive_type = .line_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });
    }

    fn drawTranslateAxes(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        active: bool,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const mode: EditorGizmoMode = if (active) .translate else .idle;
        const d: f32 = 0.012;
        const x_color = axisColor(.x, constrained_axis, mode);
        const y_color = axisColor(.y, constrained_axis, mode);
        const z_color = axisColor(.z, constrained_axis, mode);
        const offsets = [_][3]f32{ .{ 0, 0, 0 }, .{ 0, d, 0 }, .{ 0, -d, 0 }, .{ 0, 0, d }, .{ 0, 0, -d } };
        for (offsets) |off| {
            const t = [3]f32{
                translation[0] + off[0] * gizmo_scale,
                translation[1] + off[1] * gizmo_scale,
                translation[2] + off[2] * gizmo_scale,
            };
            const model = composeModelMatrix(t, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });
            self.drawShape(device, frame, pass, self.translate_arrow_vertex_buffer.?, 0, 6, view_projection, model, x_color, stats);
            self.drawShape(device, frame, pass, self.translate_arrow_vertex_buffer.?, 6, 6, view_projection, model, y_color, stats);
            self.drawShape(device, frame, pass, self.translate_arrow_vertex_buffer.?, 12, 6, view_projection, model, z_color, stats);
        }
    }

    fn drawScaleAxes(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const d: f32 = 0.012;
        const x_color = axisColor(.x, constrained_axis, .scale);
        const y_color = axisColor(.y, constrained_axis, .scale);
        const z_color = axisColor(.z, constrained_axis, .scale);
        const offsets = [_][3]f32{ .{ 0, 0, 0 }, .{ 0, d, 0 }, .{ 0, -d, 0 }, .{ 0, 0, d }, .{ 0, 0, -d } };
        for (offsets) |off| {
            const t = [3]f32{
                translation[0] + off[0] * gizmo_scale,
                translation[1] + off[1] * gizmo_scale,
                translation[2] + off[2] * gizmo_scale,
            };
            const model = composeModelMatrix(t, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });
            self.drawShape(device, frame, pass, self.axis_vertex_buffer.?, 0, 2, view_projection, model, x_color, stats);
            self.drawShape(device, frame, pass, self.axis_vertex_buffer.?, 2, 2, view_projection, model, y_color, stats);
            self.drawShape(device, frame, pass, self.axis_vertex_buffer.?, 4, 2, view_projection, model, z_color, stats);
        }
    }

    fn drawRotateRings(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const d: f32 = 0.012;
        const x_color = axisColor(.x, constrained_axis, .rotate);
        const y_color = axisColor(.y, constrained_axis, .rotate);
        const z_color = axisColor(.z, constrained_axis, .rotate);
        const offsets = [_][3]f32{ .{ 0, 0, 0 }, .{ 0, d, 0 }, .{ 0, -d, 0 }, .{ 0, 0, d }, .{ 0, 0, -d } };
        for (offsets) |off| {
            const t = [3]f32{
                translation[0] + off[0] * gizmo_scale,
                translation[1] + off[1] * gizmo_scale,
                translation[2] + off[2] * gizmo_scale,
            };
            const x_model = composeModelMatrix(t, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, std.math.pi * 0.5, 0.0 });
            const y_model = composeModelMatrix(t, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ std.math.pi * 0.5, 0.0, 0.0 });
            const z_model = composeModelMatrix(t, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });

            self.drawShape(device, frame, pass, self.ring_vertex_buffer.?, 0, ring_vertices.len, view_projection, x_model, x_color, stats);
            self.drawShape(device, frame, pass, self.ring_vertex_buffer.?, 0, ring_vertices.len, view_projection, y_model, y_color, stats);
            self.drawShape(device, frame, pass, self.ring_vertex_buffer.?, 0, ring_vertices.len, view_projection, z_model, z_color, stats);
        }
    }

    fn drawScaleBox(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const model = composeModelMatrix(translation, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });
        self.drawShape(device, frame, pass, self.box_vertex_buffer.?, 0, box_vertices.len, view_projection, model, centerColor(.scale), stats);
    }

    fn drawCenterCross(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        color: [4]f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const model = composeModelMatrix(translation, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });
        self.drawShape(device, frame, pass, self.center_cross_vertex_buffer.?, 0, center_cross_vertices.len, view_projection, model, color, stats);
    }

    fn drawShape(
        self: *GizmoPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        buffer: rhi_mod.Buffer,
        first_vertex: usize,
        vertex_count: usize,
        view_projection: [16]f32,
        model: [16]f32,
        color: [4]f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        _ = self;
        var vertex_uniforms = VertexUniforms{
            .view_projection = view_projection,
            .model = model,
        };
        var fragment_uniforms = FragmentUniforms{
            .color = color,
        };

        device.bindVertexBuffer(pass, 0, &buffer, 0);
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
        device.drawPrimitives(pass, @intCast(vertex_count), 1, @intCast(first_vertex), 0);
        stats.draw_calls += 1;
    }
};

fn createVertexBuffer(device: *rhi_mod.RhiDevice, vertices: []const GizmoVertex) !rhi_mod.Buffer {
    const buffer = try device.createBuffer(.{
        .size = @intCast(@sizeOf(GizmoVertex) * vertices.len),
        .usage = rhi_types.BufferUsage.vertex,
    });
    errdefer {
        var owned = buffer;
        device.releaseBuffer(&owned);
    }
    try device.uploadBufferData(&buffer, std.mem.sliceAsBytes(vertices));
    return buffer;
}

fn buildRingVertices() [ring_segment_count * 2]GizmoVertex {
    var vertices: [ring_segment_count * 2]GizmoVertex = undefined;
    var index: usize = 0;
    while (index < ring_segment_count) : (index += 1) {
        const angle_start = (@as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(ring_segment_count))) * std.math.tau;
        const angle_end = (@as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(ring_segment_count))) * std.math.tau;
        vertices[index * 2] = .{
            .position = .{
                std.math.cos(angle_start) * 0.9,
                std.math.sin(angle_start) * 0.9,
                0.0,
            },
        };
        vertices[index * 2 + 1] = .{
            .position = .{
                std.math.cos(angle_end) * 0.9,
                std.math.sin(angle_end) * 0.9,
                0.0,
            },
        };
    }
    return vertices;
}

fn composeModelMatrix(
    translation: [3]f32,
    rotation: [3]f32,
    scale: [3]f32,
    extra_rotation: [3]f32,
) [16]f32 {
    const base_rotation = math.mul(
        math.mul(math.rotationZ(rotation[2]), math.rotationY(rotation[1])),
        math.rotationX(rotation[0]),
    );
    const local_rotation = math.mul(
        math.mul(math.rotationZ(extra_rotation[2]), math.rotationY(extra_rotation[1])),
        math.rotationX(extra_rotation[0]),
    );
    return math.mul(
        math.mul(math.translation(translation), math.mul(base_rotation, local_rotation)),
        math.scale(scale),
    );
}

fn scaleForSelection(camera_world_position: [4]f32, target_position: [3]f32) f32 {
    const dx = camera_world_position[0] - target_position[0];
    const dy = camera_world_position[1] - target_position[1];
    const dz = camera_world_position[2] - target_position[2];
    const distance = std.math.sqrt(dx * dx + dy * dy + dz * dz);
    return std.math.clamp(distance * 0.18, 0.7, 3.4);
}

fn rotationForSpace(selected_transform: components.Transform, space: EditorGizmoSpace) [3]f32 {
    const quat = @import("../math/quat.zig");
    return switch (space) {
        .local => quat.toEuler(selected_transform.rotation),
        .world => .{ 0.0, 0.0, 0.0 },
    };
}

fn axisColor(axis: EditorGizmoAxis, constrained_axis: EditorGizmoAxis, mode: EditorGizmoMode) [4]f32 {
    var color: [4]f32 = switch (axis) {
        .free => .{ 1.0, 0.86, 0.32, 1.0 },
        .x => .{ 0.98, 0.3, 0.28, 1.0 },
        .y => .{ 0.3, 0.92, 0.38, 1.0 },
        .z => .{ 0.28, 0.58, 1.0, 1.0 },
    };

    if (constrained_axis != .free) {
        if (axis == constrained_axis) {
            color[0] = @min(color[0] * 1.2, 1.0);
            color[1] = @min(color[1] * 1.2, 1.0);
            color[2] = @min(color[2] * 1.2, 1.0);
        } else {
            color[0] *= 0.35;
            color[1] *= 0.35;
            color[2] *= 0.35;
        }
    } else if (mode == .idle) {
        color[0] *= 0.82;
        color[1] *= 0.82;
        color[2] *= 0.82;
    }

    return color;
}

fn centerColor(mode: EditorGizmoMode) [4]f32 {
    return switch (mode) {
        .idle => .{ 1.0, 0.78, 0.28, 1.0 },
        .translate => .{ 1.0, 0.92, 0.45, 1.0 },
        .rotate => .{ 1.0, 0.72, 0.32, 1.0 },
        .scale => .{ 0.95, 0.95, 0.98, 1.0 },
    };
}

test "scaleForSelection grows with distance and clamps" {
    try std.testing.expect(scaleForSelection(.{ 0.0, 0.0, 2.0, 1.0 }, .{ 0.0, 0.0, 0.0 }) >= 0.7);
    try std.testing.expectEqual(@as(f32, 3.4), scaleForSelection(.{ 0.0, 0.0, 50.0, 1.0 }, .{ 0.0, 0.0, 0.0 }));
}

test "axisColor dims unconstrained axes when locked" {
    const locked = axisColor(.y, .x, .translate);
    try std.testing.expect(locked[1] < 0.4);
    const highlighted = axisColor(.x, .x, .translate);
    try std.testing.expect(highlighted[0] >= 0.99);
}

test "rotationForSpace resets world gizmo orientation" {
    const quat = @import("../math/quat.zig");
    const euler = [3]f32{ 0.25, 0.5, 0.75 };
    const selected = components.Transform{
        .rotation = quat.fromEuler(euler),
    };
    const local_rot = rotationForSpace(selected, .local);
    try std.testing.expectApproxEqAbs(euler[0], local_rot[0], 0.0001);
    try std.testing.expectApproxEqAbs(euler[1], local_rot[1], 0.0001);
    try std.testing.expectApproxEqAbs(euler[2], local_rot[2], 0.0001);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, &rotationForSpace(selected, .world));
}
