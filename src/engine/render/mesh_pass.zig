const std = @import("std");
const generated_shaders = @import("../generated/shaders.zig");
const handles = @import("../assets/handles.zig");
const material_mod = @import("../assets/material_resource.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const texture_mod = @import("../assets/texture_resource.zig");
const math = @import("../math/mat4.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

pub const DrawStats = struct {
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,
};

const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
};

const FragmentUniforms = extern struct {
    base_color_factor: [4]f32,
};

const CameraState = struct {
    transform: components.Transform,
    camera: components.Camera,
};

const CachedMesh = struct {
    handle: handles.MeshHandle,
    vertex_buffer: rhi_mod.Buffer,
    index_buffer: rhi_mod.Buffer,
    index_count: u32,
    primitive_type: rhi_types.PrimitiveType,
};

const CachedTexture = struct {
    handle: handles.TextureHandle,
    texture: rhi_mod.Texture,
};

const CachedMaterial = struct {
    handle: handles.MaterialHandle,
    bind_group: rhi_mod.BindGroup,
};

const MaterialState = struct {
    bind_group: *const rhi_mod.BindGroup,
    base_color_factor: [4]f32,
};

const fallback_white_bgra = [_]u8{
    0xFF, 0xFF, 0xFF, 0xFF,
};

pub const MeshPass = struct {
    allocator: std.mem.Allocator,
    supported: bool = false,
    meshes: std.ArrayList(CachedMesh) = .empty,
    textures: std.ArrayList(CachedTexture) = .empty,
    materials: std.ArrayList(CachedMaterial) = .empty,
    fallback_texture: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,
    fallback_bind_group: ?rhi_mod.BindGroup = null,
    vertex_shader: ?rhi_mod.ShaderModule = null,
    fragment_shader: ?rhi_mod.ShaderModule = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,

    pub fn init(allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) !MeshPass {
        var pass = MeshPass{
            .allocator = allocator,
        };

        const program = generated_shaders.findProgram("mesh") orelse return pass;
        const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return pass;
        const fragment_variant = program.stageForBackend(device.api, .fragment) orelse return pass;

        try pass.createFallbackResources(device);
        errdefer pass.deinit(device);

        pass.vertex_shader = try device.createShaderModule(.{
            .code = vertex_variant.code,
            .stage = .vertex,
            .format = vertex_variant.format,
            .entry_point = vertex_variant.entry_point,
            .num_samplers = vertex_variant.reflection.num_samplers,
            .num_storage_textures = vertex_variant.reflection.num_storage_textures,
            .num_storage_buffers = vertex_variant.reflection.num_storage_buffers,
            .num_uniform_buffers = vertex_variant.reflection.num_uniform_buffers,
        });

        pass.fragment_shader = try device.createShaderModule(.{
            .code = fragment_variant.code,
            .stage = .fragment,
            .format = fragment_variant.format,
            .entry_point = fragment_variant.entry_point,
            .num_samplers = fragment_variant.reflection.num_samplers,
            .num_storage_textures = fragment_variant.reflection.num_storage_textures,
            .num_storage_buffers = fragment_variant.reflection.num_storage_buffers,
            .num_uniform_buffers = fragment_variant.reflection.num_uniform_buffers,
        });

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(mesh_mod.Vertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_mod.Vertex, "position"),
            },
            .{
                .location = 1,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_mod.Vertex, "color"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(mesh_mod.Vertex, "uv"),
            },
        };

        pass.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &pass.vertex_shader.?,
            .fragment_shader = &pass.fragment_shader.?,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });

        pass.supported = true;
        return pass;
    }

    pub fn deinit(self: *MeshPass, device: *rhi_mod.RhiDevice) void {
        for (self.materials.items) |*material| {
            device.releaseBindGroup(&material.bind_group);
        }
        self.materials.deinit(self.allocator);

        for (self.textures.items) |*texture| {
            device.releaseTexture(&texture.texture);
        }
        self.textures.deinit(self.allocator);

        for (self.meshes.items) |*mesh| {
            device.releaseBuffer(&mesh.index_buffer);
            device.releaseBuffer(&mesh.vertex_buffer);
        }
        self.meshes.deinit(self.allocator);

        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.fragment_shader) |*shader| {
            device.releaseShaderModule(shader);
        }
        if (self.vertex_shader) |*shader| {
            device.releaseShaderModule(shader);
        }
        if (self.fallback_bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.fallback_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const MeshPass) bool {
        return self.supported and self.pipeline != null;
    }

    pub fn draw(
        self: *MeshPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        scene: *const scene_mod.Scene,
    ) !DrawStats {
        var stats = DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const camera_state = chooseCamera(scene);
        const aspect_ratio = if (frame.height == 0)
            1.0
        else
            @as(f32, @floatFromInt(frame.width)) / @as(f32, @floatFromInt(frame.height));
        const view_projection = math.mul(
            math.projectionForCamera(camera_state.camera, aspect_ratio),
            math.viewMatrix(camera_state.transform),
        );

        device.bindGraphicsPipeline(pass, &self.pipeline.?);

        for (scene.entities.items) |entity| {
            const mesh_component = entity.mesh orelse continue;
            const mesh_handle = mesh_component.handle orelse continue;
            const mesh = scene.resources.mesh(mesh_handle) orelse continue;
            if (mesh.primitive_type != .triangle_list) {
                continue;
            }

            const gpu_mesh = try self.ensureMesh(device, mesh_handle, mesh);
            device.bindVertexBuffer(pass, 0, &gpu_mesh.vertex_buffer, 0);
            device.bindIndexBuffer(pass, &gpu_mesh.index_buffer, .u32, 0);

            const material_state = try self.resolveMaterial(device, scene, entity.material);
            device.bindGroup(pass, material_state.bind_group);

            var vertex_uniforms = VertexUniforms{
                .view_projection = view_projection,
                .model = math.transformMatrix(entity.transform),
            };
            var fragment_uniforms = FragmentUniforms{
                .base_color_factor = material_state.base_color_factor,
            };

            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
            device.drawIndexedPrimitives(pass, gpu_mesh.index_count, 1, 0, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += gpu_mesh.index_count / 3;
        }

        return stats;
    }

    fn createFallbackResources(self: *MeshPass, device: *rhi_mod.RhiDevice) !void {
        self.fallback_texture = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.sampler,
        });
        try device.uploadTextureData(&self.fallback_texture.?, fallback_white_bgra[0..], 1, 1);

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = &self.fallback_texture.?,
                .sampler = &self.sampler.?,
            },
        };
        self.fallback_bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
    }

    fn ensureMesh(
        self: *MeshPass,
        device: *rhi_mod.RhiDevice,
        handle: handles.MeshHandle,
        mesh: *const mesh_mod.MeshResource,
    ) !*CachedMesh {
        for (self.meshes.items) |*cached| {
            if (cached.handle == handle) {
                return cached;
            }
        }

        const vertex_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(mesh_mod.Vertex) * mesh.vertices.len),
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer {
            var copy = vertex_buffer;
            device.releaseBuffer(&copy);
        }
        try device.uploadBufferData(&vertex_buffer, std.mem.sliceAsBytes(mesh.vertices));

        const index_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(u32) * mesh.indices.len),
            .usage = rhi_types.BufferUsage.index,
        });
        errdefer {
            var copy = index_buffer;
            device.releaseBuffer(&copy);
        }
        try device.uploadBufferData(&index_buffer, std.mem.sliceAsBytes(mesh.indices));

        try self.meshes.append(self.allocator, .{
            .handle = handle,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .index_count = @intCast(mesh.indices.len),
            .primitive_type = mesh.primitive_type,
        });
        return &self.meshes.items[self.meshes.items.len - 1];
    }

    fn ensureTexture(
        self: *MeshPass,
        device: *rhi_mod.RhiDevice,
        handle: handles.TextureHandle,
        texture: *const texture_mod.TextureResource,
    ) !*CachedTexture {
        for (self.textures.items) |*cached| {
            if (cached.handle == handle) {
                return cached;
            }
        }

        const gpu_texture = try device.createTexture(.{
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .usage = rhi_types.TextureUsage.sampler,
        });
        errdefer {
            var copy = gpu_texture;
            device.releaseTexture(&copy);
        }
        try device.uploadTextureData(&gpu_texture, texture.pixels, texture.width, texture.height);

        try self.textures.append(self.allocator, .{
            .handle = handle,
            .texture = gpu_texture,
        });
        return &self.textures.items[self.textures.items.len - 1];
    }

    fn ensureMaterial(
        self: *MeshPass,
        device: *rhi_mod.RhiDevice,
        handle: handles.MaterialHandle,
        material: *const material_mod.MaterialResource,
        scene: *const scene_mod.Scene,
    ) !?*CachedMaterial {
        for (self.materials.items) |*cached| {
            if (cached.handle == handle) {
                return cached;
            }
        }

        const texture_handle = if (material.base_color_texture) |value| value else return null;
        const texture = scene.resources.texture(texture_handle) orelse return null;
        const gpu_texture = try self.ensureTexture(device, texture_handle, texture);

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = &gpu_texture.texture,
                .sampler = &self.sampler.?,
            },
        };
        const bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });

        try self.materials.append(self.allocator, .{
            .handle = handle,
            .bind_group = bind_group,
        });
        return &self.materials.items[self.materials.items.len - 1];
    }

    fn resolveMaterial(
        self: *MeshPass,
        device: *rhi_mod.RhiDevice,
        scene: *const scene_mod.Scene,
        material_component: ?components.Material,
    ) !MaterialState {
        var state = MaterialState{
            .bind_group = &self.fallback_bind_group.?,
            .base_color_factor = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
        };

        const material_value = material_component orelse return state;
        state.base_color_factor = material_value.base_color_factor;

        const material_handle = material_value.handle orelse return state;
        const material = scene.resources.material(material_handle) orelse return state;
        state.base_color_factor = material.base_color_factor;

        if (try self.ensureMaterial(device, material_handle, material, scene)) |cached| {
            state.bind_group = &cached.bind_group;
        }
        return state;
    }
};

fn chooseCamera(scene: *const scene_mod.Scene) CameraState {
    var fallback: ?CameraState = null;

    for (scene.entities.items) |entity| {
        const camera = entity.camera orelse continue;
        const candidate: CameraState = .{
            .transform = entity.transform,
            .camera = camera,
        };

        if (camera.is_primary) {
            return candidate;
        }
        if (fallback == null) {
            fallback = candidate;
        }
    }

    return fallback orelse .{
        .transform = .{
            .translation = .{ 0.0, 1.5, 5.0 },
        },
        .camera = .{ .is_primary = true },
    };
}
