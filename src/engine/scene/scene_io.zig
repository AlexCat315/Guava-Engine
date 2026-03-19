const std = @import("std");
const asset_registry = @import("../assets/registry.zig");
const assets_handles = @import("../assets/handles.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("components.zig");
const world_mod = @import("world.zig");

const current_scene_version: u32 = 5;

const SceneHeader = struct {
    version: u32 = 1,
};

const SceneFile = struct {
    version: u32 = current_scene_version,
    scene_id: []const u8,
    asset_records: []asset_registry.AssetRecord,
    meshes: []MeshRecord,
    textures: []TextureRecord,
    materials: []MaterialRecord,
    entities: []EntityRecord,
};

const MeshRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    primitive_type: rhi_types.PrimitiveType,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const TextureRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels_hex: []const u8,
};

const MaterialRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    shading: components.ShadingModel,
    base_color_factor: [4]f32,
    base_color_texture_asset_id: ?[]const u8 = null,
};

const MeshComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    primitive: components.Primitive = .custom,
};

const MaterialComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const RigidbodyRecord = struct {
    motion_type: components.RigidbodyMotionType = .dynamic,
    mass: f32 = 1.0,
    linear_velocity: [3]f32 = .{ 0.0, 0.0, 0.0 },
    gravity_scale: f32 = 1.0,
    linear_damping: f32 = 0.04,
    allow_sleep: bool = true,
};

const BoxColliderRecord = struct {
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
    center: [3]f32 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
};

const SphereColliderRecord = struct {
    radius: f32 = 0.5,
    center: [3]f32 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
};

const MeshColliderRecord = struct {
    use_attached_mesh: bool = true,
    is_trigger: bool = false,
};

const EntityRecord = struct {
    name: []const u8,
    parent: ?u32 = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?MeshComponentRecord = null,
    rigidbody: ?RigidbodyRecord = null,
    box_collider: ?BoxColliderRecord = null,
    sphere_collider: ?SphereColliderRecord = null,
    mesh_collider: ?MeshColliderRecord = null,
    material: ?MaterialComponentRecord = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
};

const LegacySceneFile = struct {
    version: u32 = 2,
    meshes: []LegacyMeshRecord,
    textures: []LegacyTextureRecord,
    materials: []LegacyMaterialRecord,
    entities: []LegacyEntityRecord,
};

const LegacyMeshRecord = struct {
    name: []const u8,
    primitive_type: rhi_types.PrimitiveType,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const LegacyTextureRecord = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels_hex: []const u8,
};

const LegacyMaterialRecord = struct {
    name: []const u8,
    shading: components.ShadingModel,
    base_color_factor: [4]f32,
    base_color_texture: ?u32 = null,
};

const LegacyMeshComponentRecord = struct {
    resource: ?u32 = null,
    primitive: components.Primitive = .custom,
};

const LegacyMaterialComponentRecord = struct {
    resource: ?u32 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const LegacyEntityRecord = struct {
    name: []const u8,
    parent: ?u32 = null,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?LegacyMeshComponentRecord = null,
    material: ?LegacyMaterialComponentRecord = null,
    light: ?components.Light = null,
    visible: bool = true,
    editor_only: bool = false,
};

const TextureBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.TextureHandle,
};

const MaterialBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.MaterialHandle,
};

const MeshBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.MeshHandle,
};

pub fn serializeWorldAlloc(allocator: std.mem.Allocator, world: *const world_mod.World) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scene = try buildSceneFile(arena, world);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var legacy_writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = legacy_writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(scene, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

pub fn deserializeWorldFromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var header_parse = try std.json.parseFromSlice(SceneHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    switch (header_parse.value.version) {
        1, 2 => try deserializeLegacyWorldFromSlice(allocator, world, source),
        3, 4, 5 => try deserializeWorldV4FromSlice(allocator, world, source),
        else => return error.UnsupportedSceneVersion,
    }
}

pub fn saveWorldToPath(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    path: []const u8,
) !void {
    const encoded = try serializeWorldAlloc(allocator, world);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = encoded,
    });
}

