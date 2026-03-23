const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const command_buffer = @import("../rhi/command_buffer.zig");

/// Base pass (main PBR shading) migrated to RHI v2.
///
/// Geometry pass — full PBR+IBL+CSM lighting for opaque & transparent meshes.
///
/// Binding layout (10 sets):
///   Set 0 — VertexUniforms (uniform buffer: view_projection, model, skinning)
///   Set 1 — BasePassUniforms (uniform buffer: material, lighting, shadow, IBL params)
///   Set 2 — Material textures (5 textures: base_color, metallic_roughness, normal, occlusion, emissive)
///   Set 3 — Texture sampler
///   Set 4 — CSM shadow maps (4 cascade depth textures)
///   Set 5 — Shadow sampler (comparison)
///   Set 6 — IBL irradiance map (cube texture)
///   Set 7 — IBL prefiltered env map (cube texture)
///   Set 8 — IBL BRDF LUT (2D texture)
///   Set 9 — IBL sampler
pub const BasePassV2 = struct {
    pub const max_skin_joints: u32 = 64;
    pub const csm_cascade_count: u32 = 4;
    pub const max_directional_lights: u32 = 4;
    pub const max_point_lights: u32 = 16;

    pub const VertexUniforms = extern struct {
        view_projection: [16]f32 = std.mem.zeroes([16]f32),
        model: [16]f32 = std.mem.zeroes([16]f32),
        skinning_meta: [4]u32 = .{ 0, 0, 0, 0 },
        skin_matrices: [max_skin_joints][16]f32 = std.mem.zeroes([max_skin_joints][16]f32),
    };

    pub const BasePassUniforms = extern struct {
        base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        emissive_factor: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
        pbr_factors: [4]f32 = .{ 0.0, 0.5, 0.5, 1.0 },
        has_textures: [4]u32 = .{ 0, 0, 0, 0 },
        camera_world_position: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        dir_light_directions: [max_directional_lights][4]f32 = std.mem.zeroes([max_directional_lights][4]f32),
        dir_light_colors: [max_directional_lights][4]f32 = std.mem.zeroes([max_directional_lights][4]f32),
        light_space_matrix: [16]f32 = std.mem.zeroes([16]f32),
        point_light_positions: [max_point_lights][4]f32 = std.mem.zeroes([max_point_lights][4]f32),
        point_light_colors: [max_point_lights][4]f32 = std.mem.zeroes([max_point_lights][4]f32),
        light_counts: [4]u32 = .{ 0, 0, 0, 0 },
        ambient_color: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
        shadow_params: [4]f32 = .{ 0.005, 0.0, 0.0, 0.0 },
        ibl_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
        cascade_matrices: [csm_cascade_count][16]f32 = std.mem.zeroes([csm_cascade_count][16]f32),
        cascade_splits: [4]f32 = .{ 10.0, 25.0, 50.0, 100.0 },
        view_matrix: [16]f32 = std.mem.zeroes([16]f32),
    };

    pub const LayoutIds = struct {
        vertex_uniform_layout: rhi.BindingLayout,
        fragment_uniform_layout: rhi.BindingLayout,
        material_texture_layout: rhi.BindingLayout,
        texture_sampler_layout: rhi.BindingLayout,
        csm_shadow_layout: rhi.BindingLayout,
        shadow_sampler_layout: rhi.BindingLayout,
        ibl_irradiance_layout: rhi.BindingLayout,
        ibl_prefiltered_layout: rhi.BindingLayout,
        ibl_brdf_layout: rhi.BindingLayout,
        ibl_sampler_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const vertex_uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .vertex,
            }},
            .label = "base_pass_v2_vtx_uniform",
        });

        const fragment_uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_frag_uniform",
        });

        const material_texture_layout = try device.createBindingLayout(.{
            .entries = &.{
                .{ .slot = 0, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 1, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 2, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 3, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 4, .binding_type = .texture, .stage = .fragment },
            },
            .label = "base_pass_v2_material_textures",
        });

        const texture_sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_tex_sampler",
        });

        const csm_shadow_layout = try device.createBindingLayout(.{
            .entries = &.{
                .{ .slot = 0, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 1, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 2, .binding_type = .texture, .stage = .fragment },
                .{ .slot = 3, .binding_type = .texture, .stage = .fragment },
            },
            .label = "base_pass_v2_csm_shadows",
        });

        const shadow_sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_shadow_sampler",
        });

        const ibl_irradiance_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_ibl_irradiance",
        });

        const ibl_prefiltered_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_ibl_prefiltered",
        });

        const ibl_brdf_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_ibl_brdf",
        });

        const ibl_sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "base_pass_v2_ibl_sampler",
        });

        return .{
            .vertex_uniform_layout = vertex_uniform_layout,
            .fragment_uniform_layout = fragment_uniform_layout,
            .material_texture_layout = material_texture_layout,
            .texture_sampler_layout = texture_sampler_layout,
            .csm_shadow_layout = csm_shadow_layout,
            .shadow_sampler_layout = shadow_sampler_layout,
            .ibl_irradiance_layout = ibl_irradiance_layout,
            .ibl_prefiltered_layout = ibl_prefiltered_layout,
            .ibl_brdf_layout = ibl_brdf_layout,
            .ibl_sampler_layout = ibl_sampler_layout,
        };
    }

    /// Encode a single mesh draw for the base pass with full PBR lighting.
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        color_target_id: u32,
        depth_target_id: u32,
        pipeline_id: u32,
        vertex_buffer_id: u32,
        index_buffer_id: u32,
        index_count: u32,
        vertex_params: VertexUniforms,
        fragment_params: BasePassUniforms,
    ) !void {
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.vertex_uniform_layout,
            layouts.fragment_uniform_layout,
            layouts.material_texture_layout,
            layouts.texture_sampler_layout,
            layouts.csm_shadow_layout,
            layouts.shadow_sampler_layout,
            layouts.ibl_irradiance_layout,
            layouts.ibl_prefiltered_layout,
            layouts.ibl_brdf_layout,
            layouts.ibl_sampler_layout,
        });

        // -- Uniform buffers --
        const vertex_buf = try device.createBuffer(.{
            .size = @sizeOf(VertexUniforms),
            .usage = .{ .uniform = true },
            .label = "base_pass_v2_vtx_params",
        });
        defer device.destroyBuffer(vertex_buf);

        const fragment_buf = try device.createBuffer(.{
            .size = @sizeOf(BasePassUniforms),
            .usage = .{ .uniform = true },
            .label = "base_pass_v2_frag_params",
        });
        defer device.destroyBuffer(fragment_buf);

        try device.uploadBufferData(vertex_buf, 0, std.mem.asBytes(&vertex_params));
        try device.uploadBufferData(fragment_buf, 0, std.mem.asBytes(&fragment_params));

        // -- Material textures (5: base_color, mr, normal, occlusion, emissive) --
        var material_textures: [5]rhi.Texture = undefined;
        for (&material_textures) |*t| {
            t.* = try device.createTexture(.{
                .width = 1,
                .height = 1,
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true },
            });
        }
        defer for (&material_textures) |t| device.destroyTexture(t);

        const texture_sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
        });
        defer device.destroySampler(texture_sampler);

        // -- CSM shadow maps (4 cascade depth textures) --
        var csm_textures: [csm_cascade_count]rhi.Texture = undefined;
        for (&csm_textures) |*t| {
            t.* = try device.createTexture(.{
                .width = 1,
                .height = 1,
                .format = .d32_float,
                .usage = .{ .sampled = true },
            });
        }
        defer for (&csm_textures) |t| device.destroyTexture(t);

        const shadow_sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
        });
        defer device.destroySampler(shadow_sampler);

        // -- IBL textures --
        const ibl_irradiance = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .dimension = .cube,
            .layers = 6,
        });
        defer device.destroyTexture(ibl_irradiance);

        const ibl_prefiltered = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .dimension = .cube,
            .layers = 6,
        });
        defer device.destroyTexture(ibl_prefiltered);

        const ibl_brdf = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
        });
        defer device.destroyTexture(ibl_brdf);

        const ibl_sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        defer device.destroySampler(ibl_sampler);

        // -- Create binding sets --
        const vertex_set = try device.createBindingSetCached(layouts.vertex_uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = vertex_buf } }},
        });
        const fragment_set = try device.createBindingSetCached(layouts.fragment_uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = fragment_buf } }},
        });
        const material_set = try device.createBindingSetCached(layouts.material_texture_layout, .{
            .entries = &.{
                .{ .slot = 0, .resource = .{ .texture = material_textures[0] } },
                .{ .slot = 1, .resource = .{ .texture = material_textures[1] } },
                .{ .slot = 2, .resource = .{ .texture = material_textures[2] } },
                .{ .slot = 3, .resource = .{ .texture = material_textures[3] } },
                .{ .slot = 4, .resource = .{ .texture = material_textures[4] } },
            },
        });
        const tex_sampler_set = try device.createBindingSetCached(layouts.texture_sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = texture_sampler } }},
        });
        const csm_set = try device.createBindingSetCached(layouts.csm_shadow_layout, .{
            .entries = &.{
                .{ .slot = 0, .resource = .{ .texture = csm_textures[0] } },
                .{ .slot = 1, .resource = .{ .texture = csm_textures[1] } },
                .{ .slot = 2, .resource = .{ .texture = csm_textures[2] } },
                .{ .slot = 3, .resource = .{ .texture = csm_textures[3] } },
            },
        });
        const shadow_sampler_set = try device.createBindingSetCached(layouts.shadow_sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = shadow_sampler } }},
        });
        const irradiance_set = try device.createBindingSetCached(layouts.ibl_irradiance_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = ibl_irradiance } }},
        });
        const prefiltered_set = try device.createBindingSetCached(layouts.ibl_prefiltered_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = ibl_prefiltered } }},
        });
        const brdf_set = try device.createBindingSetCached(layouts.ibl_brdf_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = ibl_brdf } }},
        });
        const ibl_sampler_set = try device.createBindingSetCached(layouts.ibl_sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = ibl_sampler } }},
        });

        // -- Validate all slots --
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, vertex_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, fragment_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, material_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 3, tex_sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 4, csm_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 5, shadow_sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 6, irradiance_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 7, prefiltered_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 8, brdf_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 9, ibl_sampler_set);

        // -- Encode draw --
        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = color_target_id,
            .depth_target_id = depth_target_id,
            .clear_mask = 0x3,
        });
        try cmd.encodeSetPipeline(.{ .pipeline_id = pipeline_id });
        try cmd.encodeSetVertexBuffer(.{ .slot = 0, .buffer_id = vertex_buffer_id, .offset = 0 });
        try cmd.encodeSetIndexBuffer(.{ .buffer_id = index_buffer_id, .offset = 0, .format = 1 });
        for (0..10) |slot| {
            const set_id: u32 = switch (slot) {
                0 => vertex_set.id,
                1 => fragment_set.id,
                2 => material_set.id,
                3 => tex_sampler_set.id,
                4 => csm_set.id,
                5 => shadow_sampler_set.id,
                6 => irradiance_set.id,
                7 => prefiltered_set.id,
                8 => brdf_set.id,
                9 => ibl_sampler_set.id,
                else => unreachable,
            };
            try cmd.encodeSetBindingSet(.{ .slot = @intCast(slot), .set_id = set_id });
        }
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
