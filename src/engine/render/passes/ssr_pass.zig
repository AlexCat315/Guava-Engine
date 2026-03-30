const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const render_graph = @import("../render_graph.zig");

/// Screen-Space Reflections pass
///
/// Binding layout: 4 sets
///   Set 0 — Color texture (sampled)
///   Set 1 — Depth texture (sampled)
///   Set 2 — Normal texture (sampled)
///   Set 3 — Uniform buffer (SSRParams)
pub const SSRPass = struct {
    pub const SSRParams = extern struct {
        projection: [16]f32 = std.mem.zeroes([16]f32),
        inv_projection: [16]f32 = std.mem.zeroes([16]f32),
        view: [16]f32 = std.mem.zeroes([16]f32),
        inv_view: [16]f32 = std.mem.zeroes([16]f32),
        resolution: [2]f32 = .{ 1.0, 1.0 },
        ray_step: f32 = 0.1,
        ray_max_distance: f32 = 100.0,
        ray_thickness: f32 = 0.5,
        intensity: f32 = 0.5,
        fade_distance: f32 = 10.0,
        edge_fade: f32 = 0.1,
        stride: f32 = 4.0,
        stride_z_cutoff: f32 = 50.0,
        padding: [2]f32 = .{ 0.0, 0.0 },
    };

    pub const LayoutIds = struct {
        color_layout: rhi.BindingLayout,
        depth_layout: rhi.BindingLayout,
        normal_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const color_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "ssr_color",
        });

        const depth_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "ssr_depth",
        });

        const normal_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "ssr_normal",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "ssr_uniform",
        });

        return .{
            .color_layout = color_layout,
            .depth_layout = depth_layout,
            .normal_layout = normal_layout,
            .uniform_layout = uniform_layout,
        };
    }

    /// Encode and submit the SSR pass via command buffer.
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: SSRParams,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.color_layout,
            layouts.depth_layout,
            layouts.normal_layout,
            layouts.uniform_layout,
        });

        const color_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "ssr_color_tex",
        });
        defer device.destroyTexture(color_tex);

        const depth_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "ssr_depth_tex",
        });
        defer device.destroyTexture(depth_tex);

        const normal_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "ssr_normal_tex",
        });
        defer device.destroyTexture(normal_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(SSRParams),
            .usage = .{ .uniform = true },
            .label = "ssr_params",
        });
        defer device.destroyBuffer(uniform_buf);

        const color_set = try device.createBindingSetCached(layouts.color_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = color_tex } }},
            .label = "ssr_color_set",
        });
        const depth_set = try device.createBindingSetCached(layouts.depth_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = depth_tex } }},
            .label = "ssr_depth_set",
        });
        const normal_set = try device.createBindingSetCached(layouts.normal_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = normal_tex } }},
            .label = "ssr_normal_set",
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "ssr_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, color_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, depth_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, normal_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 3, uniform_set);

        _ = params;

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        try render_graph.RenderGraph.encodeBarrierTransition(
            &cmd,
            input_resource_id,
            .texture,
            .render_target,
            .shader_read,
            .graphics,
            .graphics,
        );

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });

        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = color_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = depth_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = normal_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 3, .set_id = uniform_set.id });

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