pub fn loadWorldFromPath(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    path: []const u8,
) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(source);
    try deserializeWorldFromSlice(allocator, world, source);
}

fn buildSceneFile(allocator: std.mem.Allocator, world: *const world_mod.World) !SceneFile {
    var mesh_records = std.ArrayList(MeshRecord).empty;
    defer mesh_records.deinit(allocator);
    var texture_records = std.ArrayList(TextureRecord).empty;
    defer texture_records.deinit(allocator);
    var material_records = std.ArrayList(MaterialRecord).empty;
    defer material_records.deinit(allocator);
    var asset_records = std.ArrayList(asset_registry.AssetRecord).empty;
    defer asset_records.deinit(allocator);
    var entity_records = std.ArrayList(EntityRecord).empty;
    defer entity_records.deinit(allocator);

    var mesh_asset_ids = std.AutoHashMap(assets_handles.MeshHandle, []const u8).init(allocator);
    defer mesh_asset_ids.deinit();
    var texture_asset_ids = std.AutoHashMap(assets_handles.TextureHandle, []const u8).init(allocator);
    defer texture_asset_ids.deinit();
    var material_asset_ids = std.AutoHashMap(assets_handles.MaterialHandle, []const u8).init(allocator);
    defer material_asset_ids.deinit();
    var entity_indices = std.AutoHashMap(world_mod.EntityId, u32).init(allocator);
    defer entity_indices.deinit();

    var exported_entity_index: u32 = 0;
    for (world.entities.items) |entity| {
        if (entity.editor_only) {
            continue;
        }
        try entity_indices.put(entity.id, exported_entity_index);
        exported_entity_index += 1;
    }

    for (world.entities.items) |entity| {
        if (entity.editor_only) {
            continue;
        }

        const mesh_component = if (entity.mesh) |mesh|
            MeshComponentRecord{
                .asset_id = if (mesh.handle) |mesh_handle|
                    try ensureMeshRecord(
                        allocator,
                        world,
                        mesh_handle,
                        &mesh_asset_ids,
                        &mesh_records,
                        &asset_records,
                        &texture_asset_ids,
                        &texture_records,
                        &material_asset_ids,
                        &material_records,
                    )
                else
                    null,
                .primitive = mesh.primitive,
            }
        else
            null;

        const material_component = if (entity.material) |material|
            MaterialComponentRecord{
                .asset_id = if (material.handle) |material_handle|
                    try ensureMaterialRecord(
                        allocator,
                        world,
                        material_handle,
                        &material_asset_ids,
                        &material_records,
                        &asset_records,
                        &texture_asset_ids,
                        &texture_records,
                    )
                else
                    null,
                .shading = material.shading,
                .base_color_factor = material.base_color_factor,
            }
        else
            null;

        try entity_records.append(allocator, .{
            .name = entity.name,
            .parent = if (entity.parent) |parent_id| entity_indices.get(parent_id) else null,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = mesh_component,
            .rigidbody = if (entity.rigidbody) |body| .{
                .motion_type = body.motion_type,
                .mass = body.mass,
                .linear_velocity = body.linear_velocity,
                .gravity_scale = body.gravity_scale,
                .linear_damping = body.linear_damping,
                .allow_sleep = body.allow_sleep,
            } else null,
            .box_collider = if (entity.box_collider) |collider| .{
                .half_extents = collider.half_extents,
                .center = collider.center,
                .is_trigger = collider.is_trigger,
            } else null,
            .sphere_collider = if (entity.sphere_collider) |collider| .{
                .radius = collider.radius,
                .center = collider.center,
                .is_trigger = collider.is_trigger,
            } else null,
            .mesh_collider = if (entity.mesh_collider) |collider| .{
                .use_attached_mesh = collider.use_attached_mesh,
                .is_trigger = collider.is_trigger,
            } else null,
            .material = material_component,
            .light = entity.light,
            .vfx = entity.vfx,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
        });
    }

    const scene_id = try makeSceneIdAlloc(
        allocator,
        entity_records.items,
        mesh_records.items,
        material_records.items,
        texture_records.items,
    );

    return .{
        .scene_id = scene_id,
        .asset_records = try asset_records.toOwnedSlice(allocator),
        .meshes = try mesh_records.toOwnedSlice(allocator),
        .textures = try texture_records.toOwnedSlice(allocator),
        .materials = try material_records.toOwnedSlice(allocator),
        .entities = try entity_records.toOwnedSlice(allocator),
    };
}

