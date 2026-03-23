const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Gizmo pass migrated to RHI v2.
///
/// Geometry pass — line primitives for editor gizmos (translate/rotate/scale).
///   Set 0 — GizmoUniforms (uniform buffer: view_projection, model, color)
///
/// Uses line_list topology via set_pipeline + set_vertex_buffer + draw_indexed.
pub const GizmoPassV2 = struct {
    pub const GizmoUniforms = extern struct {
        view_projection: [16]f32 = std.mem.zeroes([16]f32),
        model: [16]f32 = std.mem.zeroes([16]f32),
        color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
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
            .label = "gizmo_v2_uniform",
        });

        return .{ .uniform_layout = uniform_layout };
    }

    /// Encode a single gizmo draw (one axis/ring/arrow segment).
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        pipeline_id: u32,
        vertex_buffer_id: u32,
        vertex_count: u32,
        params: GizmoUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.uniform_layout,
        });

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(GizmoUniforms),
            .usage = .{ .uniform = true },
            .label = "gizmo_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "gizmo_v2_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, uniform_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = 0, // gizmo: no depth
            .clear_mask = 0,
        });
        try cmd.encodeSetPipeline(.{ .pipeline_id = pipeline_id });
        try cmd.encodeSetVertexBuffer(.{ .slot = 0, .buffer_id = vertex_buffer_id, .offset = 0 });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = uniform_set.id });
        // Line list — draw vertex_count as indexed (2 per line segment)
        try cmd.encodeDrawIndexed(.{
            .index_count = vertex_count,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        try device.submitCommandBuffer(.graphics, &cmd, .{});
    }
};
