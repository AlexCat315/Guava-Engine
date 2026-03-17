const std = @import("std");
const handles = @import("../assets/handles.zig");
const material_mod = @import("../assets/material_resource.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const texture_mod = @import("../assets/texture_resource.zig");
const math = @import("../math/mat4.zig");
const vec3 = @import("../math/vec3.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

pub const DrawStats = struct {
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,

    pub fn add(self: *DrawStats, other: DrawStats) void {
        self.draw_calls += other.draw_calls;
        self.triangles_drawn += other.triangles_drawn;
    }
};

pub const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
};

pub const BasePassUniforms = extern struct {
    base_color_factor: [4]f32,
    camera_world_position: [4]f32,
    light_direction: [4]f32,
    light_color_intensity: [4]f32,
    point_light_position_radius: [4]f32,
    point_light_color_intensity: [4]f32,
    ambient_color: [4]f32,
};

pub const DrawItem = struct {
    entity_id: scene_mod.EntityId,
    pickable: bool,
    vertex_buffer: rhi_mod.Buffer,
    index_buffer: rhi_mod.Buffer,
    index_count: u32,
    bind_group: rhi_mod.BindGroup,
    base_color_factor: [4]f32,
    model: [16]f32,
};

pub const PreparedScene = struct {
    allocator: std.mem.Allocator,
    view_projection: [16]f32,
    camera_world_position: [4]f32,
    light_direction: [4]f32,
    light_color_intensity: [4]f32,
    point_light_position_radius: [4]f32,
    point_light_color_intensity: [4]f32,
    ambient_color: [4]f32,
    items: []DrawItem,

    pub fn deinit(self: *PreparedScene) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const CameraState = struct {
    transform: components.Transform,
    camera: components.Camera,
};

const LightState = struct {
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
};

const PointLightState = struct {
    position: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
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
    bind_group: rhi_mod.BindGroup,
    base_color_factor: [4]f32,
};

const fallback_white_bgra = [_]u8{
    0xFF, 0xFF, 0xFF, 0xFF,
};

pub const MeshSceneCache = struct {
    allocator: std.mem.Allocator,
    meshes: std.ArrayList(CachedMesh) = .empty,
    textures: std.ArrayList(CachedTexture) = .empty,
    materials: std.ArrayList(CachedMaterial) = .empty,
    fallback_texture: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,
    fallback_bind_group: ?rhi_mod.BindGroup = null,

    pub fn init(allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) !MeshSceneCache {
        var cache = MeshSceneCache{
            .allocator = allocator,
        };
        try cache.createFallbackResources(device);
        return cache;
    }

    pub fn deinit(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) void {
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

    pub fn invalidateMaterialResources(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) void {
        for (self.materials.items) |*material| {
            device.releaseBindGroup(&material.bind_group);
        }
        self.materials.deinit(self.allocator);
        self.materials = .empty;

        for (self.textures.items) |*texture| {
            device.releaseTexture(&texture.texture);
        }
        self.textures.deinit(self.allocator);
        self.textures = .empty;
    }

    pub fn prepareScene(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        scene: *const scene_mod.Scene,
        render_width: u32,
        render_height: u32,
    ) !PreparedScene {
        const camera_state = chooseCamera(scene);
        const aspect_ratio = if (render_height == 0)
            1.0
        else
            @as(f32, @floatFromInt(render_width)) / @as(f32, @floatFromInt(render_height));
        const view_projection = math.mul(
            math.projectionForCamera(camera_state.camera, aspect_ratio),
            math.viewMatrix(camera_state.transform),
        );
        const main_light = chooseMainLight(scene);
        const point_light = choosePointLight(scene);

        var items = std.ArrayList(DrawItem).empty;
        defer items.deinit(self.allocator);

        for (scene.entities.items) |entity| {
            if (!entity.visible) {
                continue;
            }
            const mesh_component = entity.mesh orelse continue;
            const mesh_handle = mesh_component.handle orelse continue;
            const mesh = scene.resources.mesh(mesh_handle) orelse continue;
            if (mesh.primitive_type != .triangle_list) {
                continue;
            }
            const world_transform = scene.worldTransform(entity.id) orelse entity.transform;

            const gpu_mesh = try self.ensureMesh(device, mesh_handle, mesh);
            const material_state = try self.resolveMaterial(device, scene, entity.material);

            try items.append(self.allocator, .{
                .entity_id = entity.id,
                .pickable = !entity.editor_only,
                .vertex_buffer = gpu_mesh.vertex_buffer,
                .index_buffer = gpu_mesh.index_buffer,
                .index_count = gpu_mesh.index_count,
                .bind_group = material_state.bind_group,
                .base_color_factor = material_state.base_color_factor,
                .model = math.transformMatrix(world_transform),
            });
        }

        return .{
            .allocator = self.allocator,
            .view_projection = view_projection,
            .camera_world_position = .{
                camera_state.transform.translation[0],
                camera_state.transform.translation[1],
                camera_state.transform.translation[2],
                1.0,
            },
            .light_direction = .{
                main_light.direction[0],
                main_light.direction[1],
                main_light.direction[2],
                0.0,
            },
            .light_color_intensity = .{
                main_light.color[0],
                main_light.color[1],
                main_light.color[2],
                main_light.intensity,
            },
            .point_light_position_radius = .{
                point_light.position[0],
                point_light.position[1],
                point_light.position[2],
                point_light.range,
            },
            .point_light_color_intensity = .{
                point_light.color[0],
                point_light.color[1],
                point_light.color[2],
                point_light.intensity,
            },
            .ambient_color = .{ 0.14, 0.15, 0.18, 1.0 },
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    pub fn defaultSelectionEntity(self: *MeshSceneCache, scene: *const scene_mod.Scene) ?scene_mod.EntityId {
        _ = self;
        if (scene.findEntityByName("Spinner")) |entity| {
            return entity.id;
        }
        for (scene.entities.items) |entity| {
            if (entity.editor_only) {
                continue;
            }
            if (entity.mesh != null) {
                return entity.id;
            }
        }
        return null;
    }

    fn createFallbackResources(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) !void {
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
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.MeshHandle,
        mesh: *const mesh_mod.MeshResource,
    ) !CachedMesh {
        for (self.meshes.items) |cached| {
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

        const cached = CachedMesh{
            .handle = handle,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .index_count = @intCast(mesh.indices.len),
            .primitive_type = mesh.primitive_type,
        };
        try self.meshes.append(self.allocator, cached);
        return cached;
    }

    fn ensureTexture(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.TextureHandle,
        texture: *const texture_mod.TextureResource,
    ) !rhi_mod.Texture {
        for (self.textures.items) |cached| {
            if (cached.handle == handle) {
                return cached.texture;
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
        return gpu_texture;
    }

    fn ensureMaterial(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.MaterialHandle,
        material: *const material_mod.MaterialResource,
        scene: *const scene_mod.Scene,
    ) !?rhi_mod.BindGroup {
        for (self.materials.items) |cached| {
            if (cached.handle == handle) {
                return cached.bind_group;
            }
        }

        const texture_handle = if (material.base_color_texture) |value| value else return null;
        const texture = scene.resources.texture(texture_handle) orelse return null;
        const gpu_texture = try self.ensureTexture(device, texture_handle, texture);

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = &gpu_texture,
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
        return bind_group;
    }

    fn resolveMaterial(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        scene: *const scene_mod.Scene,
        material_component: ?components.Material,
    ) !MaterialState {
        var state = MaterialState{
            .bind_group = self.fallback_bind_group.?,
            .base_color_factor = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
        };

        const material_value = material_component orelse return state;
        state.base_color_factor = material_value.base_color_factor;

        const material_handle = material_value.handle orelse return state;
        const material = scene.resources.material(material_handle) orelse return state;
        state.base_color_factor = material.base_color_factor;

        if (try self.ensureMaterial(device, material_handle, material, scene)) |bind_group| {
            state.bind_group = bind_group;
        }
        return state;
    }
};

fn chooseCamera(scene: *const scene_mod.Scene) CameraState {
    var fallback: ?CameraState = null;

    for (scene.entities.items) |entity| {
        const camera = entity.camera orelse continue;
        const world_transform = scene.worldTransform(entity.id) orelse entity.transform;
        const candidate: CameraState = .{
            .transform = world_transform,
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

fn chooseMainLight(scene: *const scene_mod.Scene) LightState {
    for (scene.entities.items) |entity| {
        if (!entity.visible) {
            continue;
        }
        const light = entity.light orelse continue;
        if (light.kind != .directional) {
            continue;
        }
        const world_transform = scene.worldTransform(entity.id) orelse entity.transform;

        return .{
            .direction = forwardFromEuler(world_transform.rotation_euler),
            .color = light.color,
            .intensity = light.intensity,
        };
    }

    return .{
        .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }),
        .color = .{ 1.0, 0.98, 0.92 },
        .intensity = 1.6,
    };
}

fn choosePointLight(scene: *const scene_mod.Scene) PointLightState {
    for (scene.entities.items) |entity| {
        if (!entity.visible) {
            continue;
        }
        const light = entity.light orelse continue;
        if (light.kind != .point) {
            continue;
        }
        const world_transform = scene.worldTransform(entity.id) orelse entity.transform;

        return .{
            .position = world_transform.translation,
            .color = light.color,
            .intensity = light.intensity,
            .range = light.range,
        };
    }

    return .{
        .position = .{ 0.0, 0.0, 0.0 },
        .color = .{ 1.0, 0.95, 0.9 },
        .intensity = 0.0,
        .range = 1.0,
    };
}

fn forwardFromEuler(rotation_euler: components.Vec3) [3]f32 {
    return vec3.forwardFromAngles(rotation_euler[1], rotation_euler[0]);
}
