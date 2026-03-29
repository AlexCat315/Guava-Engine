const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const shader_support = @import("../shader_support.zig");
const base_pass_mod = @import("base_pass.zig");

pub const DepthPrepass = struct {
    pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !DepthPrepass {
        var pass = DepthPrepass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *DepthPrepass, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const DepthPrepass) bool {
        return self.pipeline_hdr != null and self.pipeline_ldr != null;
    }

    pub fn draw(
        self: *DepthPrepass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        target: base_pass_mod.DrawTarget,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const pipeline = switch (target) {
            .hdr => &self.pipeline_hdr.?,
            .ldr => &self.pipeline_ldr.?,
        };
        device.bindGraphicsPipeline(pass, pipeline);
        for (prepared_scene.opaque_meshes) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
                .skinning_meta = item.skinning_meta,
                .skin_matrices = item.skin_matrices,
            };
            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0);
            device.bindIndexBuffer(pass, &item.index_buffer, .u32, 0);
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.drawIndexedPrimitives(pass, item.index_count, 1, 0, 0, 0);
            stats.draw_calls += 1;
            stats.triangles_drawn += item.index_count / 3;
        }

        return stats;
    }

    fn createResources(self: *DepthPrepass, device: *rhi_mod.RhiDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "depth_prepass");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(mesh_pass_mod.GpuVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "position"),
            },
            .{
                .location = 4,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "joints"),
            },
            .{
                .location = 5,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "weights"),
            },
        };

        self.pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float);
        errdefer if (self.pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm_srgb);
    }

    fn createPipeline(
        self: *DepthPrepass,
        device: *rhi_mod.RhiDevice,
        vertex_layouts: []const rhi_mod.VertexBufferLayoutDesc,
        vertex_attributes: []const rhi_mod.VertexAttributeDesc,
        color_format: rhi_types.TextureFormat,
    ) !rhi_mod.GraphicsPipeline {
        return device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts,
            .vertex_attributes = vertex_attributes,
            .color_format = color_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });
    }
};
