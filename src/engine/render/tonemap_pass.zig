const std = @import("std");
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

pub const TonemapUniforms = extern struct {
    // x: enable_manual_exposure, y: exposure, z/w: reserved
    exposure_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
    // x: enable_bloom, y: bloom_intensity, z/w: reserved
    bloom_params: [4]f32 = .{ 0.0, 0.35, 0.0, 0.0 },
    // x: enable_color_grading, y: saturation, z: contrast, w: gamma
    color_grading_params: [4]f32 = .{ 0.0, 1.0, 1.0, 1.0 },
};

pub const TonemapPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_hdr_texture_handle: usize = 0,
    bound_bloom_texture_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !TonemapPass {
        var pass = TonemapPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *TonemapPass, device: *rhi_mod.RhiDevice) void {
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

    pub fn isReady(self: *const TonemapPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *TonemapPass,
        device: *rhi_mod.RhiDevice,
        hdr_texture: *const rhi_mod.Texture,
        bloom_texture: *const rhi_mod.Texture,
    ) !void {
        const hdr_texture_handle = @intFromPtr(hdr_texture.raw);
        const bloom_texture_handle = @intFromPtr(bloom_texture.raw);
        if (self.bind_group != null and
            self.bound_hdr_texture_handle == hdr_texture_handle and
            self.bound_bloom_texture_handle == bloom_texture_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = hdr_texture,
                .sampler = &self.sampler.?,
            },
            .{
                .texture = bloom_texture,
                .sampler = &self.sampler.?,
            },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_hdr_texture_handle = hdr_texture_handle;
        self.bound_bloom_texture_handle = bloom_texture_handle;
    }

    pub fn draw(
        self: *TonemapPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        exposure_enabled: bool,
        exposure: f32,
        bloom_enabled: bool,
        bloom_intensity: f32,
        color_grading_enabled: bool,
        color_grading_saturation: f32,
        color_grading_contrast: f32,
        color_grading_gamma: f32,
    ) void {
        if (!self.isReady() or self.bind_group == null) {
            return;
        }

        var uniforms = TonemapUniforms{
            .exposure_params = .{
                if (exposure_enabled) 1.0 else 0.0,
                @max(exposure, 0.0),
                0.0,
                0.0,
            },
            .bloom_params = .{
                if (bloom_enabled) 1.0 else 0.0,
                @max(bloom_intensity, 0.0),
                0.0,
                0.0,
            },
            .color_grading_params = .{
                if (color_grading_enabled) 1.0 else 0.0,
                @max(color_grading_saturation, 0.0),
                @max(color_grading_contrast, 0.0),
                @max(color_grading_gamma, 0.001),
            },
        };

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);
    }

    fn createResources(self: *TonemapPass, device: *rhi_mod.RhiDevice) !void {
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

        self.stages = try shader_support.loadProgramStages(device, "tonemap");
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
            .color_format = .bgra8_unorm,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });
    }
};
