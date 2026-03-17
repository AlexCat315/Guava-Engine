const std = @import("std");
const handles = @import("handles.zig");
const image_decoder = @import("image_decoder.zig");
const mesh_mod = @import("mesh_resource.zig");
const registry_mod = @import("registry.zig");
const texture_import_mod = @import("texture_import.zig");
const components = @import("../scene/components.zig");
const math = @import("../math/mat4.zig");

pub const ImportReport = struct {
    entity_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    texture_count: usize = 0,
    root_entity: ?u64 = null,
};

const GltfDocument = struct {
    asset: Asset,
    buffers: ?[]Buffer = null,
    bufferViews: ?[]BufferView = null,
    accessors: ?[]Accessor = null,
    images: ?[]Image = null,
    textures: ?[]Texture = null,
    materials: ?[]Material = null,
    meshes: ?[]Mesh = null,
    nodes: ?[]Node = null,
    scenes: ?[]SceneDef = null,
    scene: ?u32 = null,
};

const Asset = struct {
    version: []const u8,
    generator: ?[]const u8 = null,
};

const Buffer = struct {
    uri: ?[]const u8 = null,
    byteLength: usize,
};

const BufferView = struct {
    buffer: u32,
    byteOffset: ?usize = null,
    byteLength: usize,
    byteStride: ?usize = null,
};

const Accessor = struct {
    bufferView: ?u32 = null,
    byteOffset: ?usize = null,
    componentType: u32,
    count: usize,
    type: []const u8,
    normalized: bool = false,
};

const Image = struct {
    uri: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    bufferView: ?u32 = null,
    name: ?[]const u8 = null,
};

const Texture = struct {
    sampler: ?u32 = null,
    source: ?u32 = null,
    name: ?[]const u8 = null,
};

const TextureInfo = struct {
    index: u32,
};

const PbrMetallicRoughness = struct {
    baseColorFactor: ?[4]f32 = null,
    baseColorTexture: ?TextureInfo = null,
    metallicFactor: ?f32 = null,
    roughnessFactor: ?f32 = null,
    metallicRoughnessTexture: ?TextureInfo = null,
};

const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
    normalTexture: ?TextureInfo = null,
    occlusionTexture: ?TextureInfo = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: ?[3]f32 = null,
    alphaMode: ?[]const u8 = null,
    alphaCutoff: ?f32 = null,
    doubleSided: ?bool = null,
};

const Primitive = struct {
    attributes: std.json.Value,
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: ?u32 = null,
};

const Mesh = struct {
    name: ?[]const u8 = null,
    primitives: []Primitive,
};

const Node = struct {
    name: ?[]const u8 = null,
    mesh: ?u32 = null,
    children: ?[]u32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    matrix: ?[16]f32 = null,
};

const SceneDef = struct {
    name: ?[]const u8 = null,
    nodes: ?[]u32 = null,
};

const AccessorView = struct {
    bytes: []const u8,
    stride: usize,
    count: usize,
    component_type: u32,
    normalized: bool,
    type: []const u8,
};

const TextureResolution = struct {
    handle: ?handles.TextureHandle = null,
    created: bool = false,
};

const MaterialResolution = struct {
    handle: handles.MaterialHandle,
    created: bool = false,
    created_texture_count: usize = 0,
};

const current_model_cache_version: u32 = registry_mod.AssetType.model.importVersion();

const CookedMeshRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    primitive_type: @import("../rhi/types.zig").PrimitiveType = .triangle_list,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const CookedMaterialRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture_asset_id: ?[]const u8 = null,
    metallic_roughness_texture_asset_id: ?[]const u8 = null,
    normal_texture_asset_id: ?[]const u8 = null,
    occlusion_texture_asset_id: ?[]const u8 = null,
    emissive_texture_asset_id: ?[]const u8 = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
};

const CookedEntityRecord = struct {
    name: []const u8,
    mesh_asset_id: ?[]const u8 = null,
    material_asset_id: ?[]const u8 = null,
    local_transform: components.Transform = .{},
    parent_index: ?usize = null,
};

const CookedModelFile = struct {
    version: u32 = current_model_cache_version,
    model_asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32 = current_model_cache_version,
    asset_records: []registry_mod.AssetRecord,
    meshes: []CookedMeshRecord,
    materials: []CookedMaterialRecord,
    entities: []CookedEntityRecord,
};

const CookedMaterialResolution = struct {
    asset_id: []const u8,
    created: bool = false,
};

const CookedMeshHandle = struct {
    asset_id: []const u8,
    handle: handles.MeshHandle,
};

const CookedMaterialHandle = struct {
    asset_id: []const u8,
    handle: handles.MaterialHandle,
};

pub fn importStaticModelAsset(
    world: anytype,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
    root_transform: components.Transform,
) !ImportReport {
    return importStaticModelAssetInternal(world, registry, asset_id, root_transform, false);
}

pub fn importStaticModelAssetInstance(
    world: anytype,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
    root_transform: components.Transform,
) !ImportReport {
    return importStaticModelAssetInternal(world, registry, asset_id, root_transform, true);
}

pub fn importStaticModel(
    world: anytype,
    path: []const u8,
    root_transform: components.Transform,
) !ImportReport {
    return importStaticModelInternal(world, path, root_transform, null, false);
}

pub fn importStaticModelInstance(
    world: anytype,
    path: []const u8,
    root_transform: components.Transform,
) !ImportReport {
    return importStaticModelInternal(world, path, root_transform, null, true);
}

fn importStaticModelAssetInternal(
    world: anytype,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
    root_transform: components.Transform,
    create_root_instance: bool,
) !ImportReport {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .model) {
        return error.AssetTypeMismatch;
    }
    if (record.outputs.len == 0) {
        return error.MissingCookedOutput;
    }

    const cooked_path = try ensureCookedModel(world.allocator, registry, record);
    const encoded = try std.fs.cwd().readFileAlloc(world.allocator, cooked_path, 128 * 1024 * 1024);
    defer world.allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedModelFile, world.allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const cooked = parsed.value;
    if (cooked.version != current_model_cache_version) {
        return error.UnsupportedModelCacheVersion;
    }
    if (!std.mem.eql(u8, cooked.model_asset_id, asset_id)) {
        return error.AssetIdMismatch;
    }

    return instantiateCookedModel(world, registry, cooked, root_transform, create_root_instance);
}

pub fn ensureCookedModelAsset(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) ![]u8 {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .model) {
        return error.AssetTypeMismatch;
    }
    if (record.outputs.len == 0) {
        return error.MissingCookedOutput;
    }
    return ensureCookedModel(allocator, registry, record);
}

pub fn validateCookedModelAsset(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) !void {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .model) {
        return error.AssetTypeMismatch;
    }

    const cooked_path = try ensureCookedModel(allocator, registry, record);
    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedModelFile, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const cooked = parsed.value;
    const default_material_asset_id = try builtinAssetIdAlloc(allocator, "builtin://material/default");
    defer allocator.free(default_material_asset_id);

    if (!cookedModelMatchesRecord(record, cooked)) {
        return error.ModelCacheOutOfDate;
    }

    for (cooked.materials) |material| {
        if (material.base_color_texture_asset_id) |texture_asset_id| {
            if (registry.recordById(texture_asset_id) == null) {
                return error.TextureAssetNotFound;
            }
            try texture_import_mod.validateCookedTextureAsset(allocator, registry, texture_asset_id);
        }
    }

    for (cooked.entities) |entity| {
        if (entity.mesh_asset_id) |mesh_asset_id| {
            if (findCookedMeshRecord(cooked.meshes, mesh_asset_id) == null) {
                return error.MeshAssetNotFound;
            }
        }
        if (entity.material_asset_id) |material_asset_id| {
            if (findCookedMaterialRecord(cooked.materials, material_asset_id) == null and
                !std.mem.eql(u8, material_asset_id, default_material_asset_id))
            {
                return error.MaterialAssetNotFound;
            }
        }
    }
}

fn ensureCookedModel(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    record: *const registry_mod.AssetRecord,
) ![]u8 {
    const cooked_path = record.outputs[0].path;
    const should_recook = recook: {
        std.fs.cwd().access(cooked_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :recook true,
            else => return err,
        };
        break :recook !(try cookedModelIsCurrent(allocator, record, cooked_path));
    };
    if (should_recook) {
        try cookModelRecord(allocator, registry, record, cooked_path);
    }
    return cooked_path;
}

