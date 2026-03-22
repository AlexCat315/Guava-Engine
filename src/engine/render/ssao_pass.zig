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

pub const SSAOUniforms = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    view: [16]f32 = std.mem.zeroes([16]f32),
    inv_view: [16]f32 = std.mem.zeroes([16]f32),
    resolution: [2]f32 = .{ 1.0, 1.0 },
    radius: f32 = 0.5,
    bias: f32 = 0.025,
    intensity: f32 = 1.0,
    power: f32 = 2.0,
    kernel_size: u32 = 16,
    noise_scale: [2]f32 = .{ 1.0, 1.0 },
    padding: [2]f32 = .{ 0.0, 0.0 },
};

pub const SSAOPass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    noise_sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_depth_handle: usize = 0,
    bound_normal_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    noise_texture: ?rhi_mod.Texture = null,
    kernel: [64][3]f32 = undefined,

    pub fn init(device: *rhi_mod.RhiDevice) !SSAOPass {
        var pass = SSAOPass{};
        try pass.createResources(device);
        pass.generateKernel();
        return pass;
    }

    pub fn deinit(self: *SSAOPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.noise_sampler) |*sampler| {
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
        if (self.noise_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const SSAOPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null and self.noise_texture != null;
    }

    pub fn syncTextures(
        self: *SSAOPass,
        device: *rhi_mod.RhiDevice,
        depth_texture: *const rhi_mod.Texture,
        normal_texture: ?*const rhi_mod.Texture,
    ) !void {
        const depth_handle = @intFromPtr(depth_texture.raw);
        const normal_handle = if (normal_texture) |nt| @intFromPtr(nt.raw) else 0;

        if (self.bind_group != null and self.bound_depth_handle == depth_handle and self.bound_normal_handle == normal_handle) {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        var bindings: [4]rhi_mod.TextureSamplerBinding = undefined;
        var binding_count: usize = 0;

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

        bindings[binding_count] = .{
            .texture = &self.noise_texture.?,
            .sampler = &self.noise_sampler.?,
        };
        binding_count += 1;

        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..binding_count],
        });
        self.bound_depth_handle = depth_handle;
        self.bound_normal_handle = normal_handle;
    }

    pub fn draw(
        self: *SSAOPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: SSAOUniforms,
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

    fn generateKernel(self: *SSAOPass) void {
        const kernel_size = 64;
        var rng = std.Random.DefaultPrng.init(42);

        for (0..kernel_size) |i| {
            const rand_x = rng.random().float(f32) * 2.0 - 1.0;
            const rand_y = rng.random().float(f32) * 2.0 - 1.0;
            const rand_z = rng.random().float(f32);

            const len = @sqrt(rand_x * rand_x + rand_y * rand_y + rand_z * rand_z);
            var sample: [3]f32 = .{ rand_x / len, rand_y / len, rand_z };

            const scale = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(kernel_size));
            const lerp = 0.1 + scale * scale * 0.9;
            sample[0] *= lerp;
            sample[1] *= lerp;
            sample[2] *= lerp;

            self.kernel[i] = sample;
        }
    }

    fn createResources(self: *SSAOPass, device: *rhi_mod.RhiDevice) !void {
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

        self.noise_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });
        errdefer if (self.noise_sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        var noise_data: [16 * 4]u8 = undefined;
        var rng = std.Random.DefaultPrng.init(123);
        for (0..16) |i| {
            const rand_x = rng.random().float(f32) * 2.0 - 1.0;
            const rand_y = rng.random().float(f32) * 2.0 - 1.0;
            const len = @sqrt(rand_x * rand_x + rand_y * rand_y);
            const nx: f32 = if (len > 0.001) rand_x / len else 0.0;
            const ny: f32 = if (len > 0.001) rand_y / len else 0.0;

            const base = i * 4;
            noise_data[base + 0] = @intFromFloat(@round((nx * 0.5 + 0.5) * 255.0));
            noise_data[base + 1] = @intFromFloat(@round((ny * 0.5 + 0.5) * 255.0));
            noise_data[base + 2] = 0;
            noise_data[base + 3] = 255;
        }

        self.noise_texture = try device.createTexture(.{
            .width = 4,
            .height = 4,
            .format = .rgba8_unorm,
            .usage = rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.noise_texture) |*texture| {
            device.releaseTexture(texture);
        };
        try device.uploadTextureData(&self.noise_texture.?, &noise_data, 4, 4);

        self.stages = try shader_support.loadProgramStages(device, "ssao");
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
        });
    }
};
