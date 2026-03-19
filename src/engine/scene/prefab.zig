const std = @import("std");
const asset_registry = @import("../assets/registry.zig");
const assets_handles = @import("../assets/handles.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("components.zig");
const world_mod = @import("world.zig");
const scene_io = @import("scene_io.zig");

const current_prefab_version: u32 = 1;

/// Prefab ID 格式: prefab://assets/prefabs/hero/v1
pub const PrefabId = []const u8;

/// Prefab 文件结构 (版本 1)
const PrefabFile = struct {
    version: u32 = current_prefab_version,
    prefab_id: []const u8,
    root_entity_name: []const u8,
    asset_records: []asset_registry.AssetRecord,
    meshes: []scene_io.MeshRecord,
    textures: []scene_io.TextureRecord,
    materials: []scene_io.MaterialRecord,
    /// 扁平化存储的实体数组，通过 parent 字段建立关系
    entities: []PrefabEntityRecord,
};

/// Prefab 中的实体记录
const PrefabEntityRecord = struct {
    /// 实体在原始 Prefab 中的唯一标识 (用于实例化时映射)
    prefab_entity_id: u32,
    name: []const u8,
    parent: ?u32 = null, // 指向父实体的 prefab_entity_id
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?scene_io.MeshComponentRecord = null,
    rigidbody: ?scene_io.RigidbodyRecord = null,
    box_collider: ?scene_io.BoxColliderRecord = null,
    sphere_collider: ?scene_io.SphereColliderRecord = null,
    mesh_collider: ?scene_io.MeshColliderRecord = null,
    material: ?scene_io.MaterialComponentRecord = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    /// 引用的嵌套 Prefab ID
    nested_prefab_id: ?[]const u8 = null,
};

/// Prefab 资源
pub const PrefabResource = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    name: []u8,
    source_path: ?[]u8 = null,
    version: u32 = 1,
    /// 扁平化存储的实体数据
    entities: []PrefabEntityData,
    /// 资源引用映射 (asset_id -> handle)
    mesh_asset_bindings: std.AutoHashMap([]const u8, assets_handles.MeshHandle),
    texture_asset_bindings: std.AutoHashMap([]const u8, assets_handles.TextureHandle),
    material_asset_bindings: std.AutoHashMap([]const u8, assets_handles.MaterialHandle),
    /// 嵌套 Prefab 引用
    nested_prefab_ids: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) PrefabResource {
        return .{
            .allocator = allocator,
            .id = allocator.dupe(u8, id) catch unreachable,
            .name = allocator.dupe(u8, name) catch unreachable,
            .entities = &.{},
            .mesh_asset_bindings = std.AutoHashMap([]const u8, assets_handles.MeshHandle).init(allocator),
            .texture_asset_bindings = std.AutoHashMap([]const u8, assets_handles.TextureHandle).init(allocator),
            .material_asset_bindings = std.AutoHashMap([]const u8, assets_handles.MaterialHandle).init(allocator),
            .nested_prefab_ids = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *PrefabResource) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        if (self.source_path) |path| self.allocator.free(path);
        for (self.entities) |*entity| {
            entity.deinit(self.allocator);
        }
        self.allocator.free(self.entities);
        self.mesh_asset_bindings.deinit();
        self.texture_asset_bindings.deinit();
        self.material_asset_bindings.deinit();
        for (self.nested_prefab_ids.items) |prefab_id| {
            self.allocator.free(prefab_id);
        }
        self.nested_prefab_ids.deinit();
    }
};

/// Prefab 中的实体数据 (运行时使用)
pub const PrefabEntityData = struct {
    /// 在原始 Prefab 中的唯一标识
    prefab_entity_id: u32,
    name: []u8,
    parent: ?u32 = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    skinned_mesh: ?components.SkinnedMesh = null,
    animator: ?components.Animator = null,
    rigidbody: ?components.Rigidbody = null,
    box_collider: ?components.BoxCollider = null,
    sphere_collider: ?components.SphereCollider = null,
    mesh_collider: ?components.MeshCollider = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?components.Script = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    /// 引用的嵌套 Prefab ID
    nested_prefab_id: ?[]u8 = null,

    pub fn deinit(self: *PrefabEntityData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.nested_prefab_id) |id| allocator.free(id);
    }
};