fn cookModelRecord(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    record: *const registry_mod.AssetRecord,
    cooked_path: []const u8,
) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, record.source_path, 32 * 1024 * 1024);
    defer allocator.free(source);

    var document_parse = try std.json.parseFromSlice(GltfDocument, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer document_parse.deinit();
    const document = document_parse.value;

    if (!std.mem.startsWith(u8, document.asset.version, "2.")) {
        return error.UnsupportedGltfVersion;
    }

    const base_dir = std.fs.path.dirname(record.source_path) orelse ".";
    const source_stem = std.fs.path.stem(record.source_path);
    const loaded_buffers = try loadBuffers(allocator, base_dir, document.buffers orelse &.{});
    defer freeLoadedBuffers(allocator, loaded_buffers);

    const default_material_asset_id = try builtinAssetIdAlloc(allocator, "builtin://material/default");
    defer allocator.free(default_material_asset_id);

    const document_materials = document.materials orelse &.{};
    const material_asset_ids = try allocator.alloc(?[]const u8, document_materials.len);
    defer allocator.free(material_asset_ids);
    @memset(material_asset_ids, null);

    const document_textures = document.textures orelse &.{};
    const texture_asset_ids = try allocator.alloc(?[]const u8, document_textures.len);
    defer allocator.free(texture_asset_ids);
    @memset(texture_asset_ids, null);

    var cooked_meshes = std.ArrayList(CookedMeshRecord).empty;
    defer cooked_meshes.deinit(allocator);
    var cooked_materials = std.ArrayList(CookedMaterialRecord).empty;
    defer cooked_materials.deinit(allocator);
    var cooked_entities = std.ArrayList(CookedEntityRecord).empty;
    defer cooked_entities.deinit(allocator);
    var cooked_asset_records = std.ArrayList(registry_mod.AssetRecord).empty;
    defer cooked_asset_records.deinit(allocator);

    const scene_index = document.scene orelse 0;
    const document_scenes = document.scenes orelse return error.MissingScenes;
    if (scene_index >= document_scenes.len) {
        return error.SceneIndexOutOfBounds;
    }

    const root_nodes = document_scenes[scene_index].nodes orelse return error.MissingSceneNodes;
    for (root_nodes) |node_index| {
        try cookNodeRecursive(
            allocator,
            registry,
            record,
            document,
            loaded_buffers,
            material_asset_ids,
            texture_asset_ids,
            default_material_asset_id,
            node_index,
            null,
            base_dir,
            source_stem,
            &cooked_meshes,
            &cooked_materials,
            &cooked_entities,
            &cooked_asset_records,
        );
    }

    var cooked = CookedModelFile{
        .model_asset_id = record.id,
        .source_path = record.source_path,
        .source_hash = record.source_hash,
        .import_settings_hash = record.import_settings_hash,
        .import_version = record.resolvedImportVersion(),
        .asset_records = try cooked_asset_records.toOwnedSlice(allocator),
        .meshes = try cooked_meshes.toOwnedSlice(allocator),
        .materials = try cooked_materials.toOwnedSlice(allocator),
        .entities = try cooked_entities.toOwnedSlice(allocator),
    };
    defer freeCookedModelOwned(allocator, &cooked);

    const encoded = try stringifyAlloc(allocator, cooked);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(cooked_path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = cooked_path,
        .data = encoded,
    });
}

fn composeTransform(parent: components.Transform, local: components.Transform) components.Transform {
    const quat = @import("../math/quat.zig");
    const vec3 = @import("../math/vec3.zig");
    return .{
        .translation = vec3.add(
            parent.translation,
            quat.rotateVec3(parent.rotation, vec3.mul(parent.scale, local.translation)),
        ),
        .rotation = quat.mul(parent.rotation, local.rotation),
        .scale = vec3.mul(parent.scale, local.scale),
    };
}

fn instantiateCookedModel(
    world: anytype,
    registry: *const registry_mod.AssetRegistry,
    cooked: CookedModelFile,
    root_transform: components.Transform,
    create_root_instance: bool,
) !ImportReport {
    var report = ImportReport{};
    const default_material_asset_id = try builtinAssetIdAlloc(world.allocator, "builtin://material/default");
    defer world.allocator.free(default_material_asset_id);

    var mesh_handles = std.ArrayList(CookedMeshHandle).empty;
    defer mesh_handles.deinit(world.allocator);
    for (cooked.meshes) |mesh| {
        const handle = if (world.resources.meshHandleByAssetId(mesh.asset_id)) |existing|
            existing
        else blk: {
            const created = try world.resources.createMesh(.{
                .name = mesh.name,
                .vertices = mesh.vertices,
                .indices = mesh.indices,
                .primitive_type = mesh.primitive_type,
            });
            const record = if (findCookedAssetRecord(cooked.asset_records, mesh.asset_id)) |asset_record|
                try asset_record.clone(world.allocator)
            else
                try fallbackCookedAssetRecord(world.allocator, mesh.asset_id, .mesh, mesh.name);
            _ = try world.resources.bindMeshAssetRecord(created, record);
            report.mesh_count += 1;
            break :blk created;
        };
        try mesh_handles.append(world.allocator, .{ .asset_id = mesh.asset_id, .handle = handle });
    }

    var material_handles = std.ArrayList(CookedMaterialHandle).empty;
    defer material_handles.deinit(world.allocator);
    for (cooked.materials) |material| {
        const handle = if (world.resources.materialHandleByAssetId(material.asset_id)) |existing|
            existing
        else blk: {
            const base_color_texture = if (material.base_color_texture_asset_id) |id|
                try texture_import_mod.loadTextureAsset(world.allocator, &world.resources, registry, id)
            else
                null;
            const metallic_roughness_texture = if (material.metallic_roughness_texture_asset_id) |id|
                try texture_import_mod.loadTextureAsset(world.allocator, &world.resources, registry, id)
            else
                null;
            const normal_texture = if (material.normal_texture_asset_id) |id|
                try texture_import_mod.loadTextureAsset(world.allocator, &world.resources, registry, id)
            else
                null;
            const occlusion_texture = if (material.occlusion_texture_asset_id) |id|
                try texture_import_mod.loadTextureAsset(world.allocator, &world.resources, registry, id)
            else
                null;
            const emissive_texture = if (material.emissive_texture_asset_id) |id|
                try texture_import_mod.loadTextureAsset(world.allocator, &world.resources, registry, id)
            else
                null;

            const created = try world.resources.createMaterial(.{
                .name = material.name,
                .shading = material.shading,
                .base_color_factor = material.base_color_factor,
                .base_color_texture = base_color_texture,
                .metallic_roughness_texture = metallic_roughness_texture,
                .normal_texture = normal_texture,
                .occlusion_texture = occlusion_texture,
                .emissive_texture = emissive_texture,
                .emissive_factor = material.emissive_factor,
                .metallic_factor = material.metallic_factor,
                .roughness_factor = material.roughness_factor,
                .alpha_cutoff = material.alpha_cutoff,
                .double_sided = material.double_sided,
            });
            const record = if (findCookedAssetRecord(cooked.asset_records, material.asset_id)) |asset_record|
                try asset_record.clone(world.allocator)
            else
                try fallbackCookedAssetRecord(world.allocator, material.asset_id, .material, material.name);
            _ = try world.resources.bindMaterialAssetRecord(created, record);
            report.material_count += 1;
            break :blk created;
        };
        try material_handles.append(world.allocator, .{ .asset_id = material.asset_id, .handle = handle });
    }

    const import_parent = if (create_root_instance)
        try createImportRoot(world, cooked.source_path, root_transform, &report)
    else
        null;

    var entity_ids = try world.allocator.alloc(u64, cooked.entities.len);
    defer world.allocator.free(entity_ids);

    for (cooked.entities, 0..) |entity, index| {
        const mesh_handle = if (entity.mesh_asset_id) |asset_id|
            findMeshHandle(mesh_handles.items, asset_id) orelse return error.MeshAssetNotFound
        else
            null;

        const material_handle = if (entity.material_asset_id) |asset_id|
            if (std.mem.eql(u8, asset_id, default_material_asset_id))
                try world.resources.ensureDefaultMaterial()
            else
                findMaterialHandle(material_handles.items, asset_id) orelse return error.MaterialAssetNotFound
        else
            null;

        const parent_id = if (entity.parent_index) |p_idx| entity_ids[p_idx] else import_parent;

        const entity_id = try world.createEntity(.{
            .name = entity.name,
            .parent = parent_id,
            .mesh = if (mesh_handle) |h| .{ .handle = h, .primitive = .custom } else null,
            .material = if (material_handle) |h| .{ .handle = h } else null,
            .local_transform = if (entity.parent_index != null) entity.local_transform else if (import_parent != null) entity.local_transform else composeTransform(root_transform, entity.local_transform),
        });
        entity_ids[index] = entity_id;
        report.entity_count += 1;
    }

    return report;
}

