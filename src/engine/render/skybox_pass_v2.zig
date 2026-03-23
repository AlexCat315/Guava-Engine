const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Skybox pass migrated to RHI v2.
///
/// Fullscreen pass — renders environment cubemap behind scene geometry.
///   Set 0 — SkyboxUniforms (uniform buffer: projection, view, camera_pos, inv_vp)
///   Set 1 — Environment map texture (sampled, cube dimension)
///   Set 2 — Sampler (linear, clamp-to-edge)
pub const SkyboxPassV2 = struct {
    pub const SkyboxUniforms = extern struct {
        projection: [16]f32 = std.mem.zeroes([16]f32),
        view: [16]f32 = std.mem.zeroes([16]f32),
        camera_position: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        inv_vp: [16]f32 = std.mem.zeroes([16]f32),
    };

    pub const LayoutIds = struct {
        uniform_layout: rhi.BindingLayout,
        env_map_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .vertex,
            }},
            .label = "skybox_v2_uniform",
        });

        const env_map_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "skybox_v2_env_map",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "skybox_v2_sampler",
        });

        return .{
            .uniform_layout = uniform_layout,
            .env_map_layout = env_map_layout,
            .sampler_layout = sampler_layout,
        };
    }

    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        depth_target_id: u32,
        params: SkyboxUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.uniform_layout,
            layouts.env_map_layout,
            layouts.sampler_layout,
        });

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(SkyboxUniforms),
            .usage = .{ .uniform = true },
            .label = "skybox_v2_params",
        });
        defer device.destroyBuffer(uniform_buf);

        try device.uploadBufferData(uniform_buf, 0, std.mem.asBytes(&params));

        const env_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .dimension = .cube,
            .layers = 6,
            .label = "skybox_v2_env_map",
        });
        defer device.destroyTexture(env_tex);

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        defer device.destroySampler(sampler);

        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
        });
        const env_set = try device.createBindingSetCached(layouts.env_map_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = env_tex } }},
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = sampler } }},
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, uniform_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, env_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, sampler_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = depth_target_id,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = uniform_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = env_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = sampler_set.id });
        // Fullscreen triangle — 3 vertices, no vertex buffer needed
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
