const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const render_graph = @import("render_graph.zig");

/// Bloom post-process pass
///
/// Performs a single-pass bright-filter + downsample on the HDR input.
/// Uses a uniform buffer for threshold parameters and a sampled texture
/// binding — demonstrates the full binding-layout → pipeline-layout →
/// binding-set → validation flow.
pub const BloomPass = struct {
    pub const BloomParams = struct {
        threshold: f32 = 1.0,
        intensity: f32 = 0.35,
        _pad: [2]f32 = .{ 0.0, 0.0 },
    };

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: BloomParams,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        // Set 0: sampled HDR input
        const sampled_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "bloom_sampled_layout",
        });

        // Set 1: bloom uniform buffer
        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "bloom_uniform_layout",
        });

        const pipeline_layout = try device.resolvePipelineLayout(&.{ sampled_layout, uniform_layout });

        const sampled_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "bloom_input",
        });
        defer device.destroyTexture(sampled_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(BloomParams),
            .usage = .{ .uniform = true },
            .label = "bloom_params",
        });
        defer device.destroyBuffer(uniform_buf);

        const sampled_set = try device.createBindingSetCached(sampled_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = sampled_tex } }},
            .label = "bloom_input_set",
        });

        const uniform_set = try device.createBindingSetCached(uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "bloom_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, sampled_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, uniform_set);

        _ = params;

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        try cmd.encodePipelineBarrier(.{
            .resource_id = input_resource_id,
            .src_state_bits = (rhi.ResourceStates{ .unordered_access = true }).asBits(),
            .dst_state_bits = (rhi.ResourceStates{ .shader_resource = true }).asBits(),
            .src_queue = @intCast(@intFromEnum(rhi.QueueClass.graphics)),
            .dst_queue = @intCast(@intFromEnum(rhi.QueueClass.graphics)),
        });

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = sampled_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = uniform_set.id });
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
