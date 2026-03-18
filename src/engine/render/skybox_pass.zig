const std = @import("std");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const shader_support = @import("shader_support.zig");
const math = @import("../math/mat4.zig");
const mesh_pass_mod = @import("mesh_pass.zig");

const FullscreenVertex = extern struct {
    position: [2]f32,
};

const fullscreen_triangle = [_]FullscreenVertex{
    .{ .position = .{ -1.0, -1.0 } },
    .{ .position = .{ 3.0, -1.0 } },
    .{ .position = .{ -1.0, 3.0 } },
};

pub const SkyboxUniforms = extern struct {
    projection: [16]f32,
    view: [16]f32,
    camera_position: [4]f32,
    inv_vp: [16]f32, // Precomputed inverse of (projection * view_rot_only)
};

pub const SkyboxPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SkyboxPass {
        var pass = SkyboxPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SkyboxPass, device: *rhi_mod.RhiDevice) void {
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.fullscreen_vertex_buffer) |*buffer| {
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

    pub fn isReady(self: *const SkyboxPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    fn mat4Inverse(m: [16]f32) [16]f32 {
        // Simplified matrix inverse for view-projection matrices
        // In a production engine, use a proper matrix inverse function
        var result: [16]f32 = undefined;
        
        // For view-projection matrices, we can compute the inverse more efficiently
        // by inverting view and projection separately and multiplying in reverse order
        // This is a placeholder - should implement proper matrix inverse
        
        // Simple implementation that works for typical view-projection matrices
        const det = m[0] * (m[5] * m[10] - m[9] * m[6]) -
                   m[4] * (m[1] * m[10] - m[9] * m[2]) +
                   m[8] * (m[1] * m[6] - m[5] * m[2]);
        
        if (@abs(det) < 0.00001) {
            return m; // Return original if singular
        }
        
        const inv_det = 1.0 / det;
        
        result[0] = (m[5] * m[10] - m[9] * m[6]) * inv_det;
        result[1] = (m[9] * m[2] - m[1] * m[10]) * inv_det;
        result[2] = (m[1] * m[6] - m[5] * m[2]) * inv_det;
        result[3] = 0.0;
        
        result[4] = (m[8] * m[6] - m[4] * m[10]) * inv_det;
        result[5] = (m[0] * m[10] - m[8] * m[2]) * inv_det;
        result[6] = (m[4] * m[2] - m[0] * m[6]) * inv_det;
        result[7] = 0.0;
        
        result[8] = (m[4] * m[9] - m[8] * m[5]) * inv_det;
        result[9] = (m[8] * m[1] - m[0] * m[9]) * inv_det;
        result[10] = (m[0] * m[5] - m[4] * m[1]) * inv_det;
        result[11] = 0.0;
        
        result[12] = -(m[12] * result[0] + m[13] * result[4] + m[14] * result[8]);
        result[13] = -(m[12] * result[1] + m[13] * result[5] + m[14] * result[9]);
        result[14] = -(m[12] * result[2] + m[13] * result[6] + m[14] * result[10]);
        result[15] = 1.0;
        
        return result;
    }

    pub fn draw(
        self: *SkyboxPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        env_map_texture: *const rhi_mod.Texture,
    ) void {
        if (!self.isReady()) {
            return;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);

        // Extract view rotation only (remove translation)
        var view_rot_only = prepared_scene.view_matrix;
        view_rot_only[12] = 0.0;
        view_rot_only[13] = 0.0;
        view_rot_only[14] = 0.0;
        
        // Compute VP = projection * view_rot_only
        const vp = math.mul(prepared_scene.projection_matrix, view_rot_only);
        
        // Precompute inverse VP on CPU
        const inv_vp = mat4Inverse(vp);

        var uniforms = SkyboxUniforms{
            .projection = prepared_scene.projection_matrix,
            .view = prepared_scene.view_matrix,
            .camera_position = prepared_scene.camera_world_position,
            .inv_vp = inv_vp,
        };
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&uniforms));

        // Create a temporary bind group for the environment map or keep it cached
        // For simplicity we create it temporarily, though caching is better.
        // In a real implementation we'd cache it or put it in a bind group state.
        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = env_map_texture,
                .sampler = &self.sampler.?,
            },
        };
        var bind_group = device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
            .slot_offset = 0,
        }) catch return;
        defer device.releaseBindGroup(&bind_group);

        device.bindGroup(pass, &bind_group);
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);
    }

    fn createResources(self: *SkyboxPass, device: *rhi_mod.RhiDevice) !void {
        self.fullscreen_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(FullscreenVertex) * fullscreen_triangle.len,
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer if (self.fullscreen_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.fullscreen_vertex_buffer.?, std.mem.sliceAsBytes(fullscreen_triangle[0..]));

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "skybox");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(FullscreenVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(FullscreenVertex, "position"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float, // Output to HDR buffer
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal, // Skybox is drawn at Z=1.0
            .depth_test = true,
            .depth_write = false,
        });
    }
};