fn cookNodeRecursive(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    model_record: *const registry_mod.AssetRecord,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_asset_ids: []?[]const u8,
    texture_asset_ids: []?[]const u8,
    default_material_asset_id: []const u8,
    node_index: u32,
    parent_entity_index: ?usize,
    base_dir: []const u8,
    source_stem: []const u8,
    cooked_meshes: *std.ArrayList(CookedMeshRecord),
    cooked_materials: *std.ArrayList(CookedMaterialRecord),
    cooked_entities: *std.ArrayList(CookedEntityRecord),
    cooked_asset_records: *std.ArrayList(registry_mod.AssetRecord),
) !void {
    const document_nodes = document.nodes orelse return error.MissingNodes;
    if (node_index >= document_nodes.len) {
        return error.NodeIndexOutOfBounds;
    }

    const node = document_nodes[node_index];
    const node_transform = nodeTransform(node);
    const entity_index = cooked_entities.items.len;

    const node_name = if (node.name) |n|
        try std.fmt.allocPrint(allocator, "{s}_{s}", .{ source_stem, n })
    else
        try std.fmt.allocPrint(allocator, "{s}_Node_{d}", .{ source_stem, node_index });

    try cooked_entities.append(allocator, .{
        .name = node_name,
        .local_transform = node_transform,
        .parent_index = parent_entity_index,
    });

    if (node.mesh) |mesh_index| {
        try cookNodeMesh(
            allocator,
            registry,
            model_record,
            document,
            loaded_buffers,
            material_asset_ids,
            texture_asset_ids,
            default_material_asset_id,
            mesh_index,
            node,
            entity_index,
            base_dir,
            source_stem,
            cooked_meshes,
            cooked_materials,
            cooked_entities,
            cooked_asset_records,
        );
    }

    if (node.children) |children| {
        for (children) |child_index| {
            try cookNodeRecursive(
                allocator,
                registry,
                model_record,
                document,
                loaded_buffers,
                material_asset_ids,
                texture_asset_ids,
                default_material_asset_id,
                child_index,
                entity_index,
                base_dir,
                source_stem,
                cooked_meshes,
                cooked_materials,
                cooked_entities,
                cooked_asset_records,
            );
        }
    }
}

fn cookNodeMesh(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    model_record: *const registry_mod.AssetRecord,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_asset_ids: []?[]const u8,
    texture_asset_ids: []?[]const u8,
    default_material_asset_id: []const u8,
    mesh_index: u32,
    node: Node,
    entity_index: usize,
    base_dir: []const u8,
    source_stem: []const u8,
    cooked_meshes: *std.ArrayList(CookedMeshRecord),
    cooked_materials: *std.ArrayList(CookedMaterialRecord),
    cooked_entities: *std.ArrayList(CookedEntityRecord),
    cooked_asset_records: *std.ArrayList(registry_mod.AssetRecord),
) !void {
    const document_meshes = document.meshes orelse return error.MissingMeshes;
    if (mesh_index >= document_meshes.len) {
        return error.MeshIndexOutOfBounds;
    }

    const mesh = document_meshes[mesh_index];
    for (mesh.primitives, 0..) |primitive, primitive_index| {
        const mode = primitive.mode orelse 4;
        if (mode != 4) {
            return error.UnsupportedPrimitiveMode;
        }

        const cooked_mesh = try createCookedMeshForPrimitive(
            allocator,
            model_record,
            document,
            loaded_buffers,
            primitive,
            mesh_index,
            mesh.name,
            primitive_index,
        );
        try cooked_meshes.append(allocator, cooked_mesh.record);
        try appendCookedAssetRecord(cooked_asset_records, allocator, cooked_mesh.asset_record);

        const material = try resolveCookedMaterial(
            allocator,
            registry,
            model_record,
            document,
            loaded_buffers,
            material_asset_ids,
            texture_asset_ids,
            default_material_asset_id,
            primitive.material,
            base_dir,
            source_stem,
            cooked_materials,
            cooked_asset_records,
        );

        if (primitive_index == 0) {
            cooked_entities.items[entity_index].mesh_asset_id = cooked_mesh.record.asset_id;
            cooked_entities.items[entity_index].material_asset_id = material.asset_id;
        } else {
            const entity_name = try entityNameForPrimitive(
                allocator,
                source_stem,
                node.name orelse mesh.name orelse "Node",
                primitive_index,
            );
            try cooked_entities.append(allocator, .{
                .name = entity_name,
                .mesh_asset_id = cooked_mesh.record.asset_id,
                .material_asset_id = material.asset_id,
                .parent_index = entity_index,
                .local_transform = .{},
            });
        }
    }
}

fn resolveCookedMaterial(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    model_record: *const registry_mod.AssetRecord,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_asset_ids: []?[]const u8,
    texture_asset_ids: []?[]const u8,
    default_material_asset_id: []const u8,
    material_index: ?u32,
    base_dir: []const u8,
    source_stem: []const u8,
    cooked_materials: *std.ArrayList(CookedMaterialRecord),
    cooked_asset_records: *std.ArrayList(registry_mod.AssetRecord),
) !CookedMaterialResolution {
    const index = material_index orelse return .{ .asset_id = default_material_asset_id };
    const document_materials = document.materials orelse return .{ .asset_id = default_material_asset_id };
    if (index >= document_materials.len) {
        return error.MaterialIndexOutOfBounds;
    }

    if (material_asset_ids[index]) |asset_id| {
        return .{ .asset_id = asset_id };
    }

    const material = document_materials[index];
    const pbr = material.pbrMetallicRoughness;
    const base_color_factor = if (pbr) |value|
        value.baseColorFactor orelse .{ 1.0, 1.0, 1.0, 1.0 }
    else
        .{ 1.0, 1.0, 1.0, 1.0 };
    const base_color_texture_asset_id = if (pbr) |value|
        try resolveTextureAssetIdForCook(
            allocator,
            registry,
            document,
            loaded_buffers,
            texture_asset_ids,
            if (value.baseColorTexture) |info| info.index else null,
            base_dir,
        )
    else
        null;

    const metallic_factor = if (pbr) |value| value.metallicFactor orelse 1.0 else 1.0;
    const roughness_factor = if (pbr) |value| value.roughnessFactor orelse 1.0 else 1.0;
    const metallic_roughness_texture_asset_id = if (pbr) |value|
        try resolveTextureAssetIdForCook(
            allocator,
            registry,
            document,
            loaded_buffers,
            texture_asset_ids,
            if (value.metallicRoughnessTexture) |info| info.index else null,
            base_dir,
        )
    else
        null;

    const normal_texture_asset_id = try resolveTextureAssetIdForCook(
        allocator,
        registry,
        document,
        loaded_buffers,
        texture_asset_ids,
        if (material.normalTexture) |info| info.index else null,
        base_dir,
    );

    const occlusion_texture_asset_id = try resolveTextureAssetIdForCook(
        allocator,
        registry,
        document,
        loaded_buffers,
        texture_asset_ids,
        if (material.occlusionTexture) |info| info.index else null,
        base_dir,
    );

    const emissive_factor = material.emissiveFactor orelse .{ 0.0, 0.0, 0.0 };
    const emissive_texture_asset_id = try resolveTextureAssetIdForCook(
        allocator,
        registry,
        document,
        loaded_buffers,
        texture_asset_ids,
        if (material.emissiveTexture) |info| info.index else null,
        base_dir,
    );

    const alpha_cutoff = material.alphaCutoff orelse 0.5;
    const double_sided = material.doubleSided orelse false;

    var index_buffer: [16]u8 = undefined;
    const index_text = try std.fmt.bufPrint(&index_buffer, "{d}", .{index});
    const generated_name = try std.fmt.allocPrint(allocator, "{s}_material_{d}", .{
        source_stem,
        index,
    });

    const asset_id = try registry_mod.makeDerivedAssetIdAlloc(allocator, "guava.gltf.material.v1", &.{
        model_record.id,
        index_text,
    });
    material_asset_ids[index] = asset_id;

    const material_name = if (material.name) |name| blk: {
        defer allocator.free(generated_name);
        break :blk try allocator.dupe(u8, name);
    } else generated_name;

    try cooked_materials.append(allocator, .{
        .asset_id = asset_id,
        .name = material_name,
        .base_color_factor = base_color_factor,
        .base_color_texture_asset_id = base_color_texture_asset_id,
        .metallic_roughness_texture_asset_id = metallic_roughness_texture_asset_id,
        .normal_texture_asset_id = normal_texture_asset_id,
        .occlusion_texture_asset_id = occlusion_texture_asset_id,
        .emissive_texture_asset_id = emissive_texture_asset_id,
        .emissive_factor = emissive_factor,
        .metallic_factor = metallic_factor,
        .roughness_factor = roughness_factor,
        .alpha_cutoff = alpha_cutoff,
        .double_sided = double_sided,
    });
    try appendCookedAssetRecord(
        cooked_asset_records,
        allocator,
        try makeCookedMaterialAssetRecord(
            allocator,
            model_record,
            asset_id,
            material_name,
            base_color_factor,
            base_color_texture_asset_id,
            metallic_roughness_texture_asset_id,
            normal_texture_asset_id,
            occlusion_texture_asset_id,
            emissive_texture_asset_id,
        ),
    );

    return .{
        .asset_id = asset_id,
        .created = true,
    };
}

