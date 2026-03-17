const std = @import("std");
const mesh_resource = @import("../assets/mesh_resource.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const shader_support = @import("shader_support.zig");
const render_types = @import("types.zig");
const vec3 = @import("../math/vec3.zig");

pub const BasePass = struct {
    fill_pipeline: ?rhi_mod.GraphicsPipeline = null,
    wireframe_pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !BasePass {
        var pass = BasePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *BasePass, device: *rhi_mod.RhiDevice) void {
        if (self.wireframe_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.fill_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const BasePass) bool {
        return self.fill_pipeline != null and self.wireframe_pipeline != null;
    }

    pub fn draw(
        self: *BasePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        viewport_state: render_types.EditorViewportState,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const pipeline = switch (viewport_state.render_mode) {
            .wireframe => &self.wireframe_pipeline.?,
            .textured, .unlit => &self.fill_pipeline.?,
        };
        device.bindGraphicsPipeline(pass, pipeline);

        const main_light = if (prepared_scene.lights.directional_lights.len > 0)
            prepared_scene.lights.directional_lights[0]
        else
            mesh_pass_mod.DirectionalLightBlock{ .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }), .color = .{ 1.0, 0.98, 0.92 }, .intensity = 1.6 };

        const point_light = if (prepared_scene.lights.point_lights.len > 0)
            prepared_scene.lights.point_lights[0]
        else
            mesh_pass_mod.PointLightBlock{ .position = .{ 0.0, 0.0, 0.0 }, .color = .{ 1.0, 0.95, 0.9 }, .intensity = 0.0, .range = 1.0 };

        for (prepared_scene.opaque_meshes) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
            };
            var fragment_uniforms = mesh_pass_mod.BasePassUniforms{
                .base_color_factor = item.base_color_factor,
                .emissive_factor = item.emissive_factor,
                .pbr_factors = item.pbr_factors,
                .has_textures = item.has_textures,
                .camera_world_position = prepared_scene.camera_world_position,
                .light_direction = .{ main_light.direction[0], main_light.direction[1], main_light.direction[2], 0.0 },
                .light_color_intensity = .{ main_light.color[0], main_light.color[1], main_light.color[2], main_light.intensity },
                .point_light_position_radius = .{ point_light.position[0], point_light.position[1], point_light.position[2], point_light.range },
                .point_light_color_intensity = .{ point_light.color[0], point_light.color[1], point_light.color[2], point_light.intensity },
                .ambient_color = prepared_scene.ambient_color,
            };
            if (viewport_state.render_mode == .unlit) {
                fragment_uniforms.light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
                fragment_uniforms.point_light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
                fragment_uniforms.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 };
            }

            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0);
            device.bindIndexBuffer(pass, &item.index_buffer, .u32, 0);
            device.bindGroup(pass, &item.bind_group);
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
            device.drawIndexedPrimitives(pass, item.index_count, 1, 0, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += item.index_count / 3;
        }

        return stats;
    }

    fn createResources(self: *BasePass, device: *rhi_mod.RhiDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "mesh");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(mesh_resource.Vertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_resource.Vertex, "position"),
            },
            .{
                .location = 1,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_resource.Vertex, "normal"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_resource.Vertex, "color"),
            },
            .{
                .location = 3,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(mesh_resource.Vertex, "uv"),
            },
        };

        self.fill_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });
        errdefer if (self.fill_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };

        self.wireframe_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .line,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });
    }
};