fn deserializeWorldV4FromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(SceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 3 and scene.version != 4 and scene.version != current_scene_version) {
        return error.UnsupportedSceneVersion;
    }

    world.clear();

    var texture_bindings = std.ArrayList(TextureBinding).empty;
    defer texture_bindings.deinit(allocator);
    for (scene.textures) |texture| {
        const decoded_pixels = try decodeHexAlloc(allocator, texture.pixels_hex);
        defer allocator.free(decoded_pixels);

        const handle = try world.resources.createTexture(.{
            .name = texture.name,
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = decoded_pixels,
        });
        try bindTextureAssetFromScene(allocator, world, &scene, texture.asset_id, texture.name, handle);
        applyBuiltinTextureHandle(&world.resources, texture.name, handle);
        try texture_bindings.append(allocator, .{
            .asset_id = texture.asset_id,
            .handle = handle,
        });
    }

    var material_bindings = std.ArrayList(MaterialBinding).empty;
    defer material_bindings.deinit(allocator);
    for (scene.materials) |material| {
        const handle = try world.resources.createMaterial(.{
            .name = material.name,
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
            .base_color_texture = if (material.base_color_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
        });
        try bindMaterialAssetFromScene(allocator, world, &scene, material.asset_id, material.name, handle);
        applyBuiltinMaterialHandle(&world.resources, material.name, handle);
        try material_bindings.append(allocator, .{
            .asset_id = material.asset_id,
            .handle = handle,
        });
    }

    var mesh_bindings = std.ArrayList(MeshBinding).empty;
    defer mesh_bindings.deinit(allocator);
    for (scene.meshes) |mesh| {
        const handle = try world.resources.createMesh(.{
            .name = mesh.name,
            .vertices = mesh.vertices,
            .indices = mesh.indices,
            .primitive_type = mesh.primitive_type,
        });
        try bindMeshAssetFromScene(allocator, world, &scene, mesh.asset_id, mesh.name, handle);
        applyBuiltinMeshHandle(&world.resources, mesh.name, handle);
        try mesh_bindings.append(allocator, .{
            .asset_id = mesh.asset_id,
            .handle = handle,
        });
    }

    const entity_ids = try allocator.alloc(world_mod.EntityId, scene.entities.len);
    defer allocator.free(entity_ids);

    for (scene.entities, 0..) |entity, index| {
        entity_ids[index] = try world.createEntity(.{
            .name = entity.name,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh_component|
                .{
                    .handle = if (mesh_component.asset_id) |mesh_asset_id|
                        findMeshHandle(mesh_bindings.items, mesh_asset_id) orelse return error.MeshAssetNotFound
                    else
                        null,
                    .primitive = mesh_component.primitive,
                }
            else
                null,
            .rigidbody = if (entity.rigidbody) |body|
                .{
                    .motion_type = body.motion_type,
                    .mass = body.mass,
                    .linear_velocity = body.linear_velocity,
                    .gravity_scale = body.gravity_scale,
                    .linear_damping = body.linear_damping,
                    .allow_sleep = body.allow_sleep,
                }
            else
                null,
            .box_collider = if (entity.box_collider) |collider|
                .{
                    .half_extents = collider.half_extents,
                    .center = collider.center,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .sphere_collider = if (entity.sphere_collider) |collider|
                .{
                    .radius = collider.radius,
                    .center = collider.center,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .mesh_collider = if (entity.mesh_collider) |collider|
                .{
                    .use_attached_mesh = collider.use_attached_mesh,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .material = if (entity.material) |material_component|
                .{
                    .handle = if (material_component.asset_id) |material_asset_id|
                        findMaterialHandle(material_bindings.items, material_asset_id) orelse return error.MaterialAssetNotFound
                    else
                        null,
                    .shading = material_component.shading,
                    .base_color_factor = material_component.base_color_factor,
                }
            else
                null,
            .light = entity.light,
            .vfx = entity.vfx,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
        });
    }

    for (scene.entities, 0..) |entity, index| {
        if (entity.parent) |parent_index| {
            if (parent_index >= entity_ids.len) {
                return error.ParentIndexOutOfBounds;
            }
            _ = try world.setParentLocal(entity_ids[index], entity_ids[parent_index]);
        }
    }
}

fn deserializeLegacyWorldFromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(LegacySceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 1 and scene.version != 2) {
        return error.UnsupportedSceneVersion;
    }

    world.clear();

    const texture_handles = try allocator.alloc(assets_handles.TextureHandle, scene.textures.len);
    defer allocator.free(texture_handles);
    for (scene.textures, 0..) |texture, index| {
        const decoded_pixels = try decodeHexAlloc(allocator, texture.pixels_hex);
        defer allocator.free(decoded_pixels);

        const handle = try world.resources.createTexture(.{
            .name = texture.name,
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = decoded_pixels,
        });
        texture_handles[index] = handle;
        applyBuiltinTextureHandle(&world.resources, texture.name, handle);
    }

    const material_handles = try allocator.alloc(assets_handles.MaterialHandle, scene.materials.len);
    defer allocator.free(material_handles);
    for (scene.materials, 0..) |material, index| {
        const handle = try world.resources.createMaterial(.{
            .name = material.name,
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
            .base_color_texture = if (material.base_color_texture) |texture_index|
                texture_handles[texture_index]
            else
                null,
        });
        material_handles[index] = handle;
        applyBuiltinMaterialHandle(&world.resources, material.name, handle);
    }

    const mesh_handles = try allocator.alloc(assets_handles.MeshHandle, scene.meshes.len);
    defer allocator.free(mesh_handles);
    for (scene.meshes, 0..) |mesh, index| {
        const handle = try world.resources.createMesh(.{
            .name = mesh.name,
            .vertices = mesh.vertices,
            .indices = mesh.indices,
            .primitive_type = mesh.primitive_type,
        });
        mesh_handles[index] = handle;
        applyBuiltinMeshHandle(&world.resources, mesh.name, handle);
    }

    const entity_ids = try allocator.alloc(world_mod.EntityId, scene.entities.len);
    defer allocator.free(entity_ids);

    for (scene.entities, 0..) |entity, index| {
        entity_ids[index] = try world.createEntity(.{
            .name = entity.name,
            .local_transform = entity.transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh_component|
                .{
                    .handle = if (mesh_component.resource) |mesh_index| mesh_handles[mesh_index] else null,
                    .primitive = mesh_component.primitive,
                }
            else
                null,
            .material = if (entity.material) |material_component|
                .{
                    .handle = if (material_component.resource) |material_index| material_handles[material_index] else null,
                    .shading = material_component.shading,
                    .base_color_factor = material_component.base_color_factor,
                }
            else
                null,
            .light = entity.light,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
        });
    }

    for (scene.entities, 0..) |entity, index| {
        if (entity.parent) |parent_index| {
            if (parent_index >= entity_ids.len) {
                return error.ParentIndexOutOfBounds;
            }
            _ = try world.setParentLocal(entity_ids[index], entity_ids[parent_index]);
        }
    }
}

fn ensureMeshRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MeshHandle,
    mesh_asset_ids: *std.AutoHashMap(assets_handles.MeshHandle, []const u8),
    mesh_records: *std.ArrayList(MeshRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
    material_asset_ids: *std.AutoHashMap(assets_handles.MaterialHandle, []const u8),
    material_records: *std.ArrayList(MaterialRecord),
) ![]const u8 {
    _ = texture_asset_ids;
    _ = texture_records;
    _ = material_asset_ids;
    _ = material_records;

    if (mesh_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const mesh = world.resources.mesh(handle) orelse return error.MeshNotFound;
    const asset_record = try ensureMeshAssetRecord(allocator, world, handle, mesh);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try mesh_records.append(allocator, .{
        .asset_id = asset_id,
        .name = mesh.name,
        .primitive_type = mesh.primitive_type,
        .vertices = mesh.vertices,
        .indices = mesh.indices,
    });
    try mesh_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureMaterialRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MaterialHandle,
    material_asset_ids: *std.AutoHashMap(assets_handles.MaterialHandle, []const u8),
    material_records: *std.ArrayList(MaterialRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
) ![]const u8 {
    if (material_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const material = world.resources.material(handle) orelse return error.MaterialNotFound;
    const base_color_texture_asset_id = if (material.base_color_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;

    const asset_record = try ensureMaterialAssetRecord(allocator, world, handle, material, base_color_texture_asset_id);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try material_records.append(allocator, .{
        .asset_id = asset_id,
        .name = material.name,
        .shading = material.shading,
        .base_color_factor = material.base_color_factor,
        .base_color_texture_asset_id = base_color_texture_asset_id,
    });
    try material_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureTextureRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.TextureHandle,
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) ![]const u8 {
    if (texture_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const texture = world.resources.texture(handle) orelse return error.TextureNotFound;
    const asset_record = try ensureTextureAssetRecord(allocator, world, handle, texture);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try texture_records.append(allocator, .{
        .asset_id = asset_id,
        .name = texture.name,
        .width = texture.width,
        .height = texture.height,
        .format = texture.format,
        .pixels_hex = try encodeHexAlloc(allocator, texture.pixels),
    });
    try texture_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureSceneAssetRecord(
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    allocator: std.mem.Allocator,
    record: asset_registry.AssetRecord,
) ![]const u8 {
    for (asset_records.items) |existing| {
        if (std.mem.eql(u8, existing.id, record.id)) {
            return existing.id;
        }
    }
    try asset_records.append(allocator, record);
    return asset_records.items[asset_records.items.len - 1].id;
}

fn ensureMeshAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MeshHandle,
    mesh: *const @import("../assets/mesh_resource.zig").MeshResource,
) !asset_registry.AssetRecord {
    if (world.resources.meshAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedMeshAssetRecord(allocator, mesh, asset_id);
    }
    return makeEmbeddedMeshAssetRecord(allocator, mesh, null);
}

fn ensureMaterialAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MaterialHandle,
    material: *const @import("../assets/material_resource.zig").MaterialResource,
    texture_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    if (world.resources.materialAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedMaterialAssetRecord(allocator, material, texture_asset_id, asset_id);
    }
    return makeEmbeddedMaterialAssetRecord(allocator, material, texture_asset_id, null);
}

fn ensureTextureAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.TextureHandle,
    texture: *const @import("../assets/texture_resource.zig").TextureResource,
) !asset_registry.AssetRecord {
    if (world.resources.textureAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedTextureAssetRecord(allocator, texture, asset_id);
    }
    return makeEmbeddedTextureAssetRecord(allocator, texture, null);
}

fn makeEmbeddedMeshAssetRecord(
    allocator: std.mem.Allocator,
    mesh: *const @import("../assets/mesh_resource.zig").MeshResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const vertices_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.sliceAsBytes(mesh.vertices));
    defer allocator.free(vertices_hash);
    const indices_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.sliceAsBytes(mesh.indices));
    defer allocator.free(indices_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.mesh.v1", &.{
            mesh.name,
            vertices_hash,
            indices_hash,
            @tagName(mesh.primitive_type),
        });

    return .{
        .id = asset_id,
        .type = .mesh,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/meshes/{s}", .{mesh.name}),
        .source_hash = try asset_registry.hashStringAlloc(allocator, vertices_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .mesh),
        .import_version = asset_registry.AssetType.mesh.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, mesh.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.mesh.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedTextureAssetRecord(
    allocator: std.mem.Allocator,
    texture: *const @import("../assets/texture_resource.zig").TextureResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const pixels_hash = try asset_registry.hashBytesAlloc(allocator, texture.pixels);
    defer allocator.free(pixels_hash);

    var width_buffer: [16]u8 = undefined;
    var height_buffer: [16]u8 = undefined;
    const width_text = try std.fmt.bufPrint(&width_buffer, "{d}", .{texture.width});
    const height_text = try std.fmt.bufPrint(&height_buffer, "{d}", .{texture.height});

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.texture.v1", &.{
            texture.name,
            width_text,
            height_text,
            @tagName(texture.format),
            pixels_hash,
        });

    return .{
        .id = asset_id,
        .type = .texture,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/textures/{s}", .{texture.name}),
        .source_hash = try allocator.dupe(u8, pixels_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .texture),
        .import_version = asset_registry.AssetType.texture.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, texture.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.texture.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedMaterialAssetRecord(
    allocator: std.mem.Allocator,
    material: *const @import("../assets/material_resource.zig").MaterialResource,
    texture_asset_id: ?[]const u8,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const factor_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.asBytes(&material.base_color_factor));
    defer allocator.free(factor_hash);

    const texture_part = texture_asset_id orelse "none";
    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.material.v1", &.{
            material.name,
            @tagName(material.shading),
            factor_hash,
            texture_part,
        });

    const dependency_ids = if (texture_asset_id) |resolved|
        try cloneStringList(allocator, &.{resolved})
    else
        try allocator.alloc([]u8, 0);

    return .{
        .id = asset_id,
        .type = .material,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/materials/{s}", .{material.name}),
        .source_hash = try asset_registry.hashStringAlloc(allocator, factor_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .material),
        .import_version = asset_registry.AssetType.material.importVersion(),
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, material.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn bindTextureAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.TextureHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .texture, fallback_name);
    _ = try world.resources.bindTextureAssetRecord(handle, record);
}

fn bindMaterialAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.MaterialHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .material, fallback_name);
    _ = try world.resources.bindMaterialAssetRecord(handle, record);
}