fn resolveTextureAssetIdForCook(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    texture_asset_ids: []?[]const u8,
    texture_index: ?u32,
    base_dir: []const u8,
) !?[]const u8 {
    _ = loaded_buffers;
    const index = texture_index orelse return null;
    const document_textures = document.textures orelse return null;
    const document_images = document.images orelse return null;
    if (index >= document_textures.len) {
        return error.TextureIndexOutOfBounds;
    }
    if (texture_asset_ids[index]) |asset_id| {
        return asset_id;
    }

    const texture = document_textures[index];
    const image_index = texture.source orelse return error.TextureSourceMissing;
    if (image_index >= document_images.len) {
        return error.ImageIndexOutOfBounds;
    }

    const image = document_images[image_index];
    const uri = image.uri orelse return error.UnsupportedImageSource;
    if (std.mem.startsWith(u8, uri, "data:")) {
        return error.UnsupportedImageSource;
    }

    const dependency_path = try std.fs.path.join(allocator, &.{ base_dir, uri });
    defer allocator.free(dependency_path);
    const dependency_record = registry.recordByPath(dependency_path) orelse return error.TextureAssetNotFound;
    texture_asset_ids[index] = dependency_record.id;
    return dependency_record.id;
}

fn createCookedMeshForPrimitive(
    allocator: std.mem.Allocator,
    model_record: *const registry_mod.AssetRecord,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    primitive: Primitive,
    mesh_index: u32,
    mesh_name: ?[]const u8,
    primitive_index: usize,
) !struct { record: CookedMeshRecord, asset_record: registry_mod.AssetRecord } {
    const position_accessor_index = attributeIndex(primitive.attributes, "POSITION") orelse return error.MissingPositions;
    const position_view = try accessorView(document, loaded_buffers, position_accessor_index);
    try requireAccessorFormat(position_view, "VEC3", 5126, error.UnsupportedPositionFormat);

    const normal_view = if (attributeIndex(primitive.attributes, "NORMAL")) |index| blk: {
        const view = try accessorView(document, loaded_buffers, index);
        try requireAccessorFormat(view, "VEC3", 5126, error.UnsupportedNormalFormat);
        break :blk view;
    } else null;

    const tangent_view = if (attributeIndex(primitive.attributes, "TANGENT")) |index| blk: {
        const view = try accessorView(document, loaded_buffers, index);
        try requireAccessorFormat(view, "VEC4", 5126, error.UnsupportedTangentFormat);
        break :blk view;
    } else null;

    const color_view = if (attributeIndex(primitive.attributes, "COLOR_0")) |index|
        try accessorView(document, loaded_buffers, index)
    else
        null;
    const uv_view = if (attributeIndex(primitive.attributes, "TEXCOORD_0")) |index|
        try accessorView(document, loaded_buffers, index)
    else
        null;

    try requireMatchingCount(normal_view, position_view.count);
    try requireMatchingCount(tangent_view, position_view.count);
    try requireMatchingCount(color_view, position_view.count);
    try requireMatchingCount(uv_view, position_view.count);

    const vertices = try allocator.alloc(mesh_mod.Vertex, position_view.count);
    for (vertices, 0..) |*vertex, index| {
        vertex.position = try readVec3(position_view, index);
        vertex.normal = if (normal_view) |view|
            normalize3(try readVec3(view, index))
        else
            .{ 0.0, 1.0, 0.0 };
        vertex.tangent = if (tangent_view) |view|
            try readVec4(view, index)
        else
            defaultTangent(vertex.normal);
        vertex.color = if (color_view) |view| try readColor(view, index) else .{ 1.0, 1.0, 1.0, 1.0 };
        vertex.uv = if (uv_view) |view| try readVec2(view, index) else .{ 0.0, 0.0 };
    }

    const indices = if (primitive.indices) |accessor_index|
        try readIndices(allocator, try accessorView(document, loaded_buffers, accessor_index))
    else
        try sequentialIndices(allocator, vertices.len);

    const generated_name = try std.fmt.allocPrint(allocator, "{s}_mesh_{d}", .{
        mesh_name orelse "Mesh",
        primitive_index,
    });

    var mesh_index_buffer: [16]u8 = undefined;
    var primitive_index_buffer: [16]u8 = undefined;
    const mesh_index_text = try std.fmt.bufPrint(&mesh_index_buffer, "{d}", .{mesh_index});
    const primitive_index_text = try std.fmt.bufPrint(&primitive_index_buffer, "{d}", .{primitive_index});
    const asset_id = try registry_mod.makeDerivedAssetIdAlloc(allocator, "guava.gltf.mesh.v1", &.{
        model_record.id,
        mesh_index_text,
        primitive_index_text,
    });

    return .{
        .record = .{
            .asset_id = asset_id,
            .name = generated_name,
            .vertices = vertices,
            .indices = indices,
        },
        .asset_record = try makeCookedMeshAssetRecord(
            allocator,
            model_record,
            asset_id,
            generated_name,
            vertices,
            indices,
        ),
    };
}

