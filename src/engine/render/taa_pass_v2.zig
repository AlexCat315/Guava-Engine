const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// TAA (Temporal Anti-Aliasing) pass migrated to RHI v2.
///
/// Fullscreen pass — blends current frame with history using motion vectors.
///   Set 0 — Current color texture (sampled)
///   Set 1 — History texture (sampled)
///   Set 2 — Velocity texture (sampled)
///   Set 3 — Depth texture (sampled)
///   Set 4 — Sampler (linear, clamp)
///   Set 5 — TAAUniforms (uniform buffer)
pub const TAAPassV2 = struct {
    pub const TAAUniforms = extern struct {
        projection: [16]f32 = std.mem.zeroes([16]f32),
        inv_projection: [16]f32 = std.mem.zeroes([16]f32),
        view: [16]f32 = std.mem.zeroes([16]f32),
        prev_view: [16]f32 = std.mem.zeroes([16]f32),
        resolution: [2]f32 = .{ 1.0, 1.0 },
        jitter: [2]f32 = .{ 0.0, 0.0 },
        blend_factor: f32 = 0.1,
        motion_blur_scale: f32 = 1.0,
        feedback_min: f32 = 0.88,
        feedback_max: f32 = 0.97,
        padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
    };

    pub const LayoutIds = struct {
        color_layout: rhi.BindingLayout,
        history_layout: rhi.BindingLayout,
        velocity_layout: rhi.BindingLayout,
        depth_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const color_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "taa_v2_color",
        });

        const history_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "taa_v2_history",
        });

        const velocity_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "taa_v2_velocity",
        });

        const depth_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "taa_v2_depth",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "taa_v2_sampler",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "taa_v2_uniform",
        });

        return .{
            .color_layout = color_layout,
            .history_layout = history_layout,
            .velocity_layout = velocity_layout,
            .depth_layout = depth_layout,
            .sampler_layout = sampler_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        params: TAAUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.color_layout,
            layouts.history_layout,
            layouts.velocity_layout,
            layouts.depth_layout,
            layouts.sampler_layout,
            layouts.uniform_layout,
        });

        const color_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "taa_v2_color_tex",
        });
        defer device.destroyTexture(color_tex);

        const history_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "taa_v2_history_tex",
        });
        defer device.destroyTexture(history_tex);

        const velocity_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "taa_v2_velocity_tex",
        });
        defer device.destroyTexture(velocity_tex);

        const depth_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "taa_v2_depth_tex",
        });
        defer device.destroyTexture(depth_tex);

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        defer device.destroySampler(sampler);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(TAAUniforms),
            .usage = .{ .uniform = true },
            .label = "taa_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const color_set = try device.createBindingSetCached(layouts.color_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = color_tex } }},
        });
        const history_set = try device.createBindingSetCached(layouts.history_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = history_tex } }},
        });
        const velocity_set = try device.createBindingSetCached(layouts.velocity_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = velocity_tex } }},
        });
        const depth_set = try device.createBindingSetCached(layouts.depth_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = depth_tex } }},
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = sampler } }},
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, color_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, history_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, velocity_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 3, depth_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 4, sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 5, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = color_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = history_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = velocity_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 3, .set_id = depth_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 4, .set_id = sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 5, .set_id = uniform_set.id });
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