fn bindMeshAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.MeshHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .mesh, fallback_name);
    _ = try world.resources.bindMeshAssetRecord(handle, record);
}

fn fallbackSceneAssetRecord(
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    asset_type: asset_registry.AssetType,
    display_name: []const u8,
) !asset_registry.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = asset_type,
        .source_path = try std.fmt.allocPrint(allocator, "scene://recovered/{s}/{s}", .{ @tagName(asset_type), display_name }),
        .source_hash = try asset_registry.hashStringAlloc(allocator, asset_id),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, asset_type),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn findAssetRecord(records: []const asset_registry.AssetRecord, asset_id: []const u8) ?*const asset_registry.AssetRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.id, asset_id)) {
            return record;
        }
    }
    return null;
}

fn findTextureHandle(bindings: []const TextureBinding, asset_id: []const u8) ?assets_handles.TextureHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findMaterialHandle(bindings: []const MaterialBinding, asset_id: []const u8) ?assets_handles.MaterialHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findMeshHandle(bindings: []const MeshBinding, asset_id: []const u8) ?assets_handles.MeshHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn makeSceneIdAlloc(
    allocator: std.mem.Allocator,
    entities: []const EntityRecord,
    meshes: []const MeshRecord,
    materials: []const MaterialRecord,
    textures: []const TextureRecord,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entities) |entity| {
        hasher.update(entity.name);
        if (entity.mesh) |mesh| {
            hasher.update(mesh.asset_id orelse "none");
        }
        if (entity.material) |material| {
            hasher.update(material.asset_id orelse "none");
        }
    }
    for (meshes) |mesh| hasher.update(mesh.asset_id);
    for (materials) |material| hasher.update(material.asset_id);
    for (textures) |texture| hasher.update(texture.asset_id);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