fn makeCookedMeshAssetRecord(
    allocator: std.mem.Allocator,
    model_record: *const registry_mod.AssetRecord,
    asset_id: []const u8,
    name: []const u8,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
) !registry_mod.AssetRecord {
    const vertices_hash = try registry_mod.hashBytesAlloc(allocator, std.mem.sliceAsBytes(vertices));
    defer allocator.free(vertices_hash);
    const indices_hash = try registry_mod.hashBytesAlloc(allocator, std.mem.sliceAsBytes(indices));
    defer allocator.free(indices_hash);

    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = .mesh,
        .source_path = try std.fmt.allocPrint(allocator, "{s}#mesh/{s}", .{ model_record.source_path, name }),
        .source_hash = try registry_mod.hashStringAlloc(allocator, vertices_hash),
        .import_settings_hash = try registry_mod.defaultImportSettingsHashAlloc(allocator, .mesh),
        .import_version = registry_mod.AssetType.mesh.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, name),
            .importer = try allocator.dupe(u8, registry_mod.AssetType.mesh.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeCookedMaterialAssetRecord(
    allocator: std.mem.Allocator,
    model_record: *const registry_mod.AssetRecord,
    asset_id: []const u8,
    name: []const u8,
    base_color_factor: [4]f32,
    base_color_texture_asset_id: ?[]const u8,
    metallic_roughness_texture_asset_id: ?[]const u8,
    normal_texture_asset_id: ?[]const u8,
    occlusion_texture_asset_id: ?[]const u8,
    emissive_texture_asset_id: ?[]const u8,
) !registry_mod.AssetRecord {
    const factor_hash = try registry_mod.hashBytesAlloc(allocator, std.mem.asBytes(&base_color_factor));
    defer allocator.free(factor_hash);

    var dependencies = std.ArrayList([]const u8).empty;
    defer dependencies.deinit(allocator);

    if (base_color_texture_asset_id) |id| try dependencies.append(allocator, id);
    if (metallic_roughness_texture_asset_id) |id| try dependencies.append(allocator, id);
    if (normal_texture_asset_id) |id| try dependencies.append(allocator, id);
    if (occlusion_texture_asset_id) |id| try dependencies.append(allocator, id);
    if (emissive_texture_asset_id) |id| try dependencies.append(allocator, id);

    const dependency_ids = try cloneStringList(allocator, dependencies.items);

    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = .material,
        .source_path = try std.fmt.allocPrint(allocator, "{s}#material/{s}", .{ model_record.source_path, name }),
        .source_hash = try registry_mod.hashStringAlloc(allocator, factor_hash),
        .import_settings_hash = try registry_mod.defaultImportSettingsHashAlloc(allocator, .material),
        .import_version = registry_mod.AssetType.material.importVersion(),
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, name),
            .importer = try allocator.dupe(u8, registry_mod.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn fallbackCookedAssetRecord(
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    asset_type: registry_mod.AssetType,
    display_name: []const u8,
) !registry_mod.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = asset_type,
        .source_path = try std.fmt.allocPrint(allocator, "cache://{s}/{s}", .{ @tagName(asset_type), display_name }),
        .source_hash = try registry_mod.hashStringAlloc(allocator, asset_id),
        .import_settings_hash = try registry_mod.defaultImportSettingsHashAlloc(allocator, asset_type),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn cookedModelIsCurrent(
    allocator: std.mem.Allocator,
    record: *const registry_mod.AssetRecord,
    cooked_path: []const u8,
) !bool {
    const encoded = try std.fs.cwd().readFileAlloc(allocator, cooked_path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = std.json.parseFromSlice(CookedModelFile, allocator, encoded, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    return cookedModelMatchesRecord(record, parsed.value);
}

fn cookedModelMatchesRecord(record: *const registry_mod.AssetRecord, cooked: CookedModelFile) bool {
    return cooked.version == current_model_cache_version and
        std.mem.eql(u8, cooked.model_asset_id, record.id) and
        std.mem.eql(u8, cooked.source_path, record.source_path) and
        std.mem.eql(u8, cooked.source_hash, record.source_hash) and
        std.mem.eql(u8, cooked.import_settings_hash, record.import_settings_hash) and
        cooked.import_version == record.resolvedImportVersion();
}

fn freeCookedModelOwned(allocator: std.mem.Allocator, cooked: *CookedModelFile) void {
    for (cooked.asset_records) |*record| {
        record.deinit(allocator);
    }
    allocator.free(cooked.asset_records);

    for (cooked.meshes) |mesh| {
        allocator.free(mesh.asset_id);
        allocator.free(mesh.name);
        allocator.free(mesh.vertices);
        allocator.free(mesh.indices);
    }
    allocator.free(cooked.meshes);

    for (cooked.materials) |material| {
        allocator.free(material.asset_id);
        allocator.free(material.name);
        if (material.base_color_texture_asset_id) |id| allocator.free(id);
        if (material.metallic_roughness_texture_asset_id) |id| allocator.free(id);
        if (material.normal_texture_asset_id) |id| allocator.free(id);
        if (material.occlusion_texture_asset_id) |id| allocator.free(id);
        if (material.emissive_texture_asset_id) |id| allocator.free(id);
    }
    allocator.free(cooked.materials);

    for (cooked.entities) |entity| {
        allocator.free(entity.name);
        if (entity.mesh_asset_id) |mesh_asset_id| {
            allocator.free(mesh_asset_id);
        }
        if (entity.material_asset_id) |material_asset_id| {
            allocator.free(material_asset_id);
        }
    }
    allocator.free(cooked.entities);
}

fn appendCookedAssetRecord(
    records: *std.ArrayList(registry_mod.AssetRecord),
    allocator: std.mem.Allocator,
    record: registry_mod.AssetRecord,
) !void {
    for (records.items) |existing| {
        if (std.mem.eql(u8, existing.id, record.id)) {
            return;
        }
    }
    try records.append(allocator, record);
}

fn findCookedAssetRecord(records: []const registry_mod.AssetRecord, asset_id: []const u8) ?*const registry_mod.AssetRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.id, asset_id)) {
            return record;
        }
    }
    return null;
}

fn findCookedMeshRecord(records: []const CookedMeshRecord, asset_id: []const u8) ?*const CookedMeshRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.asset_id, asset_id)) {
            return record;
        }
    }
    return null;
}

fn findCookedMaterialRecord(records: []const CookedMaterialRecord, asset_id: []const u8) ?*const CookedMaterialRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.asset_id, asset_id)) {
            return record;
        }
    }
    return null;
}

fn builtinAssetIdAlloc(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return registry_mod.makeDerivedAssetIdAlloc(allocator, "guava.builtin.v1", &.{source_path});
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [2048]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
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

fn findMeshHandle(
    items: []const CookedMeshHandle,
    asset_id: []const u8,
) ?handles.MeshHandle {
    for (items) |item| {
        if (std.mem.eql(u8, item.asset_id, asset_id)) {
            return item.handle;
        }
    }
    return null;
}

fn findMaterialHandle(
    items: []const CookedMaterialHandle,
    asset_id: []const u8,
) ?handles.MaterialHandle {
    for (items) |item| {
        if (std.mem.eql(u8, item.asset_id, asset_id)) {
            return item.handle;
        }
    }
    return null;
}

test "gltf cooked output is deterministic for identical source graph" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("assets/models/guava_showcase");

    const cwd = std.fs.cwd();
    const gltf_bytes = try cwd.readFileAlloc(std.testing.allocator, "assets/models/guava_showcase/guava_showcase.gltf", 512 * 1024);
    defer std.testing.allocator.free(gltf_bytes);
    const bin_bytes = try cwd.readFileAlloc(std.testing.allocator, "assets/models/guava_showcase/guava_showcase.bin", 4 * 1024 * 1024);
    defer std.testing.allocator.free(bin_bytes);
    const png_bytes = try cwd.readFileAlloc(std.testing.allocator, "assets/models/guava_showcase/checker.png", 512 * 1024);
    defer std.testing.allocator.free(png_bytes);

    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/guava_showcase/guava_showcase.gltf",
        .data = gltf_bytes,
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/guava_showcase/guava_showcase.bin",
        .data = bin_bytes,
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/models/guava_showcase/checker.png",
        .data = png_bytes,
    });

    var original = try cwd.openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var registry = registry_mod.AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.refreshProject("assets");

    const record = registry.recordByPath("assets/models/guava_showcase/guava_showcase.gltf") orelse return error.AssetNotFound;
    const first_path = try ensureCookedModelAsset(std.testing.allocator, &registry, record.id);
    const first_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, first_path, 8 * 1024 * 1024);
    defer std.testing.allocator.free(first_bytes);

    try std.fs.cwd().deleteFile(first_path);
    const second_path = try ensureCookedModelAsset(std.testing.allocator, &registry, record.id);
    const second_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, second_path, 8 * 1024 * 1024);
    defer std.testing.allocator.free(second_bytes);

    try std.testing.expectEqualStrings(first_path, second_path);
    try std.testing.expectEqualStrings(first_bytes, second_bytes);
    try validateCookedModelAsset(std.testing.allocator, &registry, record.id);
}

