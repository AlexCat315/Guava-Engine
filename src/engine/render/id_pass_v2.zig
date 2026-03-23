const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// ID pass migrated to RHI v2.
///
/// Geometry pass — renders each mesh with entity ID encoded as color.
///   Set 0 — VertexUniforms (uniform buffer: view_projection, model, skinning)
///   Set 1 — IdPassUniforms (uniform buffer: entity_color)
///
/// Output renders to bgra8_unorm id_texture for mouse picking.
pub const IdPassV2 = struct {
    pub const VertexUniforms = extern struct {
        view_projection: [16]f32 = std.mem.zeroes([16]f32),
        model: [16]f32 = std.mem.zeroes([16]f32),
        skinning_meta: [4]u32 = .{ 0, 0, 0, 0 },
        skin_matrices: [64][16]f32 = std.mem.zeroes([64][16]f32),
    };

    pub const IdPassUniforms = extern struct {
        entity_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    };

    pub const LayoutIds = struct {
        vertex_uniform_layout: rhi.BindingLayout,
        fragment_uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const vertex_uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .vertex,
            }},
            .label = "id_pass_v2_vertex_uniform",
        });

        const fragment_uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "id_pass_v2_fragment_uniform",
        });

        return .{
            .vertex_uniform_layout = vertex_uniform_layout,
            .fragment_uniform_layout = fragment_uniform_layout,
        };
    }

    /// Encode a single mesh draw for the ID pass.
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        id_texture_target_id: u32,
        depth_target_id: u32,
        pipeline_id: u32,
        vertex_buffer_id: u32,
        index_buffer_id: u32,
        index_count: u32,
        vertex_params: VertexUniforms,
        fragment_params: IdPassUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.vertex_uniform_layout,
            layouts.fragment_uniform_layout,
        });

        const vertex_buf = try device.createBuffer(.{
            .size = @sizeOf(VertexUniforms),
            .usage = .{ .uniform = true },
            .label = "id_pass_v2_vertex_params",
        });
        defer device.destroyBuffer(vertex_buf);

        const fragment_buf = try device.createBuffer(.{
            .size = @sizeOf(IdPassUniforms),
            .usage = .{ .uniform = true },
            .label = "id_pass_v2_fragment_params",
        });
        defer device.destroyBuffer(fragment_buf);

        try device.uploadBufferData(vertex_buf, 0, std.mem.asBytes(&vertex_params));
        try device.uploadBufferData(fragment_buf, 0, std.mem.asBytes(&fragment_params));

        const vertex_set = try device.createBindingSetCached(layouts.vertex_uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = vertex_buf } }},
        });
        const fragment_set = try device.createBindingSetCached(layouts.fragment_uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = fragment_buf } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, vertex_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, fragment_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = id_texture_target_id,
            .depth_target_id = depth_target_id,
            .clear_mask = 0x3, // clear both color + depth
        });
        try cmd.encodeSetPipeline(.{ .pipeline_id = pipeline_id });
        try cmd.encodeSetVertexBuffer(.{ .slot = 0, .buffer_id = vertex_buffer_id, .offset = 0 });
        try cmd.encodeSetIndexBuffer(.{ .buffer_id = index_buffer_id, .offset = 0, .format = 1 });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = vertex_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = fragment_set.id });
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
