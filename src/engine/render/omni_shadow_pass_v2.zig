const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Omnidirectional shadow pass migrated to RHI v2.
///
/// Renders point-light shadow cubemap — 6 face passes (depth only).
///   Set 0 — VertexUniforms (uniform buffer: face_view_projection, model, skinning)
///
/// Each of the 6 cubemap faces gets its own render pass with a face-specific
/// view_projection (90° perspective × lookAt toward +X/-X/+Y/-Y/+Z/-Z).
pub const OmniShadowPassV2 = struct {
    pub const cubemap_faces: u32 = 6;

    pub const VertexUniforms = extern struct {
        view_projection: [16]f32 = std.mem.zeroes([16]f32),
        model: [16]f32 = std.mem.zeroes([16]f32),
        skinning_meta: [4]u32 = .{ 0, 0, 0, 0 },
        skin_matrices: [64][16]f32 = std.mem.zeroes([64][16]f32),
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
            .label = "omni_shadow_v2_uniform",
        });

        return .{ .uniform_layout = uniform_layout };
    }

    /// Encode all 6 cubemap face passes for a single point light.
    /// face_view_projections: array of 6 mat4 (one per cubemap face).
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        cube_depth_target_id: u32,
        pipeline_id: u32,
        vertex_buffer_id: u32,
        index_buffer_id: u32,
        index_count: u32,
        face_view_projections: [cubemap_faces][16]f32,
        model: [16]f32,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.uniform_layout,
        });

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        for (0..cubemap_faces) |face| {
            var params = VertexUniforms{
                .view_projection = face_view_projections[face],
                .model = model,
            };

            const uniform_buf = try device.createBuffer(.{
                .size = @sizeOf(VertexUniforms),
                .usage = .{ .uniform = true },
                .label = "omni_shadow_v2_face_params",
            });
            defer device.destroyBuffer(uniform_buf);

            try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

            const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
                .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            });

            try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, uniform_set);

            // Each face renders to a different slice of the cubemap depth target.
            // We encode face index as color_target_id bits for backend dispatch.
            const face_target_id = cube_depth_target_id + @as(u32, @intCast(face));

            try cmd.encodeBeginRenderPass(.{
                .color_target_id = 0,
                .depth_target_id = face_target_id,
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
        }

        try device.submitCommandBuffer(.graphics, &cmd, .{});
    }
};