fn importStaticModelInternal(
    world: anytype,
    path: []const u8,
    root_transform: components.Transform,
    forced_parent: ?u64,
    create_root_instance: bool,
) !ImportReport {
    const allocator = world.allocator;
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(source);

    var document_parse = try std.json.parseFromSlice(GltfDocument, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer document_parse.deinit();
    const document = document_parse.value;

    if (!std.mem.startsWith(u8, document.asset.version, "2.")) {
        return error.UnsupportedGltfVersion;
    }

    const base_dir = std.fs.path.dirname(path) orelse ".";
    const source_stem = std.fs.path.stem(path);

    const loaded_buffers = try loadBuffers(allocator, base_dir, document.buffers orelse &.{});
    defer freeLoadedBuffers(allocator, loaded_buffers);

    const document_materials = document.materials orelse &.{};
    const material_handles = try allocator.alloc(?handles.MaterialHandle, document_materials.len);
    defer allocator.free(material_handles);
    @memset(material_handles, null);

    const document_textures = document.textures orelse &.{};
    const texture_handles = try allocator.alloc(?handles.TextureHandle, document_textures.len);
    defer allocator.free(texture_handles);
    @memset(texture_handles, null);

    const default_material = try world.resources.ensureDefaultMaterial();

    var report = ImportReport{};
    const import_parent = if (create_root_instance)
        try createImportRoot(world, path, root_transform, &report)
    else
        forced_parent;
    const scene_index = document.scene orelse 0;
    const document_scenes = document.scenes orelse return error.MissingScenes;
    if (scene_index >= document_scenes.len) {
        return error.SceneIndexOutOfBounds;
    }

    const root_nodes = document_scenes[scene_index].nodes orelse return error.MissingSceneNodes;
    for (root_nodes) |node_index| {
        try importNodeRecursive(
            world,
            document,
            loaded_buffers,
            material_handles,
            texture_handles,
            default_material,
            node_index,
            root_transform,
            import_parent,
            base_dir,
            source_stem,
            &report,
        );
    }

    return report;
}

fn importNodeRecursive(
    world: anytype,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_handles: []?handles.MaterialHandle,
    texture_handles: []?handles.TextureHandle,
    default_material: handles.MaterialHandle,
    node_index: u32,
    root_transform: components.Transform,
    import_parent: ?u64,
    base_dir: []const u8,
    source_stem: []const u8,
    report: *ImportReport,
) !void {
    const document_nodes = document.nodes orelse return error.MissingNodes;
    if (node_index >= document_nodes.len) {
        return error.NodeIndexOutOfBounds;
    }

    const node = document_nodes[node_index];

    // Create an entity for this glTF node
    const node_name = if (node.name) |n|
        try std.fmt.allocPrint(world.allocator, "{s}_{s}", .{ source_stem, n })
    else
        try std.fmt.allocPrint(world.allocator, "{s}_Node_{d}", .{ source_stem, node_index });
    defer world.allocator.free(node_name);

    const node_transform = nodeTransform(node);
    const node_entity_id = try world.createEntity(.{
        .name = node_name,
        .parent = import_parent,
        .local_transform = node_transform,
    });
    report.entity_count += 1;

    if (node.mesh) |mesh_index| {
        try importNodeMesh(
            world,
            document,
            loaded_buffers,
            material_handles,
            texture_handles,
            default_material,
            mesh_index,
            node,
            root_transform,
            node_entity_id,
            base_dir,
            source_stem,
            report,
        );
    }

    if (node.children) |children| {
        for (children) |child_index| {
            try importNodeRecursive(
                world,
                document,
                loaded_buffers,
                material_handles,
                texture_handles,
                default_material,
                child_index,
                root_transform,
                node_entity_id,
                base_dir,
                source_stem,
                report,
            );
        }
    }
}

fn importNodeMesh(
    world: anytype,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_handles: []?handles.MaterialHandle,
    texture_handles: []?handles.TextureHandle,
    default_material: handles.MaterialHandle,
    mesh_index: u32,
    node: Node,
    root_transform: components.Transform,
    import_parent: ?u64,
    base_dir: []const u8,
    source_stem: []const u8,
    report: *ImportReport,
) !void {
    const document_meshes = document.meshes orelse return error.MissingMeshes;
    if (mesh_index >= document_meshes.len) {
        return error.MeshIndexOutOfBounds;
    }

    const mesh = document_meshes[mesh_index];

    for (mesh.primitives, 0..) |primitive, primitive_index| {
        const mode = primitive.mode orelse 4;
        if (mode != 4) {
            return error.UnsupportedPrimitiveMode;
        }

        const mesh_handle = try createMeshForPrimitive(
            world,
            document,
            loaded_buffers,
            primitive,
            mesh.name,
            primitive_index,
        );
        const material = try resolveMaterialHandle(
            world,
            document,
            loaded_buffers,
            material_handles,
            texture_handles,
            default_material,
            primitive.material,
            base_dir,
            source_stem,
        );

        const entity_name = try entityNameForPrimitive(
            world.allocator,
            source_stem,
            node.name orelse mesh.name orelse "Node",
            primitive_index,
        );
        defer world.allocator.free(entity_name);

        _ = try world.createEntity(.{
            .name = entity_name,
            .parent = import_parent,
            .mesh = .{
                .handle = mesh_handle,
                .primitive = .custom,
            },
            .material = .{
                .handle = material.handle,
            },
            .local_transform = if (import_parent != null) .{} else root_transform,
        });

        report.entity_count += 1;
        report.mesh_count += 1;
        report.material_count += @intFromBool(material.created);
        report.texture_count += material.created_texture_count;
    }
}

fn createImportRoot(
    world: anytype,
    path: []const u8,
    root_transform: components.Transform,
    report: *ImportReport,
) !u64 {
    const source_stem = std.fs.path.stem(path);
    const root_name = try std.fmt.allocPrint(world.allocator, "{s} Instance", .{source_stem});
    defer world.allocator.free(root_name);

    const root_id = try world.createEntity(.{
        .name = root_name,
        .local_transform = root_transform,
    });
    report.root_entity = root_id;
    report.entity_count += 1;
    return root_id;
}

fn createMeshForPrimitive(
    world: anytype,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    primitive: Primitive,
    mesh_name: ?[]const u8,
    primitive_index: usize,
) !handles.MeshHandle {
    const position_accessor_index = attributeIndex(primitive.attributes, "POSITION") orelse return error.MissingPositions;
    const position_view = try accessorView(document, loaded_buffers, position_accessor_index);
    try requireAccessorFormat(position_view, "VEC3", 5126, error.UnsupportedPositionFormat);

    const normal_view = if (attributeIndex(primitive.attributes, "NORMAL")) |index| blk: {
        const view = try accessorView(document, loaded_buffers, index);
        try requireAccessorFormat(view, "VEC3", 5126, error.UnsupportedNormalFormat);
        break :blk view;
    } else null;

    const tangent_view = if (attributeIndex(primitive.attributes, "TANGENT")) |index| blk: {
        const view = try accessorView(document, loaded_buffers, index);
        try requireAccessorFormat(view, "VEC4", 5126, error.UnsupportedTangentFormat);
        break :blk view;
    } else null;

    const color_view = if (attributeIndex(primitive.attributes, "COLOR_0")) |index|
        try accessorView(document, loaded_buffers, index)
    else
        null;
    const uv_view = if (attributeIndex(primitive.attributes, "TEXCOORD_0")) |index|
        try accessorView(document, loaded_buffers, index)
    else
        null;

    try requireMatchingCount(normal_view, position_view.count);
    try requireMatchingCount(tangent_view, position_view.count);
    try requireMatchingCount(color_view, position_view.count);
    try requireMatchingCount(uv_view, position_view.count);

    const vertices = try world.allocator.alloc(mesh_mod.Vertex, position_view.count);
    defer world.allocator.free(vertices);

    for (vertices, 0..) |*vertex, index| {
        vertex.position = try readVec3(position_view, index);

        vertex.normal = if (normal_view) |view|
            normalize3(try readVec3(view, index))
        else
            .{ 0.0, 1.0, 0.0 };

        vertex.tangent = if (tangent_view) |view|
            try readVec4(view, index)
        else
            defaultTangent(vertex.normal);

        vertex.color = if (color_view) |view| try readColor(view, index) else .{ 1.0, 1.0, 1.0, 1.0 };
        vertex.uv = if (uv_view) |view| try readVec2(view, index) else .{ 0.0, 0.0 };
    }

    const indices = if (primitive.indices) |accessor_index|
        try readIndices(world.allocator, try accessorView(document, loaded_buffers, accessor_index))
    else
        try sequentialIndices(world.allocator, vertices.len);
    defer world.allocator.free(indices);

    const generated_name = try std.fmt.allocPrint(world.allocator, "{s}_mesh_{d}", .{
        mesh_name orelse "Mesh",
        primitive_index,
    });
    defer world.allocator.free(generated_name);

    return world.resources.createMesh(.{
        .name = generated_name,
        .vertices = vertices,
        .indices = indices,
    });
}

fn resolveMaterialHandle(
    world: anytype,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    material_handles: []?handles.MaterialHandle,
    texture_handles: []?handles.TextureHandle,
    default_material: handles.MaterialHandle,
    material_index: ?u32,
    base_dir: []const u8,
    source_stem: []const u8,
) !MaterialResolution {
    const index = material_index orelse return .{ .handle = default_material };
    const document_materials = document.materials orelse return .{ .handle = default_material };
    if (index >= document_materials.len) {
        return error.MaterialIndexOutOfBounds;
    }

    if (material_handles[index]) |handle| {
        return .{ .handle = handle };
    }

    const material = document_materials[index];
    const pbr = material.pbrMetallicRoughness;
    const base_color_factor = if (pbr) |value|
        value.baseColorFactor orelse .{ 1.0, 1.0, 1.0, 1.0 }
    else
        .{ 1.0, 1.0, 1.0, 1.0 };

    const base_color_texture = if (pbr) |value|
        try resolveTextureHandle(
            world,
            document,
            loaded_buffers,
            texture_handles,
            if (value.baseColorTexture) |info| info.index else null,
            base_dir,
            source_stem,
        )
    else
        TextureResolution{};

    const generated_name = try std.fmt.allocPrint(world.allocator, "{s}_material_{d}", .{
        source_stem,
        index,
    });
    defer world.allocator.free(generated_name);

    const handle = try world.resources.createMaterial(.{
        .name = material.name orelse generated_name,
        .shading = .pbr_metallic_roughness,
        .base_color_factor = base_color_factor,
        .base_color_texture = base_color_texture.handle,
    });
    material_handles[index] = handle;

    return .{
        .handle = handle,
        .created = true,
        .created_texture_count = @intFromBool(base_color_texture.created),
    };
}

fn resolveTextureHandle(
    world: anytype,
    document: GltfDocument,
    loaded_buffers: []const []u8,
    texture_handles: []?handles.TextureHandle,
    texture_index: ?u32,
    base_dir: []const u8,
    source_stem: []const u8,
) !TextureResolution {
    const index = texture_index orelse return .{};
    const document_textures = document.textures orelse return .{};
    const document_images = document.images orelse return .{};
    if (index >= document_textures.len) {
        return error.TextureIndexOutOfBounds;
    }

    if (texture_handles[index]) |handle| {
        return .{
            .handle = handle,
        };
    }

    const texture = document_textures[index];
    const image_index = texture.source orelse return error.TextureSourceMissing;
    if (image_index >= document_images.len) {
        return error.ImageIndexOutOfBounds;
    }

    const image = document_images[image_index];
    const encoded = try loadImageBytes(world.allocator, base_dir, image, document, loaded_buffers);
    defer world.allocator.free(encoded);

    var decoded = try image_decoder.decodeRgba8(world.allocator, encoded);
    defer decoded.deinit();
    swizzleRgbaToBgra(decoded.pixels);

    const generated_name = try std.fmt.allocPrint(world.allocator, "{s}_texture_{d}", .{
        source_stem,
        index,
    });
    defer world.allocator.free(generated_name);

    const handle = try world.resources.createTexture(.{
        .name = texture.name orelse image.name orelse generated_name,
        .width = decoded.width,
        .height = decoded.height,
        .format = .bgra8_unorm,
        .pixels = decoded.pixels,
    });
    texture_handles[index] = handle;

    return .{
        .handle = handle,
        .created = true,
    };
}

fn entityNameForPrimitive(
    allocator: std.mem.Allocator,
    source_stem: []const u8,
    node_name: []const u8,
    primitive_index: usize,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}_{d}", .{
        source_stem,
        node_name,
        primitive_index,
    });
}

