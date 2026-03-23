const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Shadow pass (directional light) migrated to RHI v2.
///
/// Geometry pass — depth-only with light-space transform, front-face culling.
///   Set 0 — VertexUniforms (uniform buffer: light_space_matrix, model, skinning)
///
/// Same vertex layout as depth prepass but uses light_space_matrix instead of view_projection.
pub const ShadowPassV2 = struct {
    pub const VertexUniforms = extern struct {
        light_space_matrix: [16]f32 = std.mem.zeroes([16]f32),
        model: [16]f32 = std.mem.zeroes([16]f32),
        skinning_meta: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        skin_matrices: [16 * 4]f32 = std.mem.zeroes([16 * 4]f32),
    };

    pub const LayoutIds = struct {
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .vertex,
            }},
            .label = "shadow_pass_v2_uniform",
        });

        return .{ .uniform_layout = uniform_layout };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        shadow_map_target_id: u32,
        pipeline_id: u32,
        vertex_buffer_id: u32,
        index_buffer_id: u32,
        index_count: u32,
        params: VertexUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.uniform_layout,
        });

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(VertexUniforms),
            .usage = .{ .uniform = true },
            .label = "shadow_pass_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "shadow_pass_v2_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = 0,
            .depth_target_id = shadow_map_target_id,
            .clear_mask = 0x2,
        });
        try cmd.encodeSetPipeline(.{ .pipeline_id = pipeline_id });
        try cmd.encodeSetVertexBuffer(.{ .slot = 0, .buffer_id = vertex_buffer_id, .offset = 0 });
        try cmd.encodeSetIndexBuffer(.{ .buffer_id = index_buffer_id, .offset = 0, .format = 1 });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = uniform_set.id });
        try cmd.encodeDrawIndexed(.{
            .index_count = index_count,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        try device.submitCommandBuffer(.graphics, &cmd, .{});
    }
};
