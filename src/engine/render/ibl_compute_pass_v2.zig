const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// IBL compute pass migrated to RHI v2.
///
/// Two compute sub-passes:
///   1. BRDF LUT generation — 1 storage texture output
///   2. Irradiance convolution — 1 input texture + 1 sampler + 1 storage texture output
///
/// BRDF sub-pass sets:
///   Set 0 — Output storage texture (storage_write)
///   Set 1 — BRDFParams (uniform buffer: size, sample_count)
///
/// Irradiance sub-pass sets:
///   Set 0 — Input environment map (sampled texture)
///   Set 1 — Linear sampler
///   Set 2 — Output storage texture (storage_write)
///   Set 3 — IrradianceParams (uniform buffer: output_size, sample_count)
pub const IBLComputePassV2 = struct {
    pub const BRDFParams = extern struct {
        size: u32 = 256,
        sample_count: u32 = 1024,
        padding: [2]f32 = .{ 0, 0 },
    };

    pub const IrradianceParams = extern struct {
        output_size: u32 = 64,
        sample_count: u32 = 2048,
        padding: [2]f32 = .{ 0, 0 },
    };

    pub const BRDFLayoutIds = struct {
        output_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub const IrradianceLayoutIds = struct {
        env_map_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
        output_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createBRDFLayouts(device: *rhi.Device) !BRDFLayoutIds {
        const output_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .storage_texture,
                .stage = .compute,
            }},
            .label = "ibl_v2_brdf_output",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .compute,
            }},
            .label = "ibl_v2_brdf_uniform",
        });

        return .{
            .output_layout = output_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn createIrradianceLayouts(device: *rhi.Device) !IrradianceLayoutIds {
        const env_map_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .compute,
            }},
            .label = "ibl_v2_irr_env_map",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .compute,
            }},
            .label = "ibl_v2_irr_sampler",
        });

        const output_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .storage_texture,
                .stage = .compute,
            }},
            .label = "ibl_v2_irr_output",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .compute,
            }},
            .label = "ibl_v2_irr_uniform",
        });

        return .{
            .env_map_layout = env_map_layout,
            .sampler_layout = sampler_layout,
            .output_layout = output_layout,
            .uniform_layout = uniform_layout,
        };
    }

    /// Generate BRDF LUT via compute dispatch.
    pub fn executeBRDF(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        params: BRDFParams,
    ) !void {
        const layouts = try createBRDFLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.output_layout,
            layouts.uniform_layout,
        });

        const output_tex = try device.createTexture(.{
            .width = params.size,
            .height = params.size,
            .format = .rgba16_float,
            .usage = .{ .storage_write = true },
            .label = "ibl_v2_brdf_lut",
        });
        defer device.destroyTexture(output_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(BRDFParams),
            .usage = .{ .uniform = true },
            .label = "ibl_v2_brdf_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const output_set = try device.createBindingSetCached(layouts.output_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .storage_texture = output_tex } }},
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, output_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginComputePass(.{});
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = output_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = uniform_set.id });
        try cmd.encodeDispatch(.{
            .x = (params.size + 7) / 8,
            .y = (params.size + 7) / 8,
            .z = 1,
        });
        try cmd.encodeEndComputePass();

        try device.submitCommandBuffer(.compute, &cmd, .{});
    }

    /// Convolve environment map into diffuse irradiance map via compute dispatch.
    pub fn executeIrradiance(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        params: IrradianceParams,
    ) !void {
        const layouts = try createIrradianceLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.env_map_layout,
            layouts.sampler_layout,
            layouts.output_layout,
            layouts.uniform_layout,
        });

        const env_tex = try device.createTexture(.{
            .width = 512,
            .height = 256,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "ibl_v2_env_map",
        });
        defer device.destroyTexture(env_tex);

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        defer device.destroySampler(sampler);

        const output_tex = try device.createTexture(.{
            .width = params.output_size,
            .height = params.output_size,
            .format = .rgba16_float,
            .usage = .{ .storage_write = true },
            .label = "ibl_v2_irradiance_out",
        });
        defer device.destroyTexture(output_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(IrradianceParams),
            .usage = .{ .uniform = true },
            .label = "ibl_v2_irr_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const env_set = try device.createBindingSetCached(layouts.env_map_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = env_tex } }},
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = sampler } }},
        });
        const output_set = try device.createBindingSetCached(layouts.output_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .storage_texture = output_tex } }},
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, env_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, output_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 3, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginComputePass(.{});
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = env_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = output_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 3, .set_id = uniform_set.id });
        try cmd.encodeDispatch(.{
            .x = (params.output_size + 7) / 8,
            .y = (params.output_size + 7) / 8,
            .z = 1,
        });
        try cmd.encodeEndComputePass();

        try device.submitCommandBuffer(.compute, &cmd, .{});
    }
};
