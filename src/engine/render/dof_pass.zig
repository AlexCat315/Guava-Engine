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

pub const DOFUniforms = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    resolution: [2]f32 = .{ 1.0, 1.0 },
    focus_distance: f32 = 10.0,
    focus_range: f32 = 5.0,
    blur_radius: f32 = 10.0,
    bokeh_radius: f32 = 5.0,
    near_blur: f32 = 0.0,
    far_blur: f32 = 100.0,
    quality: u32 = 4,
    padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const DOFPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_color_handle: usize = 0,
    bound_depth_handle: usize = 0,
    bound_coc_handle: usize = 0,
    pipeline_coc: ?rhi_mod.GraphicsPipeline = null,
    pipeline_blur: ?rhi_mod.GraphicsPipeline = null,
    pipeline_composite: ?rhi_mod.GraphicsPipeline = null,
    stages_coc: ?shader_support.ProgramStages = null,
    stages_blur: ?shader_support.ProgramStages = null,
    stages_composite: ?shader_support.ProgramStages = null,
    coc_texture: ?rhi_mod.Texture = null,
    blur_texture: ?rhi_mod.Texture = null,

    pub fn init(device: *rhi_mod.RhiDevice) !DOFPass {
        var pass = DOFPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *DOFPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.fullscreen_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.pipeline_coc) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.pipeline_blur) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.pipeline_composite) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages_coc) |*stages| {
            stages.deinit(device);
        }
        if (self.stages_blur) |*stages| {
            stages.deinit(device);
        }
        if (self.stages_composite) |*stages| {
            stages.deinit(device);
        }
        if (self.coc_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.blur_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const DOFPass) bool {
        return self.pipeline_coc != null and
            self.pipeline_blur != null and
            self.pipeline_composite != null and
            self.fullscreen_vertex_buffer != null and
            self.sampler != null;
    }

    pub fn syncTextures(
        self: *DOFPass,
        device: *rhi_mod.RhiDevice,
        color_texture: *const rhi_mod.Texture,
        depth_texture: *const rhi_mod.Texture,
    ) !void {
        const color_handle = @intFromPtr(color_texture.raw);
        const depth_handle = @intFromPtr(depth_texture.raw);

        if (self.bind_group != null and
            self.bound_color_handle == color_handle and
            self.bound_depth_handle == depth_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        var bindings: [2]rhi_mod.TextureSamplerBinding = undefined;

        bindings[0] = .{
            .texture = color_texture,
            .sampler = &self.sampler.?,
        };
        bindings[1] = .{
            .texture = depth_texture,
            .sampler = &self.sampler.?,
        };

        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..2],
        });
        self.bound_color_handle = color_handle;
        self.bound_depth_handle = depth_handle;
    }

    pub fn drawCOC(
        self: *DOFPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: DOFUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline_coc.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    pub fn drawBlur(
        self: *DOFPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: DOFUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline_blur.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    pub fn drawComposite(
        self: *DOFPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: DOFUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline_composite.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *DOFPass, device: *rhi_mod.RhiDevice) !void {
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

        self.stages_coc = try shader_support.loadProgramStages(device, "dof_coc");
        errdefer if (self.stages_coc) |*stages| {
            stages.deinit(device);
        };

        self.stages_blur = try shader_support.loadProgramStages(device, "dof_blur");
        errdefer if (self.stages_blur) |*stages| {
            stages.deinit(device);
        };

        self.stages_composite = try shader_support.loadProgramStages(device, "dof_composite");
        errdefer if (self.stages_composite) |*stages| {
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

        self.pipeline_coc = try device.createGraphicsPipeline(.{
            .label = "DOF COC Pipeline",
            .vertex_shader = self.stages_coc.?.vertex,
            .fragment_shader = self.stages_coc.?.fragment,
            .vertex_layouts = &vertex_layouts,
            .vertex_attributes = &vertex_attributes,
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_test = false,
            .depth_write = false,
            .blend_enabled = false,
            .color_format = .r16_float,
            .depth_format = .invalid,
        });

        self.pipeline_blur = try device.createGraphicsPipeline(.{
            .label = "DOF Blur Pipeline",
            .vertex_shader = self.stages_blur.?.vertex,
            .fragment_shader = self.stages_blur.?.fragment,
            .vertex_layouts = &vertex_layouts,
            .vertex_attributes = &vertex_attributes,
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_test = false,
            .depth_write = false,
            .blend_enabled = false,
            .color_format = .rgba16_float,
            .depth_format = .invalid,
        });

        self.pipeline_composite = try device.createGraphicsPipeline(.{
            .label = "DOF Composite Pipeline",
            .vertex_shader = self.stages_composite.?.vertex,
            .fragment_shader = self.stages_composite.?.fragment,
            .vertex_layouts = &vertex_layouts,
            .vertex_attributes = &vertex_attributes,
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_test = false,
            .depth_write = false,
            .blend_enabled = false,
            .color_format = .rgba16_float,
            .depth_format = .invalid,
        });
    }
};
