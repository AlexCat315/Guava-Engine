const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// RT shadow composite pass migrated to RHI v2.
///
/// Fullscreen pass — multiplicative blend of shadow mask onto HDR color buffer.
///   Set 0 — Shadow mask texture (sampled)
///   Set 1 — Sampler (linear, clamp)
///   Set 2 — ShadowCompositeUniforms (uniform buffer: shadow_params)
///
/// Blend mode: src_color * dst_color (multiply).
pub const RtShadowCompositePassV2 = struct {
    pub const ShadowCompositeUniforms = extern struct {
        shadow_params: [4]f32 = .{ 0.85, 0.15, 0.0, 0.0 },
    };

    pub const LayoutIds = struct {
        mask_texture_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const mask_texture_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "rt_shadow_comp_v2_mask",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "rt_shadow_comp_v2_sampler",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "rt_shadow_comp_v2_uniform",
        });

        return .{
            .mask_texture_layout = mask_texture_layout,
            .sampler_layout = sampler_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        shadow_strength: f32,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.mask_texture_layout,
            layouts.sampler_layout,
            layouts.uniform_layout,
        });

        const mask_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true },
            .label = "rt_shadow_comp_v2_mask_tex",
        });
        defer device.destroyTexture(mask_tex);

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        defer device.destroySampler(sampler);

        const params = ShadowCompositeUniforms{
            .shadow_params = .{ shadow_strength, 0.05, 0.0, 0.0 },
        };
        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(ShadowCompositeUniforms),
            .usage = .{ .uniform = true },
            .label = "rt_shadow_comp_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const mask_set = try device.createBindingSetCached(layouts.mask_texture_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = mask_tex } }},
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = sampler } }},
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, mask_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = mask_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = uniform_set.id });
        // Fullscreen triangle
        try cmd.encodeDrawIndexed(.{
            .index_count = 3,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        try device.submitCommandBuffer(.graphics, &cmd, .{});
    }
};