/// Prefab 实例覆盖数据 - 存储在实体上
pub const PrefabInstanceOverride = struct {
    /// 实例所属的 Prefab ID
    prefab_id: []u8,
    /// Prefab 版本号
    prefab_version: u32,
    /// 根实体在 Prefab 中的 entity_id
    root_prefab_entity_id: u32,
    /// 覆盖的字段掩码
    override_mask: OverrideMask = .{},
    /// 覆盖的变换
    local_transform_override: ?components.Transform = null,
    /// 覆盖的名称
    name_override: ?[]u8 = null,
    /// 覆盖的可见性
    visible_override: ?bool = null,

    pub fn deinit(self: *PrefabInstanceOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.prefab_id);
        if (self.name_override) |name| allocator.free(name);
    }
};

/// 覆盖字段掩码
pub const OverrideMask = struct {
    local_transform: bool = false,
    name: bool = false,
    visible: bool = false,
    mesh: bool = false,
    material: bool = false,
    light: bool = false,
    camera: bool = false,
    rigidbody: bool = false,
    collider: bool = false,
    vfx: bool = false,
    script: bool = false,
};

/// Prefab 实例化选项
pub const InstantiateOptions = struct {
    /// 实例名称前缀
    name_prefix: ?[]const u8 = null,
    /// 实例化后的根变换
    transform: components.Transform = .{},
    /// 是否立即初始化资源
    load_resources: bool = true,
};

/// 从 Prefab 序列化
pub fn serializePrefabAlloc(
    allocator: std.mem.Allocator,
    prefab: *const PrefabResource,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 构建 PrefabFile
    const prefab_file = try buildPrefabFile(arena, prefab);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(prefab_file, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

/// 从 JSON 反序列化
pub fn deserializePrefabFromSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
) !PrefabResource {
    var header_parse = try std.json.parseFromSlice(PrefabHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    switch (header_parse.value.version) {
        1 => return try deserializePrefabV1FromSlice(allocator, source),
        else => return error.UnsupportedPrefabVersion,
    }
}

/// 保存 Prefab 到文件
pub fn savePrefabToPath(
    allocator: std.mem.Allocator,
    prefab: *const PrefabResource,
    path: []const u8,
) !void {
    const encoded = try serializePrefabAlloc(allocator, prefab);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = encoded,
    });
}

/// 从文件加载 Prefab
pub fn loadPrefabFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !PrefabResource {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(source);
    return try deserializePrefabFromSlice(allocator, source);
}

/// 创建 Prefab (从 World 中的实体树)
pub fn createPrefabFromEntities(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    root_entity_id: world_mod.EntityId,
    prefab_id: []const u8,
) !PrefabResource {
    var prefab = PrefabResource.init(allocator, prefab_id, prefab_id);

    // 获取根实体
    const root_entity = world.getEntityConst(root_entity_id) orelse return error.EntityNotFound;

    // 构建实体列表 (扁平化)
    var entity_list = std.ArrayList(world_mod.EntityId).init(allocator);
    defer entity_list.deinit();

    try collectEntitiesRecursive(root_entity_id, world, &entity_list);

    // 转换实体数据
    var entity_data_list = std.ArrayList(PrefabEntityData).init(allocator);
    defer {
        for (entity_data_list.items) |*ed| {
            ed.deinit(allocator);
        }
        entity_data_list.deinit(allocator);
    }

    // 创建 prefab_entity_id 到数组索引的映射
    var entity_id_map = std.AutoHashMap(world_mod.EntityId, u32).init(allocator);
    defer entity_id_map.deinit();

    for (entity_list.items, 0..) |entity_id, index| {
        try entity_id_map.put(entity_id, @intCast(index));
    }

    for (entity_list.items) |entity_id| {
        const entity = world.getEntityConst(entity_id).?;

        // 复制实体名称
        var entity_name = try allocator.dupe(u8, entity.name);
        errdefer allocator.free(entity_name);

        // 处理嵌套 Prefab 引用
        var nested_prefab_id: ?[]u8 = null;
        if (entity.prefab_instance_override) |override| {
            nested_prefab_id = try allocator.dupe(u8, override.prefab_id);
            errdefer if (nested_prefab_id) |id| allocator.free(id);
        }

        try entity_data_list.append(allocator, .{
            .prefab_entity_id = entity_id_map.get(entity_id).?,
            .name = entity_name,
            .parent = if (entity.parent) |parent_id| entity_id_map.get(parent_id) else null,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = entity.mesh,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .material = entity.material,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = entity.script,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
            .nested_prefab_id = nested_prefab_id,
        });

        // 收集嵌套 Prefab ID
        if (nested_prefab_id != null) {
            try prefab.nested_prefab_ids.append(allocator, try allocator.dupe(u8, nested_prefab_id.?));
        }
    }

    prefab.entities = try entity_data_list.toOwnedSlice();

    return prefab;
}

