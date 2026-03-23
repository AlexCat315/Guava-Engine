const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Outline pass migrated to RHI v2.
///
/// Fullscreen pass — reads id_texture, draws outline for selected entities.
///   Set 0 — ID texture (sampled)
///   Set 1 — Sampler (nearest)
///   Set 2 — OutlineUniforms (uniform buffer: selected_entity_color, outline_color)
pub const OutlinePassV2 = struct {
    pub const OutlineUniforms = extern struct {
        selected_entity_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        outline_color: [4]f32 = .{ 1.0, 0.72, 0.18, 1.0 },
    };

    pub const LayoutIds = struct {
        id_texture_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const id_texture_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "outline_v2_id_texture",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "outline_v2_sampler",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "outline_v2_uniform",
        });

        return .{
            .id_texture_layout = id_texture_layout,
            .sampler_layout = sampler_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        pipeline_id: u32,
        params: OutlineUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.id_texture_layout,
            layouts.sampler_layout,
            layouts.uniform_layout,
        });

        const id_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true },
            .label = "outline_v2_id_tex",
        });
        defer device.destroyTexture(id_tex);

        const sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
        });
        defer device.destroySampler(sampler);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(OutlineUniforms),
            .usage = .{ .uniform = true },
            .label = "outline_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const id_set = try device.createBindingSetCached(layouts.id_texture_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = id_tex } }},
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = sampler } }},
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, id_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetPipeline(.{ .pipeline_id = pipeline_id });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = id_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = uniform_set.id });
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