fn encodeHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        const high = byte >> 4;
        const low = byte & 0x0F;
        encoded[index * 2] = nibbleToHex(high);
        encoded[index * 2 + 1] = nibbleToHex(low);
    }
    return encoded;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) {
        return error.InvalidHexEncoding;
    }

    const decoded = try allocator.alloc(u8, encoded.len / 2);
    errdefer allocator.free(decoded);
    _ = try std.fmt.hexToBytes(decoded, encoded);
    return decoded;
}

fn nibbleToHex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const cloned = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            allocator.free(cloned[index]);
        }
    }
    while (index < values.len) : (index += 1) {
        cloned[index] = try allocator.dupe(u8, values[index]);
    }
    return cloned;
}

fn applyBuiltinMeshHandle(resources: anytype, name: []const u8, handle: assets_handles.MeshHandle) void {
    if (std.mem.eql(u8, name, "BuiltinCube")) {
        resources.cube_mesh = handle;
    } else if (std.mem.eql(u8, name, "BuiltinSphere")) {
        resources.sphere_mesh = handle;
    } else if (std.mem.eql(u8, name, "BuiltinPlane")) {
        resources.plane_mesh = handle;
    }
}

fn applyBuiltinTextureHandle(resources: anytype, name: []const u8, handle: assets_handles.TextureHandle) void {
    if (std.mem.eql(u8, name, "White1x1")) {
        resources.white_texture = handle;
    }
}