/// 实例化 Prefab 到 World
pub fn instantiatePrefab(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    prefab: *const PrefabResource,
    options: InstantiateOptions,
) !world_mod.EntityId {
    if (prefab.entities.len == 0) {
        return error.EmptyPrefab;
    }

    // 创建 prefab_entity_id 到新实体 ID 的映射
    var entity_id_map = std.AutoHashMap(u32, world_mod.EntityId).init(allocator);
    defer entity_id_map.deinit();

    // 创建实体
    for (prefab.entities) |prefab_entity| {
        // 构建 EntityDesc
        var desc = world_mod.EntityDesc{
            .name = if (options.name_prefix) |prefix|
                try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, prefab_entity.name })
            else
                try allocator.dupe(u8, prefab_entity.name),
        };
        defer allocator.free(desc.name);

        desc.local_transform = prefab_entity.local_transform;
        desc.camera = prefab_entity.camera;
        desc.mesh = prefab_entity.mesh;
        desc.rigidbody = prefab_entity.rigidbody;
        desc.box_collider = prefab_entity.box_collider;
        desc.sphere_collider = prefab_entity.sphere_collider;
        desc.mesh_collider = prefab_entity.mesh_collider;
        desc.material = prefab_entity.material;
        desc.light = prefab_entity.light;
        desc.vfx = prefab_entity.vfx;
        desc.visible = prefab_entity.visible;
        desc.editor_only = prefab_entity.editor_only;
        desc.is_folder = prefab_entity.is_folder;

        // 处理父关系
        if (prefab_entity.parent) |parent_prefab_id| {
            if (entity_id_map.get(parent_prefab_id)) |parent_entity_id| {
                desc.parent = parent_entity_id;
            }
        }

        const entity_id = try world.createEntity(desc);
        try entity_id_map.put(prefab_entity.prefab_entity_id, entity_id);

        // 应用初始变换偏移 (如果是根实体)
        if (prefab_entity.parent == null) {
            const entity = world.getEntity(entity_id).?;
            entity.local_transform = .{
                .translation = .{
                    entity.local_transform.translation[0] + options.transform.translation[0],
                    entity.local_transform.translation[1] + options.transform.translation[1],
                    entity.local_transform.translation[2] + options.transform.translation[2],
                },
                .rotation = options.transform.rotation,
                .scale = .{
                    entity.local_transform.scale[0] * options.transform.scale[0],
                    entity.local_transform.scale[1] * options.transform.scale[1],
                    entity.local_transform.scale[2] * options.transform.scale[2],
                },
            };
        }
    }

    // 第一个创建的实体作为根实体返回
    if (prefab.entities.len > 0) {
        return entity_id_map.get(0).?;
    }

    return error.InvalidPrefab;
}

/// 生成 Prefab ID
pub fn makePrefabIdAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    version: u32,
) ![]u8 {
    return try std.fmt.allocPrint(allocator, "prefab://{s}/v{d}", .{ path, version });
}

// ============================================================================
// 内部函数
// ============================================================================

const PrefabHeader = struct {
    version: u32 = 1,
};

fn collectEntitiesRecursive(
    entity_id: world_mod.EntityId,
    world: *const world_mod.World,
    list: *std.ArrayList(world_mod.EntityId),
) !void {
    try list.append(entity_id);
    const entity = world.getEntityConst(entity_id) orelse return;
    for (entity.children.items) |child_id| {
        try collectEntitiesRecursive(child_id, world, list);
    }
}

