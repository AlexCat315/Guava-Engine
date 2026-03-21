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

pub const SSRUniforms = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    view: [16]f32 = std.mem.zeroes([16]f32),
    inv_view: [16]f32 = std.mem.zeroes([16]f32),
    resolution: [2]f32 = .{ 1.0, 1.0 },
    ray_step: f32 = 0.1,
    ray_max_distance: f32 = 100.0,
    ray_thickness: f32 = 0.5,
    intensity: f32 = 0.5,
    fade_distance: f32 = 10.0,
    edge_fade: f32 = 0.1,
    stride: f32 = 4.0,
    stride_z_cutoff: f32 = 50.0,
    padding: [2]f32 = .{ 0.0, 0.0 },
};

pub const SSRPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_color_handle: usize = 0,
    bound_depth_handle: usize = 0,
    bound_normal_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SSRPass {
        var pass = SSRPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SSRPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
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

    pub fn isReady(self: *const SSRPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *SSRPass,
        device: *rhi_mod.RhiDevice,
        color_texture: *const rhi_mod.Texture,
        depth_texture: *const rhi_mod.Texture,
        normal_texture: ?*const rhi_mod.Texture,
    ) !void {
        const color_handle = @intFromPtr(color_texture.raw);
        const depth_handle = @intFromPtr(depth_texture.raw);
        const normal_handle = if (normal_texture) |nt| @intFromPtr(nt.raw) else 0;

        if (self.bind_group != null and
            self.bound_color_handle == color_handle and
            self.bound_depth_handle == depth_handle and
            self.bound_normal_handle == normal_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        var bindings: [3]rhi_mod.TextureSamplerBinding = undefined;
        var binding_count: usize = 0;

        bindings[binding_count] = .{
            .texture = color_texture,
            .sampler = &self.sampler.?,
        };
        binding_count += 1;

        bindings[binding_count] = .{
            .texture = depth_texture,
            .sampler = &self.sampler.?,
        };
        binding_count += 1;

        if (normal_texture) |nt| {
            bindings[binding_count] = .{
                .texture = nt,
                .sampler = &self.sampler.?,
            };
            binding_count += 1;
        }

        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..binding_count],
        });
        self.bound_color_handle = color_handle;
        self.bound_depth_handle = depth_handle;
        self.bound_normal_handle = normal_handle;
    }

    pub fn draw(
        self: *SSRPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: SSRUniforms,
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

    fn createResources(self: *SSRPass, device: *rhi_mod.RhiDevice) !void {
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

        self.stages = try shader_support.loadProgramStages(device, "ssr");
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
                .offset = 0,
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .label = "SSR Pipeline",
            .vertex_shader = self.stages.?.vertex,
            .fragment_shader = self.stages.?.fragment,
            .vertex_layouts = &vertex_layouts,
            .vertex_attributes = &vertex_attributes,
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_test = false,
            .depth_write = false,
            .blend_enabled = true,
            .blend_src_factor = .one,
            .blend_dst_factor = .one,
            .color_format = .rgba16_float,
            .depth_format = .invalid,
        });
    }
};
