const std = @import("std");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const shader_support = @import("shader_support.zig");
const ssao_pass_mod = @import("ssao_pass.zig");

pub const SSAOComputePass = struct {
    pipeline: ?rhi_mod.ComputePipeline = null,
    sampler: ?rhi_mod.Sampler = null,
    noise_sampler: ?rhi_mod.Sampler = null,
    noise_texture: ?rhi_mod.Texture = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SSAOComputePass {
        var pass = SSAOComputePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SSAOComputePass, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline) |*p| {
            device.releaseComputePipeline(p);
        }
        if (self.sampler) |*s| {
            device.releaseSampler(s);
        }
        if (self.noise_sampler) |*s| {
            device.releaseSampler(s);
        }
        if (self.noise_texture) |*t| {
            device.releaseTexture(t);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const SSAOComputePass) bool {
        return self.pipeline != null and self.sampler != null and self.noise_texture != null;
    }

    pub fn dispatch(
        self: *SSAOComputePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        depth_texture: *const rhi_mod.Texture,
        output_texture: *const rhi_mod.Texture,
        uniforms: ssao_pass_mod.SSAOUniforms,
    ) void {
        if (!self.isReady()) return;

        // Begin compute pass with the output texture as read-write storage
        const compute_pass = device.beginComputePass(
            frame,
            &.{output_texture},
            &.{},
        ) catch return;

        device.bindComputePipeline(compute_pass, &self.pipeline.?);

        // Bind samplers: slot 0 = depth, slot 1 = noise
        device.bindComputeSamplers(compute_pass, 0, &.{
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
            .{ .texture = &self.noise_texture.?, .sampler = &self.noise_sampler.? },
        });

        // Push uniforms
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&uniforms));

        // Dispatch: ceil(width/8) x ceil(height/8) workgroups
        const group_x = (output_texture.desc.width + 7) / 8;
        const group_y = (output_texture.desc.height + 7) / 8;
        device.dispatchCompute(compute_pass, group_x, group_y, 1);

        device.endComputePass(compute_pass);
    }

    fn createResources(self: *SSAOComputePass, device: *rhi_mod.RhiDevice) !void {
        self.pipeline = try shader_support.loadComputePipelineRW(device, "ssao_compute", 1, 0);
        errdefer if (self.pipeline) |*p| {
            device.releaseComputePipeline(p);
            self.pipeline = null;
        };

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        self.noise_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });

        // Generate noise texture (4x4 rotation vectors)
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
        try device.uploadTextureData(&self.noise_texture.?, &noise_data, 4, 4);
    }
};
