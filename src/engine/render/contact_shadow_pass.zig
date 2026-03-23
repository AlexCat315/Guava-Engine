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

pub const ContactShadowUniforms = extern struct {
    projection: [16]f32,
    inv_projection: [16]f32,
    view: [16]f32,
    light_direction: [4]f32,
    resolution: [2]f32,
    max_distance: f32,
    thickness: f32,
    intensity: f32,
    bias: f32,
    num_steps: i32,
    padding: f32 = 0,
};

pub const ContactShadowPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_depth_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !ContactShadowPass {
        var pass = ContactShadowPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *ContactShadowPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.fullscreen_vertex_buffer) |*b| device.releaseBuffer(b);
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        self.* = undefined;
    }

    pub fn isReady(self: *const ContactShadowPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *ContactShadowPass,
        device: *rhi_mod.RhiDevice,
        depth_texture: *const rhi_mod.Texture,
    ) !void {
        const handle = @intFromPtr(depth_texture.raw);
        if (self.bind_group != null and self.bound_depth_handle == handle) return;

        if (self.bind_group) |*bg| device.releaseBindGroup(bg);

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_depth_handle = handle;
    }

    pub fn draw(
        self: *ContactShadowPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: ContactShadowUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) return stats;

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *ContactShadowPass, device: *rhi_mod.RhiDevice) !void {
        self.fullscreen_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(FullscreenVertex) * fullscreen_triangle.len,
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer if (self.fullscreen_vertex_buffer) |*b| device.releaseBuffer(b);
        try device.uploadBufferData(&self.fullscreen_vertex_buffer.?, std.mem.sliceAsBytes(fullscreen_triangle[0..]));

        self.sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*s| device.releaseSampler(s);

        self.stages = try shader_support.loadProgramStages(device, "contact_shadow");
        errdefer if (self.stages) |*s| s.deinit(device);

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
            .color_format = .r8_unorm,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
            .blend_state = null,
        });
    }
};