fn applyBuiltinMaterialHandle(resources: anytype, name: []const u8, handle: assets_handles.MaterialHandle) void {
    if (std.mem.eql(u8, name, "DefaultMaterial")) {
        resources.default_material = handle;
    }
}

fn hexLowerAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = nibbleToHex(byte >> 4);
        encoded[index * 2 + 1] = nibbleToHex(byte & 0x0F);
    }
    return encoded;
}

test "scene serialization round-trips meshes, lights, textures, and asset ids" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    _ = try world.importGltfStaticModel(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ -1.0, 0.0, 0.0 },
        },
    );
    _ = try world.createLightEntity(.point, .{ .translation = .{ 1.0, 1.5, 2.0 } }, 16.0);

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const summary = loaded.summary();
    try std.testing.expectEqual(@as(usize, 7), summary.entity_count);
    try std.testing.expectEqual(@as(usize, 5), summary.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), summary.light_count);
    try std.testing.expect(loaded.findEntityByName("PointLight") != null);
    try std.testing.expect(loaded.findEntityByName("guava_showcase_GuavaShowcase") != null);

    const imported = loaded.findEntityByName("guava_showcase_GuavaShowcase").?;
    const mesh_handle = imported.mesh.?.handle.?;
    const material_handle = imported.material.?.handle.?;
    const mesh = loaded.resources.mesh(mesh_handle).?;
    const material = loaded.resources.material(material_handle).?;
    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expect(material.base_color_texture != null);
    try std.testing.expect(loaded.resources.meshAssetId(mesh_handle) != null);
    try std.testing.expect(loaded.resources.materialAssetId(material_handle) != null);
}

