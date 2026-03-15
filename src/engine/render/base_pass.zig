const std = @import("std");
const mesh_resource = @import("../assets/mesh_resource.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const shader_support = @import("shader_support.zig");

pub const BasePass = struct {
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !BasePass {
        var pass = BasePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *BasePass, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const BasePass) bool {
        return self.pipeline != null;
    }

    pub fn draw(
        self: *BasePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        for (prepared_scene.items) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
            };
            var fragment_uniforms = mesh_pass_mod.BasePassUniforms{
                .base_color_factor = item.base_color_factor,
            };

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
                .format = .float4,
                .offset = @offsetOf(mesh_resource.Vertex, "color"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(mesh_resource.Vertex, "uv"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
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
    }
};