fn buildPrefabFile(allocator: std.mem.Allocator, prefab: *const PrefabResource) !PrefabFile {
    var asset_records = std.ArrayList(asset_registry.AssetRecord).empty;
    defer asset_records.deinit(allocator);

    var entity_records = std.ArrayList(PrefabEntityRecord).empty;
    defer entity_records.deinit(allocator);

    // 转换实体数据到记录
    for (prefab.entities) |entity| {
        try entity_records.append(allocator, .{
            .prefab_entity_id = entity.prefab_entity_id,
            .name = entity.name,
            .parent = entity.parent,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh| .{
                .asset_id = null, // TODO: 资源绑定
                .primitive = mesh.primitive,
            } else null,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .material = if (entity.material) |mat| .{
                .asset_id = null,
                .shading = mat.shading,
                .base_color_factor = mat.base_color_factor,
            } else null,
            .light = entity.light,
            .vfx = entity.vfx,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
            .nested_prefab_id = entity.nested_prefab_id,
        });
    }

    return .{
        .prefab_id = prefab.id,
        .root_entity_name = if (prefab.entities.len > 0) prefab.entities[0].name else "",
        .asset_records = try asset_records.toOwnedSlice(allocator),
        .meshes = &.{},
        .textures = &.{},
        .materials = &.{},
        .entities = try entity_records.toOwnedSlice(allocator),
    };
}