fn loadBuffers(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    buffers: []const Buffer,
) ![][]u8 {
    const loaded = try allocator.alloc([]u8, buffers.len);
    errdefer allocator.free(loaded);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            allocator.free(loaded[index]);
        }
    }

    while (index < buffers.len) : (index += 1) {
        const buffer = buffers[index];
        const uri = buffer.uri orelse return error.UnsupportedGlbBuffer;
        loaded[index] = try loadBinaryUri(allocator, base_dir, uri);
    }

    return loaded;
}

fn freeLoadedBuffers(allocator: std.mem.Allocator, buffers: [][]u8) void {
    for (buffers) |buffer| {
        allocator.free(buffer);
    }
    allocator.free(buffers);
}

fn loadImageBytes(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    image: Image,
    document: GltfDocument,
    loaded_buffers: []const []u8,
) ![]u8 {
    if (image.uri) |uri| {
        return loadBinaryUri(allocator, base_dir, uri);
    }
    if (image.bufferView) |buffer_view_index| {
        const bytes = try bufferViewBytes(document, loaded_buffers, buffer_view_index);
        return allocator.dupe(u8, bytes);
    }
    return error.UnsupportedImageSource;
}

fn loadBinaryUri(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    uri: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, uri, "data:")) {
        const comma_index = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;
        const header = uri[0..comma_index];
        if (std.mem.indexOf(u8, header, ";base64") == null) {
            return error.UnsupportedDataUriEncoding;
        }
        const encoded = uri[comma_index + 1 ..];
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try allocator.alloc(u8, decoded_len);
        errdefer allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        return decoded;
    }

    const resolved_path = try std.fs.path.join(allocator, &.{ base_dir, uri });
    defer allocator.free(resolved_path);
    return std.fs.cwd().readFileAlloc(allocator, resolved_path, 128 * 1024 * 1024);
}

fn bufferViewBytes(
    document: GltfDocument,
    loaded_buffers: []const []u8,
    buffer_view_index: u32,
) ![]const u8 {
    const buffer_views = document.bufferViews orelse return error.MissingBufferViews;
    if (buffer_view_index >= buffer_views.len) {
        return error.BufferViewIndexOutOfBounds;
    }

    const buffer_view = buffer_views[buffer_view_index];
    if (buffer_view.buffer >= loaded_buffers.len) {
        return error.BufferIndexOutOfBounds;
    }

    const buffer = loaded_buffers[buffer_view.buffer];
    const start = buffer_view.byteOffset orelse 0;
    const end = start + buffer_view.byteLength;
    if (end > buffer.len) {
        return error.BufferSliceOutOfBounds;
    }

    return buffer[start..end];
}

fn accessorView(document: GltfDocument, loaded_buffers: []const []u8, accessor_index: u32) !AccessorView {
    const accessors = document.accessors orelse return error.MissingAccessors;
    const buffer_views = document.bufferViews orelse return error.MissingBufferViews;
    if (accessor_index >= accessors.len) {
        return error.AccessorIndexOutOfBounds;
    }

    const accessor = accessors[accessor_index];
    const buffer_view_index = accessor.bufferView orelse return error.UnsupportedSparseAccessor;
    if (buffer_view_index >= buffer_views.len) {
        return error.BufferViewIndexOutOfBounds;
    }

    const buffer_view = buffer_views[buffer_view_index];
    if (buffer_view.buffer >= loaded_buffers.len) {
        return error.BufferIndexOutOfBounds;
    }

    const component_size = componentByteSize(accessor.componentType) orelse return error.UnsupportedAccessorComponentType;
    const component_count = componentCount(accessor.type) orelse return error.UnsupportedAccessorShape;
    const element_size = component_size * component_count;
    const stride = buffer_view.byteStride orelse element_size;
    if (stride < element_size) {
        return error.InvalidBufferStride;
    }

    const buffer = loaded_buffers[buffer_view.buffer];
    const start = (buffer_view.byteOffset orelse 0) + (accessor.byteOffset orelse 0);
    const required = if (accessor.count == 0) 0 else ((accessor.count - 1) * stride) + element_size;
    if (start + required > buffer.len) {
        return error.BufferSliceOutOfBounds;
    }

    return .{
        .bytes = buffer[start .. start + required],
        .stride = stride,
        .count = accessor.count,
        .component_type = accessor.componentType,
        .normalized = accessor.normalized,
        .type = accessor.type,
    };
}

