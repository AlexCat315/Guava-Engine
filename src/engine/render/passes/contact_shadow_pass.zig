const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const render_graph = @import("../render_graph.zig");

/// Contact shadow pass
///
/// Two binding sets:
///   Set 0 — Depth texture (sampled)
///   Set 1 — ContactShadow params (uniform buffer: projection, view, light dir, resolution, etc.)
pub const ContactShadowPass = struct {
    pub const ContactShadowParams = extern struct {
        projection: [16]f32 = std.mem.zeroes([16]f32),
        inv_projection: [16]f32 = std.mem.zeroes([16]f32),
        view: [16]f32 = std.mem.zeroes([16]f32),
        light_direction: [4]f32 = .{ 0.3, -0.9, -0.2, 0.0 },
        resolution: [2]f32 = .{ 1.0, 1.0 },
        max_distance: f32 = 0.5,
        thickness: f32 = 0.1,
        intensity: f32 = 0.7,
        bias: f32 = 0.01,
        num_steps: i32 = 16,
        padding: f32 = 0,
    };

    pub const LayoutIds = struct {
        depth_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const depth_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "contact_shadow_depth_layout",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "contact_shadow_uniform_layout",
        });

        return .{
            .depth_layout = depth_layout,
            .uniform_layout = uniform_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: ContactShadowParams,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.depth_layout,
            layouts.uniform_layout,
        });

        const depth_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "contact_shadow_depth",
        });
        defer device.destroyTexture(depth_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(ContactShadowParams),
            .usage = .{ .uniform = true },
            .label = "contact_shadow_params",
        });
        defer device.destroyBuffer(uniform_buf);

        const depth_set = try device.createBindingSetCached(layouts.depth_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = depth_tex } }},
            .label = "contact_shadow_depth_set",
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "contact_shadow_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, depth_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, uniform_set);

        _ = params;

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        try render_graph.RenderGraph.encodeBarrierTransition(
            &cmd,
            input_resource_id,
            .depth_write,
            .shader_read,
            .graphics,
            .graphics,
        );

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = depth_set.id });
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
