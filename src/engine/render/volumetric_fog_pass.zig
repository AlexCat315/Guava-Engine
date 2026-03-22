const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const shader_support = @import("shader_support.zig");

const FullscreenVertex = extern struct {
    position: [2]f32,
};

const fullscreen_triangle = [_]FullscreenVertex{
    .{ .position = .{ -1.0, -1.0 } },
    .{ .position = .{ 3.0, -1.0 } },
    .{ .position = .{ -1.0, 3.0 } },
};

pub const VolumetricFogUniforms = extern struct {
    inv_view_projection: [16]f32 = std.mem.zeroes([16]f32),
    light_space_matrix: [16]f32 = std.mem.zeroes([16]f32),
    camera_position: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    light_direction: [4]f32 = .{ 0.0, -1.0, 0.0, 0.0 },
    light_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    // x: density, y: height_falloff, z: max_distance, w: num_steps
    fog_params: [4]f32 = .{ 0.02, 0.1, 100.0, 32.0 },
    // xyz: scattering color, w: absorption
    fog_color: [4]f32 = .{ 0.8, 0.85, 0.9, 1.0 },
    // x: wind_time, y: noise_scale, z: noise_strength, w: unused
    noise_params: [4]f32 = .{ 0.0, 0.05, 0.3, 0.0 },
};

pub const VolumetricFogPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    shadow_sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_depth_handle: usize = 0,
    bound_shadow_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !VolumetricFogPass {
        var pass = VolumetricFogPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *VolumetricFogPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.shadow_sampler) |*sampler| {
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

    pub fn isReady(self: *const VolumetricFogPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null and self.shadow_sampler != null;
    }

    pub fn syncTextures(
        self: *VolumetricFogPass,
        device: *rhi_mod.RhiDevice,
        depth_texture: *const rhi_mod.Texture,
        shadow_texture: *const rhi_mod.Texture,
    ) !void {
        const depth_handle = @intFromPtr(depth_texture.raw);
        const shadow_handle = @intFromPtr(shadow_texture.raw);

        if (self.bind_group != null and
            self.bound_depth_handle == depth_handle and
            self.bound_shadow_handle == shadow_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = depth_texture,
                .sampler = &self.sampler.?,
            },
            .{
                .texture = shadow_texture,
                .sampler = &self.shadow_sampler.?,
            },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_depth_handle = depth_handle;
        self.bound_shadow_handle = shadow_handle;
    }

    pub fn draw(
        self: *VolumetricFogPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: VolumetricFogUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *VolumetricFogPass, device: *rhi_mod.RhiDevice) !void {
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
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.shadow_sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .enable_compare = true,
            .compare_op = .less,
        });
        errdefer if (self.shadow_sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "volumetric_fog");
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
            .color_format = .rgba16_float,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
            .blend_state = .{
                .enable_blend = true,
                .src_color_blendfactor = .one,
                .dst_color_blendfactor = .src_alpha,
                .color_blend_op = .add,
                .src_alpha_blendfactor = .zero,
                .dst_alpha_blendfactor = .src_alpha,
                .alpha_blend_op = .add,
            },
        });
    }
};