test "scene serialization is byte deterministic for identical world state" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    const first = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(first);
    const second = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "scene serialization round-trips parent relationships" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "Parent",
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = root,
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 0.0 },
        },
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_child = loaded.findEntityByName("Child").?;
    const loaded_root = loaded.findEntityByName("Parent").?;
    try std.testing.expectEqual(loaded_root.id, loaded_child.parent.?);
    const world_transform = loaded.worldTransform(loaded_child.id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), world_transform.translation[1], 0.0001);
    _ = child;
}

test "scene serialization round-trips folder entities" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const folder = try world.createFolderEntity(.{
        .translation = .{ 4.0, 0.0, 0.0 },
    });
    _ = try world.createEntity(.{
        .name = "Child",
        .parent = folder,
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_folder = loaded.findEntityByName("Folder").?;
    try std.testing.expect(loaded_folder.is_folder);
    try std.testing.expectEqual(loaded_folder.id, loaded.findEntityByName("Child").?.parent.?);
}

test "scene serialization round-trips vfx entities" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createVfxEntity(.orbit, .{
        .translation = .{ 2.0, 0.5, -1.0 },
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_vfx = loaded.findEntityByName("OrbitVfx").?;
    try std.testing.expect(loaded_vfx.vfx != null);
    try std.testing.expectEqual(components.VfxKind.orbit, loaded_vfx.vfx.?.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), loaded_vfx.local_transform.translation[0], 0.0001);
}
