const std = @import("std");
const assets_handles = @import("../assets/handles.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("components.zig");
const world_mod = @import("world.zig");

const SceneFile = struct {
    version: u32 = 1,
    meshes: []MeshRecord,
    textures: []TextureRecord,
    materials: []MaterialRecord,
    entities: []EntityRecord,
};

const MeshRecord = struct {
    name: []const u8,
    primitive_type: rhi_types.PrimitiveType,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const TextureRecord = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels_hex: []const u8,
};

const MaterialRecord = struct {
    name: []const u8,
    shading: components.ShadingModel,
    base_color_factor: [4]f32,
    base_color_texture: ?u32 = null,
};

const MeshComponentRecord = struct {
    resource: ?u32 = null,
    primitive: components.Primitive = .custom,
};

const MaterialComponentRecord = struct {
    resource: ?u32 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const EntityRecord = struct {
    name: []const u8,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?MeshComponentRecord = null,
    material: ?MaterialComponentRecord = null,
    light: ?components.Light = null,
    editor_only: bool = false,
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
    var parsed = try std.json.parseFromSlice(SceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 1) {
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

    for (scene.entities) |entity| {
        _ = try world.createEntity(.{
            .name = entity.name,
            .transform = entity.transform,
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
            .editor_only = entity.editor_only,
        });
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
    var entity_records = std.ArrayList(EntityRecord).empty;
    defer entity_records.deinit(allocator);

    var mesh_indices = std.AutoHashMap(assets_handles.MeshHandle, u32).init(allocator);
    defer mesh_indices.deinit();
    var texture_indices = std.AutoHashMap(assets_handles.TextureHandle, u32).init(allocator);
    defer texture_indices.deinit();
    var material_indices = std.AutoHashMap(assets_handles.MaterialHandle, u32).init(allocator);
    defer material_indices.deinit();

    for (world.entities.items) |entity| {
        if (entity.editor_only) {
            continue;
        }

        const mesh_component = if (entity.mesh) |mesh|
            MeshComponentRecord{
                .resource = if (mesh.handle) |mesh_handle|
                    try ensureMeshRecord(
                        allocator,
                        world,
                        mesh_handle,
                        &mesh_indices,
                        &mesh_records,
                        &material_indices,
                        &material_records,
                        &texture_indices,
                        &texture_records,
                    )
                else
                    null,
                .primitive = mesh.primitive,
            }
        else
            null;

        const material_component = if (entity.material) |material|
            MaterialComponentRecord{
                .resource = if (material.handle) |material_handle|
                    try ensureMaterialRecord(
                        allocator,
                        world,
                        material_handle,
                        &material_indices,
                        &material_records,
                        &texture_indices,
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
            .transform = entity.transform,
            .camera = entity.camera,
            .mesh = mesh_component,
            .material = material_component,
            .light = entity.light,
            .editor_only = entity.editor_only,
        });
    }

    return .{
        .version = 1,
        .meshes = try mesh_records.toOwnedSlice(allocator),
        .textures = try texture_records.toOwnedSlice(allocator),
        .materials = try material_records.toOwnedSlice(allocator),
        .entities = try entity_records.toOwnedSlice(allocator),
    };
}

fn ensureMeshRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MeshHandle,
    mesh_indices: *std.AutoHashMap(assets_handles.MeshHandle, u32),
    mesh_records: *std.ArrayList(MeshRecord),
    material_indices: *std.AutoHashMap(assets_handles.MaterialHandle, u32),
    material_records: *std.ArrayList(MaterialRecord),
    texture_indices: *std.AutoHashMap(assets_handles.TextureHandle, u32),
    texture_records: *std.ArrayList(TextureRecord),
) !u32 {
    _ = material_indices;
    _ = material_records;
    _ = texture_indices;
    _ = texture_records;

    if (mesh_indices.get(handle)) |index| {
        return index;
    }

    const mesh = world.resources.mesh(handle) orelse return error.MeshNotFound;
    const index: u32 = @intCast(mesh_records.items.len);
    try mesh_records.append(allocator, .{
        .name = mesh.name,
        .primitive_type = mesh.primitive_type,
        .vertices = mesh.vertices,
        .indices = mesh.indices,
    });
    try mesh_indices.put(handle, index);
    return index;
}

fn ensureMaterialRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MaterialHandle,
    material_indices: *std.AutoHashMap(assets_handles.MaterialHandle, u32),
    material_records: *std.ArrayList(MaterialRecord),
    texture_indices: *std.AutoHashMap(assets_handles.TextureHandle, u32),
    texture_records: *std.ArrayList(TextureRecord),
) !u32 {
    if (material_indices.get(handle)) |index| {
        return index;
    }

    const material = world.resources.material(handle) orelse return error.MaterialNotFound;
    const index: u32 = @intCast(material_records.items.len);
    try material_records.append(allocator, .{
        .name = material.name,
        .shading = material.shading,
        .base_color_factor = material.base_color_factor,
        .base_color_texture = if (material.base_color_texture) |texture_handle|
            try ensureTextureRecord(allocator, world, texture_handle, texture_indices, texture_records)
        else
            null,
    });
    try material_indices.put(handle, index);
    return index;
}

fn ensureTextureRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.TextureHandle,
    texture_indices: *std.AutoHashMap(assets_handles.TextureHandle, u32),
    texture_records: *std.ArrayList(TextureRecord),
) !u32 {
    if (texture_indices.get(handle)) |index| {
        return index;
    }

    const texture = world.resources.texture(handle) orelse return error.TextureNotFound;
    const index: u32 = @intCast(texture_records.items.len);
    try texture_records.append(allocator, .{
        .name = texture.name,
        .width = texture.width,
        .height = texture.height,
        .format = texture.format,
        .pixels_hex = try encodeHexAlloc(allocator, texture.pixels),
    });
    try texture_indices.put(handle, index);
    return index;
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

test "scene serialization round-trips meshes, lights, and textures" {
    var world = world_mod.World.init(std.testing.allocator);
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

    var loaded = world_mod.World.init(std.testing.allocator);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const summary = loaded.summary();
    try std.testing.expectEqual(@as(usize, 7), summary.entity_count);
    try std.testing.expectEqual(@as(usize, 5), summary.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), summary.light_count);
    try std.testing.expect(loaded.findEntityByName("PointLight") != null);
    try std.testing.expect(loaded.findEntityByName("guava_showcase_GuavaShowcase_0") != null);

    const imported = loaded.findEntityByName("guava_showcase_GuavaShowcase_0").?;
    const mesh = loaded.resources.mesh(imported.mesh.?.handle.?).?;
    const material = loaded.resources.material(imported.material.?.handle.?).?;
    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expect(material.base_color_texture != null);
}
