const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const shader_support = @import("shader_support.zig");
const render_types = @import("types.zig");
const vec3 = @import("../math/vec3.zig");
const render_log = std.log.scoped(.viewport_render);

var g_logged_metal_binding_mode: bool = false;

pub const DrawTarget = enum {
    hdr,
    ldr,
};

pub const DrawPhase = enum {
    opaque_pass,
    transparent_pass,
    all,
};

pub const DrawSettings = struct {
    render_mode: render_types.EditorViewportRenderMode = .textured,
    target: DrawTarget = .hdr,
    phase: DrawPhase = .all,
    blend_opaque: bool = false,
    alpha_multiplier: f32 = 1.0,
    preview_tint_strength: f32 = 0.0,
    override_base_color: ?[4]f32 = null,
};

pub const BasePass = struct {
    fill_pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    fill_pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    ghost_fill_pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    ghost_fill_pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    transparent_fill_pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    transparent_fill_pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    wireframe_pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    wireframe_pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !BasePass {
        var pass = BasePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *BasePass, device: *rhi_mod.RhiDevice) void {
        if (self.wireframe_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.wireframe_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.ghost_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.ghost_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.transparent_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.transparent_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const BasePass) bool {
        return self.fill_pipeline_hdr != null and
            self.fill_pipeline_ldr != null and
            self.ghost_fill_pipeline_hdr != null and
            self.ghost_fill_pipeline_ldr != null and
            self.transparent_fill_pipeline_hdr != null and
            self.transparent_fill_pipeline_ldr != null and
            self.wireframe_pipeline_hdr != null and
            self.wireframe_pipeline_ldr != null;
    }

    pub fn draw(
        self: *BasePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        settings: DrawSettings,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }
        const use_metal_combined_bindings = device.api == .metal;
        if (use_metal_combined_bindings and !g_logged_metal_binding_mode) {
            render_log.info("base pass using Metal combined sampler binding path", .{});
            g_logged_metal_binding_mode = true;
        }

        const is_wireframe = settings.render_mode == .wireframe;
        const opaque_pipeline = switch (settings.render_mode) {
            .wireframe => self.pipelineFor(settings.target, .wireframe, false),
            .textured, .unlit => self.pipelineFor(
                settings.target,
                if (settings.blend_opaque) .ghost_fill else .fill,
                false,
            ),
        };
        const transparent_pipeline = if (is_wireframe)
            opaque_pipeline
        else
            self.pipelineFor(settings.target, .fill, true);

        const main_light = if (prepared_scene.lights.directional_lights.len > 0)
            prepared_scene.lights.directional_lights[0]
        else
            mesh_pass_mod.DirectionalLightBlock{ .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }), .color = .{ 1.0, 0.98, 0.92 }, .intensity = 1.6 };

        const point_light = if (prepared_scene.lights.point_lights.len > 0)
            prepared_scene.lights.point_lights[0]
        else
            mesh_pass_mod.PointLightBlock{ .position = .{ 0.0, 0.0, 0.0 }, .color = .{ 1.0, 0.95, 0.9 }, .intensity = 0.0, .range = 1.0 };

        var shadow_bg: ?rhi_mod.BindGroup = null;
        defer if (shadow_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        var ibl_bg: ?rhi_mod.BindGroup = null;
        defer if (ibl_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        if (!use_metal_combined_bindings) {
            if (prepared_scene.shadow_map) |sm| {
                const shadow_bindings = [_]rhi_mod.TextureSamplerBinding{
                    .{ .texture = sm, .sampler = prepared_scene.shadow_sampler.? },
                };
                shadow_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = shadow_bindings[0..],
                    .slot_offset = 5,
                });
                device.bindGroup(pass, &shadow_bg.?);
            }

            if (prepared_scene.irradiance_map != null and
                prepared_scene.prefiltered_env_map != null and
                prepared_scene.brdf_lut != null and
                prepared_scene.environment_map != null and
                prepared_scene.texture_sampler != null)
            {
                const ibl_bindings = [_]rhi_mod.TextureSamplerBinding{
                    .{ .texture = prepared_scene.irradiance_map.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.prefiltered_env_map.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.brdf_lut.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.environment_map.?, .sampler = prepared_scene.texture_sampler.? },
                };
                ibl_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = ibl_bindings[0..],
                    .slot_offset = 6,
                });
                device.bindGroup(pass, &ibl_bg.?);
            }
        }

        switch (settings.phase) {
            .opaque_pass => {
                device.bindGraphicsPipeline(pass, opaque_pipeline);
                stats.add(try self.drawMeshList(
                    device,
                    frame,
                    pass,
                    prepared_scene,
                    prepared_scene.opaque_meshes,
                    settings,
                    main_light,
                    point_light,
                    use_metal_combined_bindings,
                    false,
                ));
            },
            .transparent_pass => {
                device.bindGraphicsPipeline(pass, transparent_pipeline);
                stats.add(try self.drawMeshList(
                    device,
                    frame,
                    pass,
                    prepared_scene,
                    prepared_scene.transparent_meshes,
                    settings,
                    main_light,
                    point_light,
                    use_metal_combined_bindings,
                    true,
                ));
            },
            .all => {
                if (prepared_scene.opaque_meshes.len > 0) {
                    device.bindGraphicsPipeline(pass, opaque_pipeline);
                    stats.add(try self.drawMeshList(
                        device,
                        frame,
                        pass,
                        prepared_scene,
                        prepared_scene.opaque_meshes,
                        settings,
                        main_light,
                        point_light,
                        use_metal_combined_bindings,
                        false,
                    ));
                }
                if (prepared_scene.transparent_meshes.len > 0) {
                    if (transparent_pipeline != opaque_pipeline) {
                        device.bindGraphicsPipeline(pass, transparent_pipeline);
                    }
                    stats.add(try self.drawMeshList(
                        device,
                        frame,
                        pass,
                        prepared_scene,
                        prepared_scene.transparent_meshes,
                        settings,
                        main_light,
                        point_light,
                        use_metal_combined_bindings,
                        true,
                    ));
                }
            },
        }

        return stats;
    }

    fn drawMeshList(
        self: *BasePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        items: []const mesh_pass_mod.DrawItem,
        settings: DrawSettings,
        main_light: mesh_pass_mod.DirectionalLightBlock,
        point_light: mesh_pass_mod.PointLightBlock,
        use_metal_combined_bindings: bool,
        transparent_pass: bool,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        const is_wireframe = settings.render_mode == .wireframe;

        for (items) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
                .skinning_meta = item.skinning_meta,
                .skin_matrices = item.skin_matrices,
            };
            var fragment_uniforms = self.makeFragmentUniforms(
                item,
                prepared_scene,
                settings,
                main_light,
                point_light,
                transparent_pass,
            );

            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0);
            const draw_index_buffer = if (is_wireframe) &item.wireframe_index_buffer else &item.index_buffer;
            const draw_index_count = if (is_wireframe) item.wireframe_index_count else item.index_count;
            device.bindIndexBuffer(pass, draw_index_buffer, .u32, 0);
            if (use_metal_combined_bindings) {
                const shadow_texture = prepared_scene.shadow_map orelse return error.TextureNotFound;
                const shadow_sampler = prepared_scene.shadow_sampler orelse return error.SamplerCreateFailed;
                const texture_sampler = prepared_scene.texture_sampler orelse return error.SamplerCreateFailed;
                const irradiance_map = prepared_scene.irradiance_map orelse return error.TextureNotFound;
                const prefiltered_env_map = prepared_scene.prefiltered_env_map orelse return error.TextureNotFound;
                const brdf_lut = prepared_scene.brdf_lut orelse return error.TextureNotFound;
                const environment_map = prepared_scene.environment_map orelse return error.TextureNotFound;

                const combined_bindings = [_]rhi_mod.TextureSamplerBinding{
                    .{ .texture = item.material_textures[0], .sampler = texture_sampler }, // binding 0: u_base_color_map
                    .{ .texture = item.material_textures[1], .sampler = texture_sampler }, // binding 1: u_metallic_roughness_map
                    .{ .texture = item.material_textures[2], .sampler = texture_sampler }, // binding 2: u_normal_map
                    .{ .texture = item.material_textures[3], .sampler = texture_sampler }, // binding 3: u_occlusion_map
                    .{ .texture = item.material_textures[4], .sampler = texture_sampler }, // binding 4: u_emissive_map
                    .{ .texture = shadow_texture, .sampler = shadow_sampler }, // binding 5: u_shadow_map (sampler2DShadow)
                    .{ .texture = irradiance_map, .sampler = texture_sampler }, // binding 6: u_irradiance_map
                    .{ .texture = prefiltered_env_map, .sampler = texture_sampler }, // binding 7: u_prefiltered_env_map
                    .{ .texture = brdf_lut, .sampler = texture_sampler }, // binding 8: u_brdf_lut
                    .{ .texture = environment_map, .sampler = texture_sampler }, // binding 9: u_environment_map
                };
                var combined_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = combined_bindings[0..],
                });
                defer device.releaseBindGroup(&combined_bg);
                device.bindGroup(pass, &combined_bg);
            } else {
                device.bindGroup(pass, &item.bind_group);
            }

            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
            device.drawIndexedPrimitives(pass, draw_index_count, 1, 0, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += item.index_count / 3;
        }

        return stats;
    }

    fn makeFragmentUniforms(
        self: *BasePass,
        item: mesh_pass_mod.DrawItem,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        settings: DrawSettings,
        main_light: mesh_pass_mod.DirectionalLightBlock,
        point_light: mesh_pass_mod.PointLightBlock,
        transparent_pass: bool,
    ) mesh_pass_mod.BasePassUniforms {
        _ = self;
        var fragment_uniforms = mesh_pass_mod.BasePassUniforms{
            .base_color_factor = item.base_color_factor,
            .emissive_factor = item.emissive_factor,
            .pbr_factors = item.pbr_factors,
            .has_textures = item.has_textures,
            .camera_world_position = prepared_scene.camera_world_position,
            .light_direction = .{ main_light.direction[0], main_light.direction[1], main_light.direction[2], 0.0 },
            .light_color_intensity = .{ main_light.color[0], main_light.color[1], main_light.color[2], main_light.intensity },
            .light_space_matrix = prepared_scene.light_space_matrix,
            .point_light_position_radius = .{ point_light.position[0], point_light.position[1], point_light.position[2], point_light.range },
            .point_light_color_intensity = .{ point_light.color[0], point_light.color[1], point_light.color[2], point_light.intensity },
            .ambient_color = prepared_scene.ambient_color,
            .shadow_params = .{ 0.005, 0.0, 0.0, 0.0 }, // bias
            .ibl_params = item.ibl_params,
        };

        if (settings.render_mode == .unlit) {
            fragment_uniforms.light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.point_light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 };
            fragment_uniforms.ibl_params = .{ 0.0, 0.0, 0.0, 0.0 };
        } else if (settings.render_mode == .wireframe) {
            fragment_uniforms.base_color_factor = settings.override_base_color orelse .{ 0.08, 0.08, 0.08, 1.0 };
            fragment_uniforms.emissive_factor = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.has_textures = .{ 0, 0, 0, 0 };
            fragment_uniforms.light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.point_light_color_intensity = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 };
            fragment_uniforms.ibl_params = .{ 0.0, 0.0, 0.0, 0.0 };
        }

        fragment_uniforms.pbr_factors[3] = settings.alpha_multiplier;
        if (settings.render_mode != .wireframe) {
            if (settings.override_base_color) |preview_tint| {
                fragment_uniforms.shadow_params[1] = preview_tint[0];
                fragment_uniforms.shadow_params[2] = preview_tint[1];
                fragment_uniforms.shadow_params[3] = preview_tint[2];
                fragment_uniforms.ibl_params[2] = settings.preview_tint_strength;
            }
        }

        if (transparent_pass or (settings.render_mode == .wireframe and fragment_uniforms.base_color_factor[3] < 1.0)) {
            fragment_uniforms.pbr_factors[2] = 0.0;
        }

        return fragment_uniforms;
    }

    fn createResources(self: *BasePass, device: *rhi_mod.RhiDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "mesh");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(mesh_pass_mod.GpuVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "position"),
            },
            .{
                .location = 1,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "normal"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "color"),
            },
            .{
                .location = 3,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "uv"),
            },
            .{
                .location = 4,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "joints"),
            },
            .{
                .location = 5,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "weights"),
            },
        };

        self.fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .fill, false, true);
        errdefer if (self.fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm, .fill, false, true);
        errdefer if (self.fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.ghost_fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .ghost_fill, true, true);
        errdefer if (self.ghost_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.ghost_fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm, .ghost_fill, true, true);
        errdefer if (self.ghost_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.transparent_fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .fill, true, false);
        errdefer if (self.transparent_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.transparent_fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm, .fill, true, false);
        errdefer if (self.transparent_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.wireframe_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .wireframe, true, false);
        errdefer if (self.wireframe_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.wireframe_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm, .wireframe, true, false);
    }

    const PipelineMode = enum {
        fill,
        ghost_fill,
        wireframe,
    };

    fn pipelineFor(self: *BasePass, target: DrawTarget, mode: PipelineMode, transparent: bool) *rhi_mod.GraphicsPipeline {
        return switch (mode) {
            .fill => switch (target) {
                .hdr => if (transparent) &self.transparent_fill_pipeline_hdr.? else &self.fill_pipeline_hdr.?,
                .ldr => if (transparent) &self.transparent_fill_pipeline_ldr.? else &self.fill_pipeline_ldr.?,
            },
            .ghost_fill => switch (target) {
                .hdr => &self.ghost_fill_pipeline_hdr.?,
                .ldr => &self.ghost_fill_pipeline_ldr.?,
            },
            .wireframe => switch (target) {
                .hdr => &self.wireframe_pipeline_hdr.?,
                .ldr => &self.wireframe_pipeline_ldr.?,
            },
        };
    }

    fn createPipeline(
        self: *BasePass,
        device: *rhi_mod.RhiDevice,
        vertex_layouts: []const rhi_mod.VertexBufferLayoutDesc,
        vertex_attributes: []const rhi_mod.VertexAttributeDesc,
        color_format: rhi_types.TextureFormat,
        mode: PipelineMode,
        enable_blend: bool,
        depth_write: bool,
    ) !rhi_mod.GraphicsPipeline {
        return device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts,
            .vertex_attributes = vertex_attributes,
            .color_format = color_format,
            .blend_state = if (enable_blend)
                @as(?rhi_types.ColorTargetBlendState, .{
                    .enable_blend = true,
                })
            else
                null,
            .depth_format = .d32_float,
            .primitive_type = if (mode == .wireframe) .line_list else .triangle_list,
            .fill_mode = .fill,
            .cull_mode = if (mode == .wireframe) .none else .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = depth_write,
        });
    }
};