fn deserializePrefabV1FromSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
) !PrefabResource {
    var parsed = try std.json.parseFromSlice(PrefabFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const prefab_file = parsed.value;
    if (prefab_file.version != 1) {
        return error.UnsupportedPrefabVersion;
    }

    var prefab = PrefabResource.init(allocator, prefab_file.prefab_id, prefab_file.root_entity_name);
    prefab.version = prefab_file.version;

    // 转换记录到实体数据
    var entity_data_list = std.ArrayList(PrefabEntityData).init(allocator);
    defer {
        for (entity_data_list.items) |*ed| {
            ed.deinit(allocator);
        }
        entity_data_list.deinit(allocator);
    }

    for (prefab_file.entities) |record| {
        try entity_data_list.append(allocator, .{
            .prefab_entity_id = record.prefab_entity_id,
            .name = try allocator.dupe(u8, record.name),
            .parent = record.parent,
            .local_transform = record.local_transform,
            .camera = record.camera,
            .mesh = if (record.mesh) |mesh| .{
                .handle = null,
                .primitive = mesh.primitive,
            } else null,
            .rigidbody = record.rigidbody,
            .box_collider = record.box_collider,
            .sphere_collider = record.sphere_collider,
            .mesh_collider = record.mesh_collider,
            .material = if (record.material) |mat| .{
                .handle = null,
                .shading = mat.shading,
                .base_color_factor = mat.base_color_factor,
            } else null,
            .light = record.light,
            .vfx = record.vfx,
            .visible = record.visible,
            .editor_only = record.editor_only,
            .is_folder = record.is_folder,
            .nested_prefab_id = if (record.nested_prefab_id) |id|
                try allocator.dupe(u8, id)
            else
                null,
        });

        // 收集嵌套 Prefab ID
        if (record.nested_prefab_id) |id| {
            try prefab.nested_prefab_ids.append(allocator, try allocator.dupe(u8, id));
        }
    }

    prefab.entities = try entity_data_list.toOwnedSlice();

    return prefab;
}

/// Diff 检测 - 比较两个 Prefab 版本
pub fn detectDiffs(
    allocator: std.mem.Allocator,
    old_prefab: *const PrefabResource,
    new_prefab: *const PrefabResource,
) !PrefabDiff {
    var diff = PrefabDiff{
        .allocator = allocator,
        .added_entities = std.ArrayList(u32).init(allocator),
        .removed_entities = std.ArrayList(u32).init(allocator),
        .modified_entities = std.ArrayList(EntityDiff).init(allocator),
    };

    // 构建旧实体的 ID 集合
    var old_ids = std.AutoHashMap(u32, void).init(allocator);
    defer old_ids.deinit();
    for (old_prefab.entities) |entity| {
        try old_ids.put(entity.prefab_entity_id, {});
    }

    // 检测新增和修改的实体
    for (new_prefab.entities) |new_entity| {
        if (!old_ids.contains(new_entity.prefab_entity_id)) {
            // 新增实体
            try diff.added_entities.append(allocator, new_entity.prefab_entity_id);
        } else {
            // 检测修改 - 查找旧实体
            for (old_prefab.entities) |old_entity| {
                if (old_entity.prefab_entity_id == new_entity.prefab_entity_id) {
                    const entity_diff = try detectEntityDiff(allocator, &old_entity, &new_entity);
                    if (entity_diff.has_changes) {
                        try diff.modified_entities.append(allocator, entity_diff);
                    }
                    break;
                }
            }
        }
    }

    // 检测删除的实体
    var new_ids = std.AutoHashMap(u32, void).init(allocator);
    defer new_ids.deinit();
    for (new_prefab.entities) |entity| {
        try new_ids.put(entity.prefab_entity_id, {});
    }
    for (old_prefab.entities) |old_entity| {
        if (!new_ids.contains(old_entity.prefab_entity_id)) {
            try diff.removed_entities.append(allocator, old_entity.prefab_entity_id);
        }
    }

    return diff;
}

/// 单个实体的 Diff
const EntityDiff = struct {
    prefab_entity_id: u32,
    has_changes: bool,
    transform_changed: bool,
    name_changed: bool,
    component_changes: ComponentChangeList,
};

const ComponentChangeList = struct {
    mesh_changed: bool = false,
    material_changed: bool = false,
    light_changed: bool = false,
    camera_changed: bool = false,
    rigidbody_changed: bool = false,
    collider_changed: bool = false,
    vfx_changed: bool = false,
};

fn detectEntityDiff(
    allocator: std.mem.Allocator,
    old_entity: *const PrefabEntityData,
    new_entity: *const PrefabEntityData,
) !EntityDiff {
    var diff = EntityDiff{
        .prefab_entity_id = old_entity.prefab_entity_id,
        .has_changes = false,
        .transform_changed = false,
        .name_changed = false,
        .component_changes = .{},
    };

    // 检测名称变化
    if (!std.mem.eql(u8, old_entity.name, new_entity.name)) {
        diff.name_changed = true;
        diff.has_changes = true;
    }

    // 检测变换变化
    const old_t = &old_entity.local_transform;
    const new_t = &new_entity.local_transform;
    if (!std.mem.eql(f32, old_t.translation[0..3], new_t.translation[0..3]) or
        !std.mem.eql(f32, old_t.rotation[0..4], new_t.rotation[0..4]) or
        !std.mem.eql(f32, old_t.scale[0..3], new_t.scale[0..3]))
    {
        diff.transform_changed = true;
        diff.has_changes = true;
    }

    // 检测组件变化
    if (!equalOrNull(old_entity.mesh, new_entity.mesh)) {
        diff.component_changes.mesh_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.material, new_entity.material)) {
        diff.component_changes.material_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.light, new_entity.light)) {
        diff.component_changes.light_changed = true;
        diff.has_changes = true;
    }

    return diff;
}

fn equalOrNull(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    // 简化比较 - 实际实现需要更详细的比较
    return a.* == b.*;
}

/// Prefab Diff 结果
pub const PrefabDiff = struct {
    allocator: std.mem.Allocator,
    added_entities: std.ArrayList(u32),
    removed_entities: std.ArrayList(u32),
    modified_entities: std.ArrayList(EntityDiff),

    pub fn deinit(self: *PrefabDiff) void {
        self.added_entities.deinit(self.allocator);
        self.removed_entities.deinit(self.allocator);
        for (self.modified_entities.items) |*diff| {
            _ = diff;
        }
        self.modified_entities.deinit(self.allocator);
    }
};

/// 更新 Prefab 实例
pub fn updatePrefabInstance(
    world: *world_mod.World,
    root_entity_id: world_mod.EntityId,
    diff: *const PrefabDiff,
    prefab: *const PrefabResource,
) !void {
    _ = world;
    _ = root_entity_id;
    _ = diff;
    _ = prefab;
    // TODO: 实现实例更新逻辑
    // 1. 对每个修改的实体，应用新的组件值
    // 2. 对新增的实体，创建新实例
    // 3. 对删除的实体，销毁实例
}
