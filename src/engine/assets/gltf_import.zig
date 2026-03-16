const std = @import("std");
const handles = @import("handles.zig");
const image_decoder = @import("image_decoder.zig");
const mesh_mod = @import("mesh_resource.zig");
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
};

const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
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
            math.identity(),
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
    parent_matrix: math.Mat4,
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
    const node_world = math.mul(parent_matrix, nodeMatrix(node));

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
            node_world,
            root_transform,
            import_parent,
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
                node_world,
                root_transform,
                import_parent,
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
    node_world: math.Mat4,
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
            node_world,
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
            .transform = if (import_parent != null) .{} else root_transform,
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
        .transform = root_transform,
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
    node_world: math.Mat4,
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
        const position = try readVec3(position_view, index);
        vertex.position = transformPoint(node_world, position);

        vertex.normal = if (normal_view) |view|
            normalize3(transformDirection(node_world, try readVec3(view, index)))
        else
            .{ 0.0, 1.0, 0.0 };

        vertex.tangent = if (tangent_view) |view|
            transformTangent(node_world, try readVec4(view, index))
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