fn attributeIndex(attributes: std.json.Value, name: []const u8) ?u32 {
    const object = switch (attributes) {
        .object => |value| value,
        else => return null,
    };
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| @intCast(number),
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn requireAccessorFormat(view: AccessorView, expected_type: []const u8, expected_component: u32, err: anyerror) !void {
    if (!std.mem.eql(u8, view.type, expected_type) or view.component_type != expected_component) {
        return err;
    }
}

fn requireMatchingCount(view: ?AccessorView, expected: usize) !void {
    if (view) |value| {
        if (value.count != expected) {
            return error.AttributeCountMismatch;
        }
    }
}

fn readVec2(view: AccessorView, index: usize) ![2]f32 {
    if (!std.mem.eql(u8, view.type, "VEC2")) {
        return error.InvalidAccessorType;
    }

    return .{
        try componentAsF32(view, index, 0),
        try componentAsF32(view, index, 1),
    };
}

fn readVec3(view: AccessorView, index: usize) ![3]f32 {
    if (!std.mem.eql(u8, view.type, "VEC3")) {
        return error.InvalidAccessorType;
    }

    return .{
        try componentAsF32(view, index, 0),
        try componentAsF32(view, index, 1),
        try componentAsF32(view, index, 2),
    };
}

fn readVec4(view: AccessorView, index: usize) ![4]f32 {
    if (!std.mem.eql(u8, view.type, "VEC4")) {
        return error.InvalidAccessorType;
    }

    return .{
        try componentAsF32(view, index, 0),
        try componentAsF32(view, index, 1),
        try componentAsF32(view, index, 2),
        try componentAsF32(view, index, 3),
    };
}

fn readColor(view: AccessorView, index: usize) ![4]f32 {
    if (std.mem.eql(u8, view.type, "VEC3")) {
        return .{
            try componentAsF32(view, index, 0),
            try componentAsF32(view, index, 1),
            try componentAsF32(view, index, 2),
            1.0,
        };
    }
    if (std.mem.eql(u8, view.type, "VEC4")) {
        return try readVec4(view, index);
    }
    return error.InvalidAccessorType;
}

fn readIndices(allocator: std.mem.Allocator, view: AccessorView) ![]u32 {
    if (!std.mem.eql(u8, view.type, "SCALAR")) {
        return error.InvalidAccessorType;
    }

    const indices = try allocator.alloc(u32, view.count);
    errdefer allocator.free(indices);

    for (indices, 0..) |*index_value, index| {
        index_value.* = switch (view.component_type) {
            5121 => componentAsUnsigned(u8, view, index, 0),
            5123 => componentAsUnsigned(u16, view, index, 0),
            5125 => componentAsUnsigned(u32, view, index, 0),
            else => return error.UnsupportedIndexFormat,
        };
    }

    return indices;
}

fn sequentialIndices(allocator: std.mem.Allocator, count: usize) ![]u32 {
    const indices = try allocator.alloc(u32, count);
    errdefer allocator.free(indices);

    for (indices, 0..) |*index_value, index| {
        index_value.* = @intCast(index);
    }
    return indices;
}

fn componentAsF32(view: AccessorView, index: usize, component_index: usize) !f32 {
    const component_size = componentByteSize(view.component_type) orelse unreachable;
    const bytes = elementBytes(view, index);
    const start = component_index * component_size;
    const component_bytes = bytes[start .. start + component_size];

    return switch (view.component_type) {
        5126 => std.mem.bytesToValue(f32, component_bytes),
        5121 => if (view.normalized)
            @as(f32, @floatFromInt(std.mem.bytesToValue(u8, component_bytes))) / 255.0
        else
            @floatFromInt(std.mem.bytesToValue(u8, component_bytes)),
        5123 => if (view.normalized)
            @as(f32, @floatFromInt(std.mem.bytesToValue(u16, component_bytes))) / 65535.0
        else
            @floatFromInt(std.mem.bytesToValue(u16, component_bytes)),
        else => error.UnsupportedVertexFormat,
    };
}

fn componentAsUnsigned(comptime T: type, view: AccessorView, index: usize, component_index: usize) u32 {
    const component_size = componentByteSize(view.component_type) orelse unreachable;
    const bytes = elementBytes(view, index);
    const start = component_index * component_size;
    const component_bytes = bytes[start .. start + component_size];
    return @as(u32, std.mem.bytesToValue(T, component_bytes));
}

fn elementBytes(view: AccessorView, index: usize) []const u8 {
    const component_size = componentByteSize(view.component_type) orelse unreachable;
    const element_size = component_size * (componentCount(view.type) orelse unreachable);
    const start = index * view.stride;
    return view.bytes[start .. start + element_size];
}

fn componentByteSize(component_type: u32) ?usize {
    return switch (component_type) {
        5121 => 1,
        5123 => 2,
        5125 => 4,
        5126 => 4,
        else => null,
    };
}

fn componentCount(type_name: []const u8) ?usize {
    if (std.mem.eql(u8, type_name, "SCALAR")) return 1;
    if (std.mem.eql(u8, type_name, "VEC2")) return 2;
    if (std.mem.eql(u8, type_name, "VEC3")) return 3;
    if (std.mem.eql(u8, type_name, "VEC4")) return 4;
    return null;
}

fn nodeTransform(node: Node) components.Transform {
    if (node.matrix) |m| {
        // Simple decomposition for glTF's column-major matrix
        const translation = components.Vec3{ m[12], m[13], m[14] };

        // Extraction of scale
        const s_x = std.math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
        const s_y = std.math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
        const s_z = std.math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);
        const scale = components.Vec3{ s_x, s_y, s_z };

        // Extraction of rotation (normalized matrix)
        const quat = @import("../math/quat.zig");
        const r_m = [_]f32{
            m[0] / s_x, m[1] / s_x, m[2] / s_x, 0.0,
            m[4] / s_y, m[5] / s_y, m[6] / s_y, 0.0,
            m[8] / s_z, m[9] / s_z, m[10] / s_z, 0.0,
            0.0,        0.0,        0.0,         1.0,
        };
        const rotation = quat.fromRotationMatrix(r_m);

        return .{
            .translation = translation,
            .rotation = rotation,
            .scale = scale,
        };
    }
    return .{
        .translation = node.translation orelse .{ 0.0, 0.0, 0.0 },
        .rotation = node.rotation orelse .{ 0.0, 0.0, 0.0, 1.0 },
        .scale = node.scale orelse .{ 1.0, 1.0, 1.0 },
    };
}

fn nodeMatrix(node: Node) math.Mat4 {
    if (node.matrix) |matrix_value| {
        return matrix_value;
    }

    const translation_value = node.translation orelse .{ 0.0, 0.0, 0.0 };
    const rotation_value = node.rotation orelse .{ 0.0, 0.0, 0.0, 1.0 };
    const scale_value = node.scale orelse .{ 1.0, 1.0, 1.0 };

    return math.mul(
        math.translation(translation_value),
        math.mul(quaternionMatrix(rotation_value), math.scale(scale_value)),
    );
}

fn quaternionMatrix(quaternion: [4]f32) math.Mat4 {
    const x = quaternion[0];
    const y = quaternion[1];
    const z = quaternion[2];
    const w = quaternion[3];

    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    const xy = x * y;
    const xz = x * z;
    const yz = y * z;
    const wx = w * x;
    const wy = w * y;
    const wz = w * z;

    return .{
        1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz),       2.0 * (xz - wy),       0.0,
        2.0 * (xy - wz),       1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx),       0.0,
        2.0 * (xz + wy),       2.0 * (yz - wx),       1.0 - 2.0 * (xx + yy), 0.0,
        0.0,                   0.0,                   0.0,                   1.0,
    };
}

fn transformPoint(matrix_value: math.Mat4, point: [3]f32) [3]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14],
    };
}

fn transformDirection(matrix_value: math.Mat4, direction: [3]f32) [3]f32 {
    return .{
        matrix_value[0] * direction[0] + matrix_value[4] * direction[1] + matrix_value[8] * direction[2],
        matrix_value[1] * direction[0] + matrix_value[5] * direction[1] + matrix_value[9] * direction[2],
        matrix_value[2] * direction[0] + matrix_value[6] * direction[1] + matrix_value[10] * direction[2],
    };
}

fn transformTangent(matrix_value: math.Mat4, tangent: [4]f32) [4]f32 {
    const xyz = normalize3(transformDirection(matrix_value, .{ tangent[0], tangent[1], tangent[2] }));
    return .{ xyz[0], xyz[1], xyz[2], tangent[3] };
}

fn normalize3(value: [3]f32) [3]f32 {
    const length = std.math.sqrt(value[0] * value[0] + value[1] * value[1] + value[2] * value[2]);
    if (length <= std.math.floatEps(f32)) {
        return .{ 0.0, 1.0, 0.0 };
    }
    const inverse = 1.0 / length;
    return .{
        value[0] * inverse,
        value[1] * inverse,
        value[2] * inverse,
    };
}

fn defaultTangent(normal: [3]f32) [4]f32 {
    if (@abs(normal[1]) > 0.8) {
        return .{ 1.0, 0.0, 0.0, 1.0 };
    }
    return .{ 0.0, 1.0, 0.0, 1.0 };
}

fn swizzleRgbaToBgra(bytes: []u8) void {
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        const r = bytes[index];
        bytes[index] = bytes[index + 2];
        bytes[index + 2] = r;
    }
}
