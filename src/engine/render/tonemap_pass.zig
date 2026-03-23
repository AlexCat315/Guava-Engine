const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const render_graph = @import("render_graph.zig");

/// Tonemap post-process pass
///
/// Three binding sets:
///   Set 0 — HDR scene color (sampled texture)
///   Set 1 — Bloom buffer    (sampled texture)
///   Set 2 — Tonemap params  (uniform buffer: exposure, bloom, color grading, LUT)
pub const TonemapPass = struct {
    pub const TonemapParams = extern struct {
        exposure_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
        bloom_params: [4]f32 = .{ 0.0, 0.35, 0.0, 0.0 },
        color_grading_params: [4]f32 = .{ 0.0, 1.0, 1.0, 1.0 },
        lut_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
    };

    /// Returns the three binding layout IDs created for this pass (for constraint wiring).
    pub const LayoutIds = struct {
        hdr_layout: rhi.BindingLayout,
        bloom_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const hdr_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "tonemap_hdr_layout",
        });

        const bloom_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "tonemap_bloom_layout",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "tonemap_uniform_layout",
        });

        return .{
            .hdr_layout = hdr_layout,
            .bloom_layout = bloom_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: TonemapParams,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.hdr_layout,
            layouts.bloom_layout,
            layouts.uniform_layout,
        });

        // Placeholder resources
        const hdr_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "tonemap_hdr_in",
        });
        defer device.destroyTexture(hdr_tex);

        const bloom_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "tonemap_bloom_in",
        });
        defer device.destroyTexture(bloom_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(TonemapParams),
            .usage = .{ .uniform = true },
            .label = "tonemap_params",
        });
        defer device.destroyBuffer(uniform_buf);

        const hdr_set = try device.createBindingSetCached(layouts.hdr_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = hdr_tex } }},
            .label = "tonemap_hdr_set",
        });
        const bloom_set = try device.createBindingSetCached(layouts.bloom_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = bloom_tex } }},
            .label = "tonemap_bloom_set",
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "tonemap_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, hdr_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, bloom_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, uniform_set);

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
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = hdr_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = bloom_set.id });
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
