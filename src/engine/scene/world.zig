const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const gltf_import = @import("../assets/gltf_import.zig");
const raycast_mod = @import("raycast.zig");
const spatial_index_mod = @import("spatial_index.zig");
const components = @import("components.zig");
const vfx_runtime_mod = @import("vfx_runtime.zig");
const vec3 = @import("../math/vec3.zig");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const job_system_mod = @import("../core/job_system.zig");
const prefab_mod = @import("prefab.zig");

const compose_epsilon = 0.0001;
const dynamic_reintegration_query_threshold: u8 = 3;
const spatial_log = std.log.scoped(.spatial_index);

const DynamicRenderableState = struct {
    steady_query_count: u8 = 0,
};

const SpatialPartitionSnapshot = struct {
    static_items: usize,
    dynamic_items: usize,
};

const AnimatorBinding = struct {
    animator_entity_id: EntityId,
    target_entities: []EntityId,
    base_local_transforms: []components.Transform,
};

const SkinnedMeshBinding = struct {
    entity_id: EntityId,
    target_entities: []EntityId,
};

var g_logged_spatial_partition_snapshot: ?SpatialPartitionSnapshot = null;

pub const EntityId = u64;

pub const Entity = struct {
    id: EntityId,
    name: []u8,
    parent: ?EntityId = null,
    local_transform: components.Transform = .{},
    world_transform_cache: components.Transform = .{},
    world_bounds_cache: ?AABB = null,
    dirty: bool = true,
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    skinned_mesh: ?components.SkinnedMesh = null,
    animator: ?components.Animator = null,
    rigidbody: ?components.Rigidbody = null,
    box_collider: ?components.BoxCollider = null,
    sphere_collider: ?components.SphereCollider = null,
    mesh_collider: ?components.MeshCollider = null,
    constraint: ?components.Constraint = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?components.Script = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    children: std.ArrayListUnmanaged(EntityId) = .empty,

    // Prefab 相关字段
    /// 该实体在原始 Prefab 中的 ID (如果是 Prefab 实例)
    prefab_entity_id: ?u32 = null,
    /// Prefab 实例覆盖数据 (如果有覆盖)
    prefab_instance_override: ?prefab_mod.PrefabInstanceOverride = null,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        allocator.free(self.name);
        if (self.prefab_instance_override) |*override| {
            override.deinit(allocator);
        }
    }
};

fn isPrefabRootEntity(entity: *const Entity) bool {
    return entity.prefab_entity_id != null and entity.prefab_entity_id.? == 0 and entity.parent == null;
}

pub const RenderableRayCandidate = struct {
    id: EntityId,
    bounds: AABB,
    enter_distance: f32,
};

pub const EntityDesc = struct {
    name: []const u8,
    parent: ?EntityId = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    skinned_mesh: ?components.SkinnedMesh = null,
    animator: ?components.Animator = null,
    rigidbody: ?components.Rigidbody = null,
    box_collider: ?components.BoxCollider = null,
    sphere_collider: ?components.SphereCollider = null,
    mesh_collider: ?components.MeshCollider = null,
    constraint: ?components.Constraint = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?components.Script = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
};

pub const Summary = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
    vfx_count: usize = 0,
    rigidbody_count: usize = 0,
    collider_count: usize = 0,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    resources: assets_lib.ResourceLibrary,
    /// Prefab 库
    prefab_library: prefab_mod.PrefabLibrary,
    entities: std.ArrayList(Entity) = .empty,
    id_to_index: std.AutoHashMap(EntityId, usize),
    next_id: EntityId = 1,
    job_system: ?*job_system_mod.JobSystem = null,
    vfx_runtime_emitters: std.ArrayList(vfx_runtime_mod.VfxRuntimeEmitter) = .empty,
    renderable_spatial_index: spatial_index_mod.StaticBoundsBvh,
    dynamic_renderable_spatial_index: spatial_index_mod.StaticBoundsBvh,
    static_renderable_items: std.ArrayList(spatial_index_mod.BoundsItem) = .empty,
    dynamic_renderable_items: std.ArrayList(spatial_index_mod.BoundsItem) = .empty,
    static_renderable_item_indices: std.AutoHashMap(EntityId, usize),
    dynamic_renderable_item_indices: std.AutoHashMap(EntityId, usize),
    dynamic_renderables: std.AutoHashMap(EntityId, DynamicRenderableState),
    dynamic_dirty_renderables: std.AutoHashMap(EntityId, void),
    renderable_sync_candidates: std.AutoHashMap(EntityId, void),
    animator_bindings: std.ArrayList(AnimatorBinding) = .empty,
    skinned_mesh_bindings: std.ArrayList(SkinnedMeshBinding) = .empty,
    renderable_full_sync_required: bool = false,

    pub fn init(allocator: std.mem.Allocator, job_system: ?*job_system_mod.JobSystem) World {
        return .{
            .allocator = allocator,
            .resources = assets_lib.ResourceLibrary.init(allocator, job_system),
            .prefab_library = prefab_mod.PrefabLibrary.init(allocator),
            .id_to_index = std.AutoHashMap(EntityId, usize).init(allocator),
            .job_system = job_system,
            .renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(allocator),
            .dynamic_renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(allocator),
            .static_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(allocator),
            .dynamic_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(allocator),
            .dynamic_renderables = std.AutoHashMap(EntityId, DynamicRenderableState).init(allocator),
            .dynamic_dirty_renderables = std.AutoHashMap(EntityId, void).init(allocator),
            .renderable_sync_candidates = std.AutoHashMap(EntityId, void).init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.clearStorage(false);
    }

    pub fn clear(self: *World) void {
        self.clearStorage(true);
    }

    fn clearStorage(self: *World, reinitialize: bool) void {
        self.releaseVfxRuntime(false);
        for (self.entities.items) |*entity| {
            entity.deinit(self.allocator);
        }
        self.entities.deinit(self.allocator);
        self.id_to_index.deinit();
        self.renderable_spatial_index.deinit();
        self.dynamic_renderable_spatial_index.deinit();
        self.static_renderable_items.deinit(self.allocator);
        self.dynamic_renderable_items.deinit(self.allocator);
        self.static_renderable_item_indices.deinit();
        self.dynamic_renderable_item_indices.deinit();
        self.dynamic_renderables.deinit();
        self.dynamic_dirty_renderables.deinit();
        self.renderable_sync_candidates.deinit();
        for (self.animator_bindings.items) |binding| {
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
        }
        self.animator_bindings.deinit(self.allocator);
        for (self.skinned_mesh_bindings.items) |binding| {
            self.allocator.free(binding.target_entities);
        }
        self.skinned_mesh_bindings.deinit(self.allocator);
        self.resources.deinit();
        self.prefab_library.deinit();
        if (reinitialize) {
            self.entities = .empty;
            self.id_to_index = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.resources = assets_lib.ResourceLibrary.init(self.allocator, self.job_system);
            self.prefab_library = prefab_mod.PrefabLibrary.init(self.allocator);
            self.vfx_runtime_emitters = .empty;
            self.renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(self.allocator);
            self.dynamic_renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(self.allocator);
            self.static_renderable_items = .empty;
            self.dynamic_renderable_items = .empty;
            self.static_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.dynamic_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.dynamic_renderables = std.AutoHashMap(EntityId, DynamicRenderableState).init(self.allocator);
            self.dynamic_dirty_renderables = std.AutoHashMap(EntityId, void).init(self.allocator);
            self.renderable_sync_candidates = std.AutoHashMap(EntityId, void).init(self.allocator);
            self.animator_bindings = .empty;
            self.skinned_mesh_bindings = .empty;
            self.renderable_full_sync_required = false;
        }
    }

    pub fn createEntity(self: *World, desc: EntityDesc) !EntityId {
        const id = self.next_id;
        self.next_id += 1;
        return self.createEntityWithId(id, desc);
    }

    pub fn createEntityWithId(self: *World, id: EntityId, desc: EntityDesc) !EntityId {
        if (desc.parent) |parent_id| {
            if (!self.hasEntity(parent_id)) {
                return error.ParentNotFound;
            }
        }
        if (self.hasEntity(id)) {
            return error.EntityIdConflict;
        }

        const index = self.entities.items.len;
        try self.entities.append(self.allocator, .{
            .id = id,
            .name = try self.allocator.dupe(u8, desc.name),
            .parent = desc.parent,
            .local_transform = desc.local_transform,
            .camera = desc.camera,
            .mesh = desc.mesh,
            .skinned_mesh = desc.skinned_mesh,
            .animator = desc.animator,
            .rigidbody = desc.rigidbody,
            .box_collider = desc.box_collider,
            .sphere_collider = desc.sphere_collider,
            .mesh_collider = desc.mesh_collider,
            .constraint = desc.constraint,
            .material = desc.material,
            .light = desc.light,
            .vfx = desc.vfx,
            .visible = desc.visible,
            .editor_only = desc.editor_only,
            .is_folder = desc.is_folder,
            .world_transform_cache = .{},
            .world_bounds_cache = null,
            .dirty = true,
            .children = .empty,
        });

        try self.id_to_index.put(id, index);

        if (desc.parent) |parent_id| {
            if (self.getEntity(parent_id)) |parent| {
                try parent.children.append(self.allocator, id);
            }
        }
        if (desc.mesh != null or desc.skinned_mesh != null or desc.vfx != null) {
            self.queueRenderableSync(id);
        }

        if (id >= self.next_id) {
            self.next_id = id + 1;
        }

        return id;
    }

    pub fn getEntity(self: *World, id: EntityId) ?*Entity {
        const index = self.id_to_index.get(id) orelse return null;
        return &self.entities.items[index];
    }

    pub fn getEntityConst(self: *const World, id: EntityId) ?*const Entity {
        const index = self.id_to_index.get(id) orelse return null;
        return &self.entities.items[index];
    }

    pub fn hasEntity(self: *const World, id: EntityId) bool {
        return self.getEntityConst(id) != null;
    }

    pub fn parentEntity(self: *const World, id: EntityId) ?EntityId {
        const entity = self.getEntityConst(id) orelse return null;
        return entity.parent;
    }

    pub fn markDirty(self: *World, id: EntityId) void {
        const entity = self.getEntity(id) orelse return;
        if (entity.mesh != null or entity.skinned_mesh != null or entity.vfx != null) {
            self.queueRenderableSync(id);
            if (self.dynamic_renderables.getPtr(id)) |state| {
                state.steady_query_count = 0;
                _ = self.dynamic_dirty_renderables.put(id, {}) catch {};
                self.dynamic_renderable_spatial_index.markDirty();
            } else if (self.promoteRenderableToDynamic(id)) {
                _ = self.dynamic_dirty_renderables.put(id, {}) catch {};
                self.dynamic_renderable_spatial_index.markDirty();
            } else {
                self.renderable_spatial_index.markDirty();
            }
        }

        const was_dirty = entity.dirty;
        entity.dirty = true;
        if (was_dirty) return;

        for (entity.children.items) |child_id| {
            self.markDirty(child_id);
        }
    }

    pub fn updateHierarchy(self: *World) void {
        // First pass: update world transforms
        for (self.entities.items) |*entity| {
            if (entity.parent == null) {
                self.updateTransformRecursive(entity.id, components.Transform.identity());
            }
        }

        // Second pass: update bounds (bottom-up)
        // For simplicity, we can do it in a separate pass or combine.
        // Bottom-up is better for bounds.
        for (self.entities.items) |*entity| {
            _ = self.updateBoundsRecursive(entity.id);
        }
    }

    fn updateTransformRecursive(self: *World, id: EntityId, parent_world: components.Transform) void {
        const entity = self.getEntity(id) orelse return;
        if (entity.dirty) {
            const mat4 = @import("../math/mat4.zig");
            const quat = @import("../math/quat.zig");

            // Combine parent and local
            const parent_mat = mat4.transformMatrix(parent_world);
            const local_mat = mat4.transformMatrix(entity.local_transform);
            const world_mat = mat4.mul(parent_mat, local_mat);

            // For now, we store it back in TRS.
            // In a real engine, we'd store the matrix and decompose only if needed.
            // But we'll follow the plan's TRS requirement.
            entity.world_transform_cache.translation = .{ world_mat[12], world_mat[13], world_mat[14] };

            // Simplified decomposition for now - assuming no skew
            entity.world_transform_cache.scale = .{
                vec3.length(.{ world_mat[0], world_mat[4], world_mat[8] }),
                vec3.length(.{ world_mat[1], world_mat[5], world_mat[9] }),
                vec3.length(.{ world_mat[2], world_mat[6], world_mat[10] }),
            };

            // Rotation is trickier to extract from matrix, but for now we'll just
            // accumulate quats (which is faster and more precise for hierarchies)
            entity.world_transform_cache.rotation = quat.mul(parent_world.rotation, entity.local_transform.rotation);

            entity.dirty = false;
        }

        for (entity.children.items) |child_id| {
            self.updateTransformRecursive(child_id, entity.world_transform_cache);
        }
    }

    fn updateBoundsRecursive(self: *World, id: EntityId) AABB {
        const entity = self.getEntity(id) orelse return AABB.empty();

        var bounds = AABB.empty();

        // Include own mesh bounds
        if (entity.mesh) |mesh_comp| {
            if (mesh_comp.handle) |handle| {
                if (self.resources.mesh(handle)) |mesh_res| {
                    bounds.expandAABB(mesh_res.local_bounds.transformed(entity.world_transform_cache));
                }
            }
        } else if (entity.skinned_mesh) |skinned_mesh_comp| {
            if (skinned_mesh_comp.mesh_handle) |handle| {
                if (self.resources.mesh(handle)) |mesh_res| {
                    bounds.expandAABB(mesh_res.local_bounds.transformed(entity.world_transform_cache));
                }
            }
        }

        // Include children bounds
        for (entity.children.items) |child_id| {
            const child_bounds = self.updateBoundsRecursive(child_id);
            if (child_bounds.isValid()) {
                bounds.expandAABB(child_bounds);
            }
        }

        entity.world_bounds_cache = if (bounds.isValid()) bounds else null;
        return bounds;
    }

    pub fn setEntityLocalTransform(self: *World, id: EntityId, transform: components.Transform) bool {
        const entity = self.getEntity(id) orelse return false;
        entity.local_transform = transform;
        self.markDirty(id);
        return true;
    }

    pub fn localTransform(self: *const World, id: EntityId) components.Transform {
        const entity = self.getEntityConst(id) orelse return .{};
        return entity.local_transform;
    }

    pub fn worldTransform(self: *World, id: EntityId) ?components.Transform {
        const entity = self.getEntity(id) orelse return null;
        if (entity.dirty) {
            self.updateHierarchy();
        }
        return entity.world_transform_cache;
    }

    pub fn worldTransformConst(self: *const World, id: EntityId) ?components.Transform {
        const entity = self.getEntityConst(id) orelse return null;
        // In const context we can't update, so we just return the cache
        // If it's dirty, the caller should have called updateHierarchy before.
        return entity.world_transform_cache;
    }

    pub fn worldBounds(self: *World, id: EntityId) ?AABB {
        const entity = self.getEntity(id) orelse return null;
        if (entity.dirty) {
            self.updateHierarchy();
        }
        return entity.world_bounds_cache;
    }

    pub fn worldBoundsConst(self: *const World, id: EntityId) ?AABB {
        const entity = self.getEntityConst(id) orelse return null;
        return entity.world_bounds_cache;
    }

    pub fn setEntityWorldTransform(self: *World, id: EntityId, world_transform: components.Transform) bool {
        const entity = self.getEntity(id) orelse return false;
        if (entity.parent) |parent_id| {
            const parent_world = self.worldTransform(parent_id) orelse return false;
            entity.local_transform = relativeTransform(parent_world, world_transform);
        } else {
            entity.local_transform = world_transform;
        }
        self.markDirty(id);
        return true;
    }

    pub fn renameEntity(self: *World, id: EntityId, new_name: []const u8) !bool {
        const entity = self.getEntity(id) orelse return false;
        if (std.mem.eql(u8, entity.name, new_name)) {
            return false;
        }

        const owned_name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(entity.name);
        entity.name = owned_name;
        return true;
    }

    pub fn findEntityByName(self: *const World, name: []const u8) ?*const Entity {
        for (self.entities.items) |*entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity;
            }
        }
        return null;
    }

    pub fn primaryCameraEntity(self: *const World) ?EntityId {
        var fallback: ?EntityId = null;
        for (self.entities.items) |entity| {
            const camera = entity.camera orelse continue;
            if (fallback == null) {
                fallback = entity.id;
            }
            if (camera.is_primary) {
                return entity.id;
            }
        }
        return fallback;
    }

    pub fn setPrimaryCamera(self: *World, id: EntityId) bool {
        var found = false;
        for (self.entities.items) |*entity| {
            if (entity.camera) |camera| {
                var next_camera = camera;
                next_camera.is_primary = entity.id == id;
                entity.camera = next_camera;
                if (entity.id == id) {
                    found = true;
                }
            }
        }
        return found;
    }

    pub fn setParent(self: *World, child_id: EntityId, parent_id: ?EntityId) !bool {
        if (!self.hasEntity(child_id)) {
            return false;
        }

        if (parent_id) |resolved_parent_id| {
            if (!self.hasEntity(resolved_parent_id)) {
                return error.ParentNotFound;
            }
            if (resolved_parent_id == child_id or self.isDescendantOf(resolved_parent_id, child_id)) {
                return error.ParentCycleDetected;
            }
        }

        const current_world = self.worldTransform(child_id) orelse return false;
        const entity = self.getEntity(child_id) orelse return false;
        if (entity.parent == parent_id) {
            return false;
        }

        // Remove from old parent
        if (entity.parent) |old_parent_id| {
            if (self.getEntity(old_parent_id)) |old_parent| {
                for (old_parent.children.items, 0..) |cid, i| {
                    if (cid == child_id) {
                        _ = old_parent.children.swapRemove(i);
                        break;
                    }
                }
            }
        }

        entity.parent = parent_id;

        // Add to new parent
        if (parent_id) |new_parent_id| {
            if (self.getEntity(new_parent_id)) |new_parent| {
                try new_parent.children.append(self.allocator, child_id);
            }
        }

        return self.setEntityWorldTransform(child_id, current_world);
    }

    pub fn setParentLocal(self: *World, child_id: EntityId, parent_id: ?EntityId) !bool {
        if (!self.hasEntity(child_id)) {
            return false;
        }

        if (parent_id) |resolved_parent_id| {
            if (!self.hasEntity(resolved_parent_id)) {
                return error.ParentNotFound;
            }
            if (resolved_parent_id == child_id or self.isDescendantOf(resolved_parent_id, child_id)) {
                return error.ParentCycleDetected;
            }
        }

        const entity = self.getEntity(child_id) orelse return false;
        if (entity.parent == parent_id) {
            return false;
        }

        // Remove from old parent
        if (entity.parent) |old_parent_id| {
            if (self.getEntity(old_parent_id)) |old_parent| {
                for (old_parent.children.items, 0..) |cid, i| {
                    if (cid == child_id) {
                        _ = old_parent.children.swapRemove(i);
                        break;
                    }
                }
            }
        }

        entity.parent = parent_id;

        // Add to new parent
        if (parent_id) |new_parent_id| {
            if (self.getEntity(new_parent_id)) |new_parent| {
                try new_parent.children.append(self.allocator, child_id);
            }
        }

        self.markDirty(child_id);
        return true;
    }

    pub fn destroyEntity(self: *World, id: EntityId) bool {
        var subtree = std.ArrayList(EntityId).empty;
        defer subtree.deinit(self.allocator);
        self.collectSubtreeIds(id, &subtree) catch return false;
        if (subtree.items.len == 0) {
            return false;
        }

        self.removeVfxEmittersForEntities(subtree.items);

        var index = subtree.items.len;
        while (index > 0) {
            index -= 1;
            self.removeEntityById(subtree.items[index]);
        }
        return true;
    }

    pub fn pruneVfxRuntimeEmitters(self: *World) void {
        var index: usize = 0;
        while (index < self.vfx_runtime_emitters.items.len) {
            const emitter_id = self.vfx_runtime_emitters.items[index].entity_id;
            const emitter_entity = self.getEntityConst(emitter_id);
            if (emitter_entity == null or emitter_entity.?.vfx == null) {
                self.clearVfxEmitterAtIndex(index, true);
                continue;
            }
            index += 1;
        }
    }

    pub fn clearVfxRuntime(self: *World) void {
        self.releaseVfxRuntime(true);
    }

    pub fn clearVfxEmitterRuntime(self: *World, entity_id: EntityId) void {
        for (self.vfx_runtime_emitters.items, 0..) |emitter, index| {
            if (emitter.entity_id == entity_id) {
                self.clearVfxEmitterAtIndex(index, true);
                return;
            }
        }
    }

    pub fn ensureVfxRuntimeEmitter(self: *World, entity_id: EntityId, vfx: components.Vfx) !*vfx_runtime_mod.VfxRuntimeEmitter {
        for (self.vfx_runtime_emitters.items) |*emitter| {
            if (emitter.entity_id == entity_id) {
                if (!vfx.looping and emitter.particles.len == 0 and emitter.elapsed <= 0.0001 and emitter.one_shot_remaining == 0) {
                    emitter.one_shot_remaining = vfx.max_particles;
                }
                return emitter;
            }
        }

        try self.vfx_runtime_emitters.append(self.allocator, .{
            .entity_id = entity_id,
            .seed = @truncate(entity_id *% 747796405 +% 2891336453),
            .one_shot_remaining = if (vfx.looping) 0 else vfx.max_particles,
        });
        return &self.vfx_runtime_emitters.items[self.vfx_runtime_emitters.items.len - 1];
    }

    pub fn duplicateEntity(self: *World, id: EntityId) !EntityId {
        const source = self.getEntityConst(id) orelse return error.EntityNotFound;
        return self.duplicateEntityRecursive(id, source.parent);
    }

    pub fn createPrimitiveEntity(
        self: *World,
        primitive: components.Primitive,
        transform: components.Transform,
    ) !EntityId {
        const mesh_handle = try self.resources.ensurePrimitiveMesh(primitive);
        const material_handle = try self.resources.ensureDefaultMaterial();
        const base_name = switch (primitive) {
            .cube => "Cube",
            .sphere => "Sphere",
            .plane => "Plane",
            .custom => "Mesh",
        };
        const entity_name = try self.nextAvailableName(base_name);
        defer self.allocator.free(entity_name);

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = transform,
            .mesh = .{
                .handle = mesh_handle,
                .primitive = primitive,
            },
            .material = .{
                .handle = material_handle,
            },
        });
    }

    pub fn createEmptyEntity(self: *World, transform: components.Transform) !EntityId {
        const entity_name = try self.nextAvailableName("Empty");
        defer self.allocator.free(entity_name);

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = transform,
        });
    }

    pub fn createFolderEntity(self: *World, transform: components.Transform) !EntityId {
        const entity_name = try self.nextAvailableName("Folder");
        defer self.allocator.free(entity_name);

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = transform,
            .is_folder = true,
        });
    }

    pub fn createCameraEntity(self: *World, transform: components.Transform) !EntityId {
        const entity_name = try self.nextAvailableName("Camera");
        defer self.allocator.free(entity_name);

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = transform,
            .camera = .{},
        });
    }

    pub fn createLightEntity(
        self: *World,
        kind: components.LightKind,
        transform: components.Transform,
        intensity: f32,
    ) !EntityId {
        const base_name = switch (kind) {
            .directional => "DirectionalLight",
            .point => "PointLight",
            .spot => "SpotLight",
        };
        const entity_name = try self.nextAvailableName(base_name);
        defer self.allocator.free(entity_name);

        var light_transform = transform;
        var mesh: ?components.Mesh = null;
        var material: ?components.Material = null;

        if (kind != .directional) {
            const proxy_mesh = try self.resources.ensurePrimitiveMesh(.sphere);
            const material_name = try std.fmt.allocPrint(self.allocator, "{s}Material", .{entity_name});
            defer self.allocator.free(material_name);
            const tint: [4]f32 = switch (kind) {
                .point => .{ 1.0, 0.86, 0.55, 1.0 },
                .spot => .{ 0.65, 0.8, 1.0, 1.0 },
                .directional => .{ 1.0, 1.0, 1.0, 1.0 },
            };
            const proxy_material = try self.resources.createMaterial(.{
                .name = material_name,
                .base_color_factor = tint,
                .base_color_texture = try self.resources.ensureWhiteTexture(),
            });

            light_transform.scale = switch (kind) {
                .point => .{ 0.18, 0.18, 0.18 },
                .spot => .{ 0.24, 0.24, 0.24 },
                .directional => light_transform.scale,
            };
            mesh = .{
                .handle = proxy_mesh,
                .primitive = .sphere,
            };
            material = .{
                .handle = proxy_material,
                .base_color_factor = tint,
            };
        }

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = light_transform,
            .mesh = mesh,
            .material = material,
            .light = .{
                .kind = kind,
                .intensity = intensity,
                .range = if (kind == .point) 12.0 else 10.0,
            },
        });
    }

    pub fn createVfxEntity(
        self: *World,
        kind: components.VfxKind,
        transform: components.Transform,
    ) !EntityId {
        const base_name = switch (kind) {
            .fountain => "FountainVfx",
            .orbit => "OrbitVfx",
        };
        const entity_name = try self.nextAvailableName(base_name);
        defer self.allocator.free(entity_name);

        const mesh_handle = try self.resources.ensurePrimitiveMesh(.sphere);
        const vfx = components.defaultVfx(kind);
        var root_transform = transform;
        root_transform.scale = switch (kind) {
            .fountain => .{ 0.18, 0.18, 0.18 },
            .orbit => .{ 0.2, 0.2, 0.2 },
        };

        return self.createEntity(.{
            .name = entity_name,
            .local_transform = root_transform,
            .mesh = .{
                .handle = mesh_handle,
                .primitive = .sphere,
            },
            .material = .{
                .shading = .unlit,
                .base_color_factor = .{ vfx.color[0], vfx.color[1], vfx.color[2], 1.0 },
            },
            .vfx = vfx,
        });
    }

    pub fn summary(self: *const World) Summary {
        var result = Summary{
            .entity_count = self.entities.items.len,
        };

        for (self.entities.items) |entity| {
            if (entity.camera != null) {
                result.camera_count += 1;
            }
            if (entity.mesh != null or entity.skinned_mesh != null) {
                result.mesh_count += 1;
            }
            if (entity.material != null) {
                result.material_count += 1;
            }
            if (entity.light != null) {
                result.light_count += 1;
            }
            if (entity.vfx != null) {
                result.vfx_count += 1;
            }
            if (entity.rigidbody != null) {
                result.rigidbody_count += 1;
            }
            if (entity.box_collider != null or entity.sphere_collider != null or entity.mesh_collider != null) {
                result.collider_count += 1;
            }
        }

        return result;
    }

    pub fn bootstrap3D(self: *World) !void {
        const default_material = try self.resources.ensureDefaultMaterial();
        const plane_mesh = try self.resources.ensurePrimitiveMesh(.plane);
        const cube_mesh = try self.resources.ensurePrimitiveMesh(.cube);

        _ = try self.createEntity(.{
            .name = "MainCamera",
            .camera = .{ .is_primary = true },
            .local_transform = .{
                .translation = .{ 0.0, 1.5, 5.0 },
            },
        });

        _ = try self.createEntity(.{
            .name = "Sun",
            .light = .{
                .kind = .directional,
                .intensity = 4.0,
            },
            .local_transform = .{
                .rotation = @import("../math/quat.zig").fromEuler(.{ -0.9, 0.6, 0.0 }),
            },
        });

        _ = try self.createEntity(.{
            .name = "Ground",
            .mesh = .{
                .handle = plane_mesh,
                .primitive = .plane,
            },
            .rigidbody = .{
                .motion_type = .static,
            },
            .box_collider = .{
                .half_extents = .{ 5.0, 0.1, 5.0 },
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .scale = .{ 10.0, 1.0, 10.0 },
            },
        });

        _ = try self.createEntity(.{
            .name = "Hero",
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .rigidbody = .{
                .motion_type = .dynamic,
            },
            .box_collider = .{
                .half_extents = .{ 0.5, 0.5, 0.5 },
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .translation = .{ 0.0, 1.0, 0.0 },
            },
        });
    }

    pub fn importGltfStaticModel(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
    ) !gltf_import.ImportReport {
        return gltf_import.importStaticModel(self, path, root_transform);
    }

    const AsyncImportContext = struct {
        world: *World,
        path: []const u8,
        root_transform: components.Transform,
        callback: ?*const fn (report: gltf_import.ImportReport) void = null,
    };

    fn asyncImportTask(context: ?*anyopaque) void {
        const ctx: *AsyncImportContext = @ptrCast(@alignCast(context));
        const report = ctx.world.importGltfStaticModel(ctx.path, ctx.root_transform) catch |err| {
            std.log.err("Async GLTF import failed: {s}, error: {}", .{ ctx.path, err });
            return;
        };
        if (ctx.callback) |cb| {
            cb(report);
        }
        ctx.world.allocator.free(ctx.path);
        ctx.world.allocator.destroy(ctx);
    }

    pub fn importGltfAsync(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
        callback: ?*const fn (report: gltf_import.ImportReport) void,
    ) !job_system_mod.JobHandle {
        const job_system = self.job_system orelse return error.NoJobSystem;
        const ctx = try self.allocator.create(AsyncImportContext);
        ctx.* = .{
            .world = self,
            .path = try self.allocator.dupe(u8, path),
            .root_transform = root_transform,
            .callback = callback,
        };

        return job_system.enqueue(asyncImportTask, ctx, .normal);
    }

    pub fn importGltfStaticModelInstance(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
    ) !gltf_import.ImportReport {
        return gltf_import.importStaticModelInstance(self, path, root_transform);
    }

    pub fn raycastSurface(self: *World, ray: raycast_mod.Ray) ?raycast_mod.SurfaceRaycastHit {
        return raycast_mod.raycastSurface(self, ray);
    }

    pub fn queryRenderableRayCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]EntityId {
        const bounds_candidates = try self.queryRenderableRayBounds(allocator, ray_origin, ray_direction, max_distance);
        defer allocator.free(bounds_candidates);

        var candidates = std.ArrayList(EntityId).empty;
        errdefer candidates.deinit(allocator);
        try candidates.ensureTotalCapacity(allocator, @intCast(bounds_candidates.len));
        for (bounds_candidates) |candidate| {
            candidates.appendAssumeCapacity(candidate.id);
        }
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableRayBounds(
        self: *World,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]RenderableRayCandidate {
        try self.ensureRenderableSpatialState();

        var candidates = std.ArrayList(RenderableRayCandidate).empty;
        errdefer candidates.deinit(allocator);

        const static_candidates = try self.renderable_spatial_index.queryRayCandidatesDetailed(
            allocator,
            ray_origin,
            ray_direction,
            max_distance,
        );
        defer allocator.free(static_candidates);
        try self.appendRenderableRayCandidates(allocator, &candidates, static_candidates);

        const dynamic_candidates = try self.dynamic_renderable_spatial_index.queryRayCandidatesDetailed(
            allocator,
            ray_origin,
            ray_direction,
            max_distance,
        );
        defer allocator.free(dynamic_candidates);
        try self.appendRenderableRayCandidates(allocator, &candidates, dynamic_candidates);

        std.sort.heap(RenderableRayCandidate, candidates.items, {}, lessThanRenderableRayCandidateDistance);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableFrustumCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]EntityId {
        try self.ensureRenderableSpatialState();

        var candidates = std.ArrayList(EntityId).empty;
        errdefer candidates.deinit(allocator);

        const static_candidates = try self.renderable_spatial_index.queryFrustumCandidates(allocator, frustum);
        defer allocator.free(static_candidates);
        try candidates.appendSlice(allocator, static_candidates);

        const dynamic_candidates = try self.dynamic_renderable_spatial_index.queryFrustumCandidates(allocator, frustum);
        defer allocator.free(dynamic_candidates);
        try candidates.appendSlice(allocator, dynamic_candidates);

        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableBoundsInFrustum(
        self: *World,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]spatial_index_mod.BoundsItem {
        const candidate_ids = try self.queryRenderableFrustumCandidates(allocator, frustum);
        defer allocator.free(candidate_ids);

        var bounds_items = std.ArrayList(spatial_index_mod.BoundsItem).empty;
        errdefer bounds_items.deinit(allocator);
        try bounds_items.ensureTotalCapacity(allocator, @intCast(candidate_ids.len));

        // 调试可视化直接复用 BVH 候选与 world bounds cache，避免再走一遍 mesh local bounds 现场换算。
        for (candidate_ids) |entity_id| {
            const bounds = self.worldBoundsConst(entity_id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            bounds_items.appendAssumeCapacity(.{
                .id = entity_id,
                .bounds = bounds,
            });
        }

        return try bounds_items.toOwnedSlice(allocator);
    }

    pub fn assets(self: *World) *assets_lib.ResourceLibrary {
        return &self.resources;
    }

    pub fn bindAnimatorTargets(self: *World, animator_entity_id: EntityId, target_entities: []const EntityId) !void {
        if (!self.hasEntity(animator_entity_id)) {
            return error.EntityNotFound;
        }

        const owned_targets = try self.allocator.dupe(EntityId, target_entities);
        errdefer self.allocator.free(owned_targets);
        const owned_base_transforms = try self.allocator.alloc(components.Transform, target_entities.len);
        errdefer self.allocator.free(owned_base_transforms);
        for (target_entities, 0..) |target_entity_id, index| {
            owned_base_transforms[index] = if (self.getEntityConst(target_entity_id)) |entity|
                entity.local_transform
            else
                .{};
        }

        for (self.animator_bindings.items) |*binding| {
            if (binding.animator_entity_id != animator_entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
            binding.target_entities = owned_targets;
            binding.base_local_transforms = owned_base_transforms;
            return;
        }

        try self.animator_bindings.append(self.allocator, .{
            .animator_entity_id = animator_entity_id,
            .target_entities = owned_targets,
            .base_local_transforms = owned_base_transforms,
        });
    }

    pub fn animatorTargets(self: *const World, animator_entity_id: EntityId) ?[]const EntityId {
        for (self.animator_bindings.items) |binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding.target_entities;
            }
        }
        return null;
    }

    pub fn animatorBaseTransforms(self: *const World, animator_entity_id: EntityId) ?[]const components.Transform {
        for (self.animator_bindings.items) |binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding.base_local_transforms;
            }
        }
        return null;
    }

    pub fn bindSkinnedMeshTargets(self: *World, entity_id: EntityId, target_entities: []const EntityId) !void {
        if (!self.hasEntity(entity_id)) {
            return error.EntityNotFound;
        }

        const owned_targets = try self.allocator.dupe(EntityId, target_entities);
        errdefer self.allocator.free(owned_targets);

        for (self.skinned_mesh_bindings.items) |*binding| {
            if (binding.entity_id != entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            binding.target_entities = owned_targets;
            return;
        }

        try self.skinned_mesh_bindings.append(self.allocator, .{
            .entity_id = entity_id,
            .target_entities = owned_targets,
        });
    }

    pub fn skinnedMeshTargets(self: *const World, entity_id: EntityId) ?[]const EntityId {
        for (self.skinned_mesh_bindings.items) |binding| {
            if (binding.entity_id == entity_id) {
                return binding.target_entities;
            }
        }
        return null;
    }

    fn worldTransformRecursive(self: *const World, id: EntityId, depth: usize) ?components.Transform {
        _ = depth;
        return self.worldTransformConst(id);
    }

    fn isDescendantOf(self: *const World, candidate_id: EntityId, ancestor_id: EntityId) bool {
        var current = self.getEntityConst(candidate_id) orelse return false;
        var guard: usize = 0;
        while (current.parent) |parent_id| : (guard += 1) {
            if (guard > self.entities.items.len) {
                return false;
            }
            if (parent_id == ancestor_id) {
                return true;
            }
            current = self.getEntityConst(parent_id) orelse return false;
        }
        return false;
    }

    fn collectDirectChildIds(self: *const World, parent_id: EntityId, list: *std.ArrayList(EntityId)) !void {
        for (self.entities.items) |entity| {
            if (entity.parent == parent_id) {
                try list.append(self.allocator, entity.id);
            }
        }
    }

    fn collectSubtreeIds(self: *const World, root_id: EntityId, list: *std.ArrayList(EntityId)) !void {
        if (!self.hasEntity(root_id)) {
            return;
        }

        try list.append(self.allocator, root_id);
        for (self.entities.items) |entity| {
            if (entity.parent == root_id) {
                try self.collectSubtreeIds(entity.id, list);
            }
        }
    }

    fn removeEntityById(self: *World, id: EntityId) void {
        const index = self.id_to_index.get(id) orelse return;
        const entity = &self.entities.items[index];
        self.removeBoundsItemFromPartition(
            &self.static_renderable_items,
            &self.static_renderable_item_indices,
            &self.renderable_spatial_index,
            id,
        );
        self.removeBoundsItemFromPartition(
            &self.dynamic_renderable_items,
            &self.dynamic_renderable_item_indices,
            &self.dynamic_renderable_spatial_index,
            id,
        );
        _ = self.dynamic_renderables.remove(id);
        _ = self.dynamic_dirty_renderables.remove(id);
        _ = self.renderable_sync_candidates.remove(id);
        self.removeAnimatorBinding(id);
        self.removeSkinnedMeshBinding(id);

        // Remove from parent's children list
        if (entity.parent) |parent_id| {
            if (self.getEntity(parent_id)) |parent| {
                for (parent.children.items, 0..) |child_id, child_idx| {
                    if (child_id == id) {
                        _ = parent.children.swapRemove(child_idx);
                        break;
                    }
                }
            }
        }

        entity.deinit(self.allocator);
        _ = self.entities.orderedRemove(index);
        _ = self.id_to_index.remove(id);

        // Update indices in the map because orderedRemove shifts items
        for (self.entities.items[index..], index..) |shifted, i| {
            self.id_to_index.put(shifted.id, i) catch {};
        }
    }

    fn duplicateEntityRecursive(self: *World, source_id: EntityId, new_parent: ?EntityId) !EntityId {
        const source = self.getEntityConst(source_id) orelse return error.EntityNotFound;
        var source_subtree_ids = std.ArrayList(EntityId).empty;
        defer source_subtree_ids.deinit(self.allocator);
        if (self.animatorTargets(source_id) != null) {
            try self.collectSubtreeIds(source_id, &source_subtree_ids);
        }

        var child_ids = std.ArrayList(EntityId).empty;
        defer child_ids.deinit(self.allocator);
        try self.collectDirectChildIds(source_id, &child_ids);

        const duplicate_name = try self.nextAvailableDerivedName(source.name, " Copy");
        defer self.allocator.free(duplicate_name);

        const duplicate_camera = if (source.camera) |camera| blk: {
            var next_camera = camera;
            next_camera.is_primary = false;
            break :blk next_camera;
        } else null;

        const duplicate_id = try self.createEntity(.{
            .name = duplicate_name,
            .parent = new_parent,
            .local_transform = source.local_transform,
            .camera = duplicate_camera,
            .mesh = source.mesh,
            .skinned_mesh = source.skinned_mesh,
            .animator = source.animator,
            .rigidbody = source.rigidbody,
            .box_collider = source.box_collider,
            .sphere_collider = source.sphere_collider,
            .mesh_collider = source.mesh_collider,
            .material = source.material,
            .light = source.light,
            .vfx = source.vfx,
            .visible = source.visible,
            .editor_only = source.editor_only,
            .is_folder = source.is_folder,
        });

        for (child_ids.items) |child_id| {
            const child = self.getEntityConst(child_id) orelse continue;
            if (child.editor_only) {
                continue;
            }
            _ = try self.duplicateEntityRecursive(child_id, duplicate_id);
        }

        if (self.animatorTargets(source_id)) |targets| {
            var duplicate_subtree_ids = std.ArrayList(EntityId).empty;
            defer duplicate_subtree_ids.deinit(self.allocator);
            try self.collectSubtreeIds(duplicate_id, &duplicate_subtree_ids);

            var remapped_targets = std.ArrayList(EntityId).empty;
            defer remapped_targets.deinit(self.allocator);
            try remapped_targets.ensureTotalCapacity(self.allocator, @intCast(targets.len));

            for (targets) |target_id| {
                const subtree_index = indexOfEntityId(source_subtree_ids.items, target_id) orelse continue;
                if (subtree_index >= duplicate_subtree_ids.items.len) {
                    continue;
                }
                remapped_targets.appendAssumeCapacity(duplicate_subtree_ids.items[subtree_index]);
            }
            if (remapped_targets.items.len == targets.len) {
                try self.bindAnimatorTargets(duplicate_id, remapped_targets.items);
            }
        }

        return duplicate_id;
    }

    fn nextAvailableName(self: *const World, base_name: []const u8) ![]u8 {
        return self.nextAvailableDerivedName(base_name, "");
    }

    fn ensureRenderableSpatialState(self: *World) !void {
        if (self.hasDirtyEntities()) {
            self.updateHierarchy();
        }

        const reintegrated_dynamic = try self.reintegrateStableDynamicRenderables();
        try self.syncRenderableSpatialItems();
        try self.refitDirtyDynamicRenderables();

        if (!self.renderable_spatial_index.dirty and !self.dynamic_renderable_spatial_index.dirty and !reintegrated_dynamic) {
            return;
        }

        var rebuilt_static = false;
        if (self.renderable_spatial_index.dirty) {
            // 静态树只从缓存分区条目重建，避免树 dirty 后重新线性扫完整个 World。
            try self.renderable_spatial_index.rebuild(self.static_renderable_items.items);
            rebuilt_static = true;
        }
        var rebuilt_dynamic = false;
        if (self.dynamic_renderable_spatial_index.dirty) {
            try self.dynamic_renderable_spatial_index.rebuild(self.dynamic_renderable_items.items);
            rebuilt_dynamic = true;
            self.dynamic_dirty_renderables.clearRetainingCapacity();
        }
        self.logSpatialPartitionSnapshotIfNeeded(rebuilt_static, rebuilt_dynamic);
    }

    fn promoteRenderableToDynamic(self: *World, id: EntityId) bool {
        const entity = self.getEntityConst(id) orelse return false;
        if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
            return false;
        }
        if (self.dynamic_renderables.contains(id)) {
            return false;
        }
        self.dynamic_renderables.put(id, .{}) catch {
            // OOM 时退回缓存全量同步路径，保证正确性优先。
            self.renderable_full_sync_required = true;
            return false;
        };
        return true;
    }

    fn reintegrateStableDynamicRenderables(self: *World) !bool {
        if (self.dynamic_renderables.count() == 0) {
            return false;
        }

        var reintegrate_ids = std.ArrayList(EntityId).empty;
        defer reintegrate_ids.deinit(self.allocator);

        var iter = self.dynamic_renderables.iterator();
        while (iter.next()) |entry| {
            const entity_id = entry.key_ptr.*;
            const entity = self.getEntityConst(entity_id) orelse {
                try reintegrate_ids.append(self.allocator, entity_id);
                continue;
            };
            if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
                try reintegrate_ids.append(self.allocator, entity_id);
                continue;
            }

            if (entry.value_ptr.steady_query_count < dynamic_reintegration_query_threshold) {
                entry.value_ptr.steady_query_count += 1;
            }
            if (entry.value_ptr.steady_query_count >= dynamic_reintegration_query_threshold) {
                try reintegrate_ids.append(self.allocator, entity_id);
            }
        }

        if (reintegrate_ids.items.len == 0) {
            return false;
        }

        for (reintegrate_ids.items) |entity_id| {
            _ = self.dynamic_renderables.remove(entity_id);
            _ = self.dynamic_dirty_renderables.remove(entity_id);
            self.queueRenderableSync(entity_id);
        }
        return true;
    }

    fn refitDirtyDynamicRenderables(self: *World) !void {
        if (self.dynamic_dirty_renderables.count() == 0 or self.dynamic_renderable_spatial_index.dirty) {
            return;
        }

        var iter = self.dynamic_dirty_renderables.keyIterator();
        while (iter.next()) |entity_id_ptr| {
            const entity_id = entity_id_ptr.*;
            if (!self.dynamic_renderables.contains(entity_id)) {
                continue;
            }
            const bounds = self.worldBoundsConst(entity_id) orelse {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            };
            if (!bounds.isValid()) {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            }
            if (!self.dynamic_renderable_spatial_index.updateItemBounds(entity_id, bounds)) {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            }
        }

        if (!self.dynamic_renderable_spatial_index.dirty) {
            self.dynamic_dirty_renderables.clearRetainingCapacity();
        }
    }

    fn syncRenderableSpatialItems(self: *World) !void {
        if (self.renderable_full_sync_required) {
            try self.rebuildRenderableItemCachesFromWorld();
            self.renderable_full_sync_required = false;
            self.renderable_spatial_index.markDirty();
            self.dynamic_renderable_spatial_index.markDirty();
            self.renderable_sync_candidates.clearRetainingCapacity();
            return;
        }

        if (self.renderable_sync_candidates.count() == 0) {
            return;
        }

        var iter = self.renderable_sync_candidates.keyIterator();
        while (iter.next()) |entity_id_ptr| {
            try self.syncRenderableSpatialItem(entity_id_ptr.*);
        }
        self.renderable_sync_candidates.clearRetainingCapacity();
    }

    fn syncRenderableSpatialItem(self: *World, entity_id: EntityId) !void {
        const entity = self.getEntityConst(entity_id);
        const is_renderable = entity != null and (entity.?.mesh != null or entity.?.skinned_mesh != null or entity.?.vfx != null);
        const desired_bounds = if (is_renderable) self.worldBoundsConst(entity_id) else null;
        const desired_partition: enum { none, static, dynamic } = blk: {
            if (desired_bounds == null or !desired_bounds.?.isValid()) {
                break :blk .none;
            }
            break :blk if (self.dynamic_renderables.contains(entity_id)) .dynamic else .static;
        };

        switch (desired_partition) {
            .none => {
                self.removeBoundsItemFromPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    entity_id,
                );
                self.removeBoundsItemFromPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    entity_id,
                );
                _ = self.dynamic_dirty_renderables.remove(entity_id);
            },
            .static => {
                self.removeBoundsItemFromPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    entity_id,
                );
                _ = self.dynamic_dirty_renderables.remove(entity_id);
                try self.syncBoundsItemIntoPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    .{
                        .id = entity_id,
                        .bounds = desired_bounds.?,
                    },
                );
            },
            .dynamic => {
                self.removeBoundsItemFromPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    entity_id,
                );
                try self.syncBoundsItemIntoPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    .{
                        .id = entity_id,
                        .bounds = desired_bounds.?,
                    },
                );
            },
        }
    }

    fn rebuildRenderableItemCachesFromWorld(self: *World) !void {
        self.static_renderable_items.clearRetainingCapacity();
        self.dynamic_renderable_items.clearRetainingCapacity();
        self.static_renderable_item_indices.clearRetainingCapacity();
        self.dynamic_renderable_item_indices.clearRetainingCapacity();

        for (self.entities.items) |entity| {
            if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
                continue;
            }
            const bounds = self.worldBoundsConst(entity.id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            const item = spatial_index_mod.BoundsItem{
                .id = entity.id,
                .bounds = bounds,
            };
            if (self.dynamic_renderables.contains(entity.id)) {
                try appendBoundsItem(&self.dynamic_renderable_items, &self.dynamic_renderable_item_indices, self.allocator, item);
            } else {
                try appendBoundsItem(&self.static_renderable_items, &self.static_renderable_item_indices, self.allocator, item);
            }
        }
    }

    fn syncBoundsItemIntoPartition(
        self: *World,
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        bvh: *spatial_index_mod.StaticBoundsBvh,
        item: spatial_index_mod.BoundsItem,
    ) !void {
        const change = try upsertBoundsItem(items, indices, self.allocator, item);
        switch (change) {
            .unchanged => {},
            .inserted => {
                if (!bvh.dirty and !bvh.insertItem(item)) {
                    bvh.markDirty();
                }
            },
            .updated => {
                if (!bvh.dirty and !bvh.updateItemBounds(item.id, item.bounds)) {
                    bvh.markDirty();
                }
            },
        }
    }

    fn removeBoundsItemFromPartition(
        self: *World,
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        bvh: *spatial_index_mod.StaticBoundsBvh,
        item_id: EntityId,
    ) void {
        _ = self;
        if (!removeBoundsItem(items, indices, item_id)) {
            return;
        }
        if (!bvh.dirty and !bvh.removeItem(item_id)) {
            bvh.markDirty();
        }
    }

    fn queueRenderableSync(self: *World, entity_id: EntityId) void {
        self.renderable_sync_candidates.put(entity_id, {}) catch {
            self.renderable_full_sync_required = true;
        };
    }

    fn logSpatialPartitionSnapshotIfNeeded(self: *World, rebuilt_static: bool, rebuilt_dynamic: bool) void {
        if (!rebuilt_static and !rebuilt_dynamic) {
            return;
        }

        const snapshot = SpatialPartitionSnapshot{
            .static_items = self.static_renderable_items.items.len,
            .dynamic_items = self.dynamic_renderable_items.items.len,
        };
        if (g_logged_spatial_partition_snapshot == null or
            g_logged_spatial_partition_snapshot.?.static_items != snapshot.static_items or
            g_logged_spatial_partition_snapshot.?.dynamic_items != snapshot.dynamic_items or
            rebuilt_static or
            rebuilt_dynamic)
        {
            spatial_log.info(
                "renderable spatial partitions synced static_items={} dynamic_items={} rebuilt_static={} rebuilt_dynamic={}",
                .{ snapshot.static_items, snapshot.dynamic_items, rebuilt_static, rebuilt_dynamic },
            );
            g_logged_spatial_partition_snapshot = snapshot;
        }
    }

    fn hasDirtyEntities(self: *const World) bool {
        for (self.entities.items) |entity| {
            if (entity.dirty) {
                return true;
            }
        }
        return false;
    }

    fn appendBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        allocator: std.mem.Allocator,
        item: spatial_index_mod.BoundsItem,
    ) !void {
        const next_index = items.items.len;
        try items.append(allocator, item);
        errdefer _ = items.pop();
        try indices.put(item.id, next_index);
    }

    fn appendRenderableRayCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        candidates: *std.ArrayList(RenderableRayCandidate),
        source: []const spatial_index_mod.RayCandidate,
    ) !void {
        try candidates.ensureUnusedCapacity(allocator, source.len);
        for (source) |candidate| {
            const bounds = self.worldBoundsConst(candidate.id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            candidates.appendAssumeCapacity(.{
                .id = candidate.id,
                .bounds = bounds,
                .enter_distance = candidate.enter_distance,
            });
        }
    }

    const BoundsItemChange = enum {
        unchanged,
        updated,
        inserted,
    };

    fn upsertBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        allocator: std.mem.Allocator,
        item: spatial_index_mod.BoundsItem,
    ) !BoundsItemChange {
        if (indices.get(item.id)) |item_index| {
            if (std.meta.eql(items.items[item_index].bounds, item.bounds)) {
                return .unchanged;
            }
            items.items[item_index] = item;
            return .updated;
        }

        try appendBoundsItem(items, indices, allocator, item);
        return .inserted;
    }

    fn removeBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        item_id: EntityId,
    ) bool {
        const item_index = indices.get(item_id) orelse return false;
        const moved_item = items.items[items.items.len - 1];
        _ = items.swapRemove(item_index);
        _ = indices.remove(item_id);
        if (item_index < items.items.len) {
            indices.put(moved_item.id, item_index) catch {};
        }
        return true;
    }

    fn lessThanRenderableRayCandidateDistance(_: void, lhs: RenderableRayCandidate, rhs: RenderableRayCandidate) bool {
        return lhs.enter_distance < rhs.enter_distance;
    }

    fn nextAvailableDerivedName(self: *const World, base_name: []const u8, suffix: []const u8) ![]u8 {
        var candidate = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base_name, suffix });
        if (!self.entityNameExists(candidate)) {
            return candidate;
        }
        self.allocator.free(candidate);

        var index: usize = 2;
        while (true) : (index += 1) {
            candidate = try std.fmt.allocPrint(self.allocator, "{s}{s} {d}", .{ base_name, suffix, index });
            if (!self.entityNameExists(candidate)) {
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }

    fn entityNameExists(self: *const World, candidate: []const u8) bool {
        for (self.entities.items) |entity| {
            if (std.mem.eql(u8, entity.name, candidate)) {
                return true;
            }
        }
        return false;
    }

    fn releaseVfxRuntime(self: *World, destroy_particles: bool) void {
        while (self.vfx_runtime_emitters.items.len > 0) {
            self.clearVfxEmitterAtIndex(self.vfx_runtime_emitters.items.len - 1, destroy_particles);
        }
        self.vfx_runtime_emitters.deinit(self.allocator);
        self.vfx_runtime_emitters = .empty;
    }

    fn clearVfxEmitterAtIndex(self: *World, index: usize, destroy_particles: bool) void {
        var emitter = self.vfx_runtime_emitters.orderedRemove(index);
        if (destroy_particles) {
            const particle_ids = emitter.particles.items(.entity_id);
            for (particle_ids) |particle_id| {
                _ = self.destroyEntity(particle_id);
            }
        }
        emitter.deinit(self.allocator);
    }

    fn removeVfxEmittersForEntities(self: *World, entity_ids: []const EntityId) void {
        var index: usize = 0;
        while (index < self.vfx_runtime_emitters.items.len) {
            if (sliceContainsEntityId(entity_ids, self.vfx_runtime_emitters.items[index].entity_id)) {
                self.clearVfxEmitterAtIndex(index, false);
                continue;
            }
            index += 1;
        }
    }

    fn removeAnimatorBinding(self: *World, animator_entity_id: EntityId) void {
        for (self.animator_bindings.items, 0..) |binding, index| {
            if (binding.animator_entity_id != animator_entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
            _ = self.animator_bindings.swapRemove(index);
            return;
        }
    }

    fn removeSkinnedMeshBinding(self: *World, entity_id: EntityId) void {
        for (self.skinned_mesh_bindings.items, 0..) |binding, index| {
            if (binding.entity_id != entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            _ = self.skinned_mesh_bindings.swapRemove(index);
            return;
        }
    }

    pub fn createPrefab(self: *World, root_entity_id: EntityId, prefab_id: []const u8) !void {
        var prefab_value = try prefab_mod.createPrefabFromEntities(
            self.allocator,
            self,
            root_entity_id,
            prefab_id,
        );
        errdefer prefab_value.deinit();

        const prefab = try self.allocator.create(prefab_mod.PrefabResource);
        errdefer self.allocator.destroy(prefab);
        prefab.* = prefab_value;
        try self.prefab_library.registerPrefab(prefab);
    }

    pub fn loadPrefab(self: *World, path: []const u8) !prefab_mod.PrefabId {
        var prefab_value = try prefab_mod.loadPrefabFromPath(self.allocator, path);
        errdefer prefab_value.deinit();

        const prefab = try self.allocator.create(prefab_mod.PrefabResource);
        errdefer self.allocator.destroy(prefab);
        prefab.* = prefab_value;

        const prefab_id = try self.allocator.dupe(u8, prefab.id);
        errdefer self.allocator.free(prefab_id);
        try self.prefab_library.registerPrefab(prefab);
        return prefab_id;
    }

    pub fn savePrefab(self: *World, id: []const u8, path: []const u8) !void {
        const prefab = self.prefab_library.getPrefab(id) orelse return error.PrefabNotFound;
        try prefab_mod.savePrefabToPath(self.allocator, prefab, path);
        if (prefab.source_path) |existing| {
            self.allocator.free(existing);
        }
        prefab.source_path = try self.allocator.dupe(u8, path);
    }

    pub fn instantiatePrefab(self: *World, prefab_id: []const u8, options: prefab_mod.InstantiateOptions) !EntityId {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;
        return try prefab_mod.instantiatePrefab(self.allocator, self, prefab, options);
    }

    pub fn getPrefab(self: *const World, id: []const u8) ?*prefab_mod.PrefabResource {
        return self.prefab_library.getPrefab(id);
    }

    pub fn removePrefab(self: *World, id: []const u8) !void {
        if (!self.prefab_library.removePrefab(id)) {
            return error.PrefabNotFound;
        }
    }

    pub fn detectPrefabDiff(self: *World, old_prefab_id: []const u8, new_prefab_id: []const u8) !prefab_mod.PrefabDiff {
        const old_prefab = self.prefab_library.getPrefab(old_prefab_id) orelse
            return error.PrefabNotFound;
        const new_prefab = self.prefab_library.getPrefab(new_prefab_id) orelse
            return error.PrefabNotFound;
        return try prefab_mod.detectDiffs(self.allocator, old_prefab, new_prefab);
    }

    pub fn updatePrefabInstance(self: *World, root_entity_id: EntityId, prefab_id: []const u8) !void {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;
        var diff = try detectEntityTreeDiff(self, root_entity_id, prefab);
        defer diff.deinit();
        try prefab_mod.updatePrefabInstance(self, root_entity_id, &diff, prefab);
    }

    pub fn updateAllPrefabInstances(self: *World, prefab_id: []const u8) !usize {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;

        var updated_count: usize = 0;
        for (self.entities.items) |*entity| {
            if (!isPrefabRootEntity(entity)) {
                continue;
            }
            if (entity.prefab_instance_override) |*override| {
                if (!std.mem.eql(u8, override.prefab_id, prefab_id)) {
                    continue;
                }

                var diff = try detectEntityTreeDiff(self, entity.id, prefab);
                defer diff.deinit();

                try prefab_mod.updatePrefabInstance(self, entity.id, &diff, prefab);
                override.prefab_version = prefab.version;
                updated_count += 1;
            }
        }

        return updated_count;
    }

    pub fn applyPrefabUpdate(self: *World, old_prefab_id: []const u8, new_prefab_id: []const u8) !void {
        var diff = try self.detectPrefabDiff(old_prefab_id, new_prefab_id);
        defer diff.deinit();

        const new_prefab = self.getPrefab(new_prefab_id) orelse
            return error.PrefabNotFound;

        for (self.entities.items) |*entity| {
            if (!isPrefabRootEntity(entity)) {
                continue;
            }
            if (entity.prefab_instance_override) |*override| {
                if (!std.mem.eql(u8, override.prefab_id, old_prefab_id)) {
                    continue;
                }

                try prefab_mod.updatePrefabInstance(self, entity.id, &diff, new_prefab);
                self.allocator.free(override.prefab_id);
                override.prefab_id = try self.allocator.dupe(u8, new_prefab_id);
                override.prefab_version = new_prefab.version;
            }
        }
    }

    pub fn revertPrefabOverride(self: *World, entity_id: EntityId) !void {
        const entity = self.getEntity(entity_id) orelse return error.EntityNotFound;
        if (entity.prefab_instance_override) |*override| {
            if (override.override_mask.local_transform) {
                if (override.local_transform_override) |transform| {
                    entity.local_transform = transform;
                }
            }
            if (override.override_mask.visible) {
                if (override.visible_override) |visible| {
                    entity.visible = visible;
                }
            }
            override.deinit(self.allocator);
            entity.prefab_instance_override = null;
        }
    }
};

fn sliceContainsEntityId(entity_ids: []const EntityId, entity_id: EntityId) bool {
    for (entity_ids) |candidate| {
        if (candidate == entity_id) {
            return true;
        }
    }
    return false;
}

fn indexOfEntityId(entity_ids: []const EntityId, entity_id: EntityId) ?usize {
    for (entity_ids, 0..) |candidate, index| {
        if (candidate == entity_id) {
            return index;
        }
    }
    return null;
}

fn composeTransform(parent: components.Transform, local: components.Transform) components.Transform {
    const quat = @import("../math/quat.zig");
    return .{
        .translation = vec3.add(
            parent.translation,
            quat.rotateVec3(parent.rotation, vec3.mul(parent.scale, local.translation)),
        ),
        .rotation = quat.mul(parent.rotation, local.rotation),
        .scale = vec3.mul(parent.scale, local.scale),
    };
}

fn relativeTransform(parent: components.Transform, world: components.Transform) components.Transform {
    const quat = @import("../math/quat.zig");
    const delta = vec3.sub(world.translation, parent.translation);
    const local_translation = vec3.divSafe(
        quat.rotateVec3(quat.inverse(parent.rotation), delta),
        parent.scale,
        compose_epsilon,
    );

    return .{
        .translation = local_translation,
        .rotation = quat.mul(quat.inverse(parent.rotation), world.rotation),
        .scale = vec3.divSafe(world.scale, parent.scale, compose_epsilon),
    };
}

fn rotateVec3Euler(rotation: components.Vec3, vector: components.Vec3) components.Vec3 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn inverseRotateVec3Euler(rotation: components.Vec3, vector: components.Vec3) components.Vec3 {
    return rotateX(-rotation[0], rotateY(-rotation[1], rotateZ(-rotation[2], vector)));
}

fn rotateX(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

test "bootstrap creates a minimal 3D scene" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();

    const result = world.summary();
    try std.testing.expectEqual(@as(usize, 4), result.entity_count);
    try std.testing.expectEqual(@as(usize, 1), result.camera_count);
    try std.testing.expectEqual(@as(usize, 2), result.mesh_count);
    try std.testing.expectEqual(@as(usize, 1), result.light_count);
    try std.testing.expect(world.findEntityByName("Hero") != null);
}

test "glTF static import creates world entities, textures, normals, tangents, and multi primitive materials" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const report = try world.importGltfStaticModel(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ -2.0, 0.0, 0.0 },
        },
    );

    // 1 个 node 实体 + 1 个额外的 primitive 实体 = 2 个实体
    // (mesh 有 2 个 primitives，第一个使用 node 实体，第二个创建子实体)
    try std.testing.expectEqual(@as(usize, 2), report.entity_count);
    try std.testing.expectEqual(@as(usize, 2), report.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), report.material_count);
    try std.testing.expectEqual(@as(usize, 1), report.texture_count);
    // 第一个 primitive 使用 node 实体，名称为 "guava_showcase_GuavaShowcase"
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase") != null);
    // 第二个 primitive 创建子实体，名称为 "guava_showcase_GuavaShowcase_1"
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase_1") != null);

    const imported = world.findEntityByName("guava_showcase_GuavaShowcase").?;
    const mesh = world.resources.mesh(imported.mesh.?.handle.?).?;
    const material = world.resources.material(imported.material.?.handle.?).?;

    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].normal[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].tangent[0], 0.0001);
    try std.testing.expect(material.base_color_texture != null);
}

test "glTF instance import creates a movable root entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const report = try world.importGltfStaticModelInstance(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ 3.0, 2.0, 1.0 },
        },
    );

    try std.testing.expect(report.root_entity != null);
    const root = world.getEntityConst(report.root_entity.?).?;
    try std.testing.expectEqualStrings("guava_showcase Instance", root.name);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), root.local_transform.translation[0], 0.0001);

    // 根实例实体 + node 实体 + 额外的 primitive 实体 = 3 个实体
    // 第一个 primitive 使用 node 实体，名称为 "guava_showcase_GuavaShowcase"
    const imported = world.findEntityByName("guava_showcase_GuavaShowcase").?;
    // node 实体的父实体是根实例
    try std.testing.expectEqual(report.root_entity.?, imported.parent.?);
    const imported_world = world.worldTransform(imported.id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), imported_world.translation[0], 0.0001);
    try std.testing.expectEqual(@as(usize, 3), report.entity_count);
}

test "world supports editor duplicate and destroy operations" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    const source = world.findEntityByName("Hero").?.id;
    const duplicate = try world.duplicateEntity(source);
    try std.testing.expect(duplicate != source);
    try std.testing.expect(world.findEntityByName("Hero Copy") != null);
    try std.testing.expect(world.destroyEntity(source));
    try std.testing.expect(world.findEntityByName("Hero") == null);
}

test "createVfxEntity adds a selectable VFX anchor entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createVfxEntity(.fountain, .{
        .translation = .{ 1.0, 2.0, 3.0 },
    });
    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expect(entity.vfx != null);
    try std.testing.expectEqual(components.VfxKind.fountain, entity.vfx.?.kind);
    try std.testing.expect(entity.mesh != null);
    try std.testing.expect(entity.material != null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), entity.local_transform.translation[0], 0.0001);
}

test "world hierarchy composes transforms and preserves world space on reparent" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const parent_a = try world.createEntity(.{
        .name = "ParentA",
        .local_transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });
    const parent_b = try world.createEntity(.{
        .name = "ParentB",
        .local_transform = .{
            .translation = .{ 10.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = parent_a,
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });

    const before = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), before.translation[0], 0.0001);

    try std.testing.expect(try world.setParent(child, parent_b));
    const after = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), after.translation[0], 0.0001);
    const local = world.getEntityConst(child).?.local_transform;
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), local.translation[0], 0.0001);
}

test "duplicateEntity copies subtrees and destroyEntity removes descendants" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "RigRoot",
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "RigChild",
        .parent = root,
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 0.0 },
        },
    });

    const duplicate_root = try world.duplicateEntity(root);
    try std.testing.expect(duplicate_root != root);
    try std.testing.expect(world.findEntityByName("RigRoot Copy") != null);
    try std.testing.expect(world.findEntityByName("RigChild Copy") != null);
    const duplicate_child = world.findEntityByName("RigChild Copy").?;
    try std.testing.expectEqual(duplicate_root, duplicate_child.parent.?);

    try std.testing.expect(world.destroyEntity(root));
    try std.testing.expect(world.findEntityByName("RigRoot") == null);
    try std.testing.expect(world.findEntityByName("RigChild") == null);
    try std.testing.expect(world.findEntityByName("RigRoot Copy") != null);
    try std.testing.expect(world.findEntityByName("RigChild Copy") != null);
    _ = child;
}

test "folder entities preserve folder state through duplication" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const folder = try world.createFolderEntity(.{
        .translation = .{ 2.0, 0.0, 0.0 },
    });
    try std.testing.expect(world.getEntityConst(folder).?.is_folder);
    try std.testing.expect(!world.getEntityConst(folder).?.editor_only);

    const duplicate = try world.duplicateEntity(folder);
    try std.testing.expect(world.getEntityConst(duplicate).?.is_folder);
}

test "renderable spatial index moves dirty meshes into dynamic partition" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const a = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ -2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });
    const b = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });

    const initial = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderables.count());

    try std.testing.expect(world.setEntityLocalTransform(a, .{
        .translation = .{ -1.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));

    const after_first_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_first_move);
    try std.testing.expectEqual(@as(usize, 1), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());

    try std.testing.expect(world.setEntityLocalTransform(a, .{
        .translation = .{ 0.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));

    const after_second_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_second_move);
    try std.testing.expectEqual(@as(usize, 1), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());
    try std.testing.expect(world.dynamic_renderables.contains(a));
    try std.testing.expect(!world.dynamic_renderables.contains(b));

    var reintegration_step: u8 = 0;
    while (reintegration_step < dynamic_reintegration_query_threshold) : (reintegration_step += 1) {
        const steady_query = try world.queryRenderableRayCandidates(
            std.testing.allocator,
            .{ -5.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            16.0,
        );
        defer std.testing.allocator.free(steady_query);
    }

    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderables.count());
}

test "dynamic renderable movement refits dynamic BVH without growing dynamic partition" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });

    const initial_query = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial_query);

    try std.testing.expect(world.setEntityLocalTransform(entity_id, .{
        .translation = .{ 4.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));
    const after_first_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_first_move);
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    const first_dynamic_nodes = world.dynamic_renderable_spatial_index.nodeCount();

    try std.testing.expect(world.setEntityLocalTransform(entity_id, .{
        .translation = .{ 6.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));
    const after_second_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_second_move);
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(first_dynamic_nodes, world.dynamic_renderable_spatial_index.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());
}

// ========================================================================
// Prefab 相关方法
// ========================================================================

/// 从实体树创建 Prefab
pub fn createPrefab(
    self: *World,
    root_entity_id: EntityId,
    prefab_id: []const u8,
) !void {
    var prefab_value = try prefab_mod.createPrefabFromEntities(
        self.allocator,
        self,
        root_entity_id,
        prefab_id,
    );
    errdefer prefab_value.deinit();

    const prefab = try self.allocator.create(prefab_mod.PrefabResource);
    errdefer self.allocator.destroy(prefab);
    prefab.* = prefab_value;
    try self.prefab_library.registerPrefab(prefab);
}

/// 加载 Prefab 从文件
pub fn loadPrefab(self: *World, path: []const u8) !prefab_mod.PrefabId {
    var prefab_value = try prefab_mod.loadPrefabFromPath(self.allocator, path);
    errdefer prefab_value.deinit();

    const prefab = try self.allocator.create(prefab_mod.PrefabResource);
    errdefer self.allocator.destroy(prefab);
    prefab.* = prefab_value;

    const prefab_id = try self.allocator.dupe(u8, prefab.id);
    errdefer self.allocator.free(prefab_id);
    try self.prefab_library.registerPrefab(prefab);
    return prefab_id;
}

/// 保存 Prefab 到文件
pub fn savePrefab(self: *World, id: []const u8, path: []const u8) !void {
    const prefab = self.prefab_library.getPrefab(id) orelse return error.PrefabNotFound;
    try prefab_mod.savePrefabToPath(self.allocator, prefab, path);
    if (prefab.source_path) |existing| {
        self.allocator.free(existing);
    }
    prefab.source_path = try self.allocator.dupe(u8, path);
}

/// 实例化 Prefab
pub fn instantiatePrefab(
    self: *World,
    prefab_id: []const u8,
    options: prefab_mod.InstantiateOptions,
) !EntityId {
    const prefab = self.prefab_library.getPrefab(prefab_id) orelse
        return error.PrefabNotFound;
    return try prefab_mod.instantiatePrefab(self.allocator, self, prefab, options);
}

/// 获取 Prefab
pub fn getPrefab(self: *const World, id: []const u8) ?*prefab_mod.PrefabResource {
    return self.prefab_library.getPrefab(id);
}

/// 移除 Prefab
pub fn removePrefab(self: *World, id: []const u8) !void {
    if (!self.prefab_library.removePrefab(id)) {
        return error.PrefabNotFound;
    }
}

/// 检测 Prefab 差异
pub fn detectPrefabDiff(
    self: *World,
    old_prefab_id: []const u8,
    new_prefab_id: []const u8,
) !prefab_mod.PrefabDiff {
    const old_prefab = self.prefab_library.getPrefab(old_prefab_id) orelse
        return error.PrefabNotFound;
    const new_prefab = self.prefab_library.getPrefab(new_prefab_id) orelse
        return error.PrefabNotFound;
    return try prefab_mod.detectDiffs(self.allocator, old_prefab, new_prefab);
}

/// 更新 Prefab 实例
pub fn updatePrefabInstance(
    self: *World,
    root_entity_id: EntityId,
    prefab_id: []const u8,
) !void {
    const prefab = self.prefab_library.getPrefab(prefab_id) orelse
        return error.PrefabNotFound;
    var diff = try detectEntityTreeDiff(self, root_entity_id, prefab);
    defer diff.deinit();
    try prefab_mod.updatePrefabInstance(self, root_entity_id, &diff, prefab);
}

/// 批量更新所有 Prefab 实例
/// 遍历场景中所有指定 Prefab 的实例并应用最新版本
pub fn updateAllPrefabInstances(self: *World, prefab_id: []const u8) !usize {
    const prefab = self.prefab_library.getPrefab(prefab_id) orelse
        return error.PrefabNotFound;

    var updated_count: usize = 0;

    // 遍历所有实体，查找 Prefab 实例的根实体
    for (self.entities.items) |*entity| {
        if (!isPrefabRootEntity(entity)) {
            continue;
        }
        if (entity.prefab_instance_override) |*override| {
            if (!std.mem.eql(u8, override.prefab_id, prefab_id)) {
                continue;
            }

            var diff = try detectEntityTreeDiff(self, entity.id, prefab);
            defer diff.deinit();

            try prefab_mod.updatePrefabInstance(self, entity.id, &diff, prefab);
            override.prefab_version = prefab.version;
            updated_count += 1;
        }
    }

    if (updated_count > 0) {
        std.log.info("Updated {d} Prefab instances for '{s}' to version {d}", .{
            updated_count,
            prefab_id,
            prefab.version,
        });
    }

    return updated_count;
}

/// 应用 Prefab 更新到所有实例
pub fn applyPrefabUpdate(
    self: *World,
    old_prefab_id: []const u8,
    new_prefab_id: []const u8,
) !void {
    // 检测差异
    const diff = try self.detectPrefabDiff(old_prefab_id, new_prefab_id);
    defer diff.deinit();

    const new_prefab = self.getPrefab(new_prefab_id) orelse
        return error.PrefabNotFound;

    // 查找并更新所有实例
    var updated_count: usize = 0;
    for (self.entities.items) |*entity| {
        if (isPrefabRootEntity(entity)) {
            if (entity.prefab_instance_override) |*override| {
                if (std.mem.eql(u8, override.prefab_id, old_prefab_id)) {
                    // 更新实例
                    try prefab_mod.updatePrefabInstance(self, entity.id, &diff, new_prefab);

                    // 更新 Prefab ID 引用
                    self.allocator.free(override.prefab_id);
                    override.prefab_id = try self.allocator.dupe(u8, new_prefab_id);

                    updated_count += 1;
                }
            }
        }
    }

    std.log.info("Updated {d} Prefab instances from {s} to {s}", .{
        updated_count,
        old_prefab_id,
        new_prefab_id,
    });
}

/// 检测实体树与 Prefab 的差异
fn detectEntityTreeDiff(
    self: *World,
    root_entity_id: EntityId,
    new_prefab: *const prefab_mod.PrefabResource,
) !prefab_mod.PrefabDiff {
    var diff = prefab_mod.PrefabDiff{
        .allocator = self.allocator,
        .added_entities = .empty,
        .removed_entities = .empty,
        .modified_entities = .empty,
    };
    errdefer diff.deinit();

    // 收集当前实例中的所有实体（按 prefab_entity_id）
    var instance_entity_map = std.AutoHashMap(u32, EntityId).init(self.allocator);
    defer instance_entity_map.deinit();

    try collectPrefabEntitiesRecursive(self, root_entity_id, &instance_entity_map);

    // 收集 Prefab 中的所有实体 ID
    var prefab_entity_set = std.AutoHashMap(u32, void).init(self.allocator);
    defer prefab_entity_set.deinit();

    for (new_prefab.entities) |entity| {
        try prefab_entity_set.put(entity.prefab_entity_id, {});
    }

    // 检测新增的实体（在 Prefab 中但不在实例中）
    for (new_prefab.entities) |prefab_entity| {
        if (!instance_entity_map.contains(prefab_entity.prefab_entity_id)) {
            try diff.added_entities.append(self.allocator, prefab_entity.prefab_entity_id);
        }
    }

    // 检测删除的实体（在实例中但不在 Prefab 中）
    var instance_it = instance_entity_map.keyIterator();
    while (instance_it.next()) |prefab_entity_id| {
        if (!prefab_entity_set.contains(prefab_entity_id.*)) {
            try diff.removed_entities.append(self.allocator, prefab_entity_id.*);
        }
    }

    // 检测修改的实体
    var it = instance_entity_map.iterator();
    while (it.next()) |entry| {
        const prefab_entity_id = entry.key_ptr.*;
        const entity_id = entry.value_ptr.*;

        // 查找对应的 Prefab 实体
        const prefab_entity = findPrefabEntity(self, new_prefab, prefab_entity_id) orelse continue;

        if (self.getEntity(entity_id)) |entity| {
            // 检测差异
            const entity_diff = detectSingleEntityDiff(self, entity, prefab_entity);
            if (entity_diff.has_changes) {
                try diff.modified_entities.append(self.allocator, entity_diff);
            }
        }
    }

    return diff;
}

/// 递归收集 Prefab 实例中的所有实体
fn collectPrefabEntitiesRecursive(
    self: *World,
    entity_id: EntityId,
    out_map: *std.AutoHashMap(u32, EntityId),
) !void {
    const entity = self.getEntity(entity_id) orelse return;

    // 记录实体（如果有 prefab_entity_id）
    if (entity.prefab_entity_id) |prefab_id| {
        try out_map.put(prefab_id, entity_id);
    }

    // 递归处理子实体
    for (entity.children.items) |child_id| {
        try collectPrefabEntitiesRecursive(self, child_id, out_map);
    }
}

/// 在 Prefab 中查找实体
fn findPrefabEntity(
    self: *World,
    prefab: *const prefab_mod.PrefabResource,
    prefab_entity_id: u32,
) ?*const prefab_mod.PrefabEntityData {
    _ = self;
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == prefab_entity_id) {
            return entity;
        }
    }
    return null;
}

/// 检测单个实体与 Prefab 实体的差异
fn detectSingleEntityDiff(
    self: *World,
    entity: *Entity,
    prefab_entity: *const prefab_mod.PrefabEntityData,
) prefab_mod.EntityDiff {
    _ = self;
    var diff = prefab_mod.EntityDiff{
        .prefab_entity_id = prefab_entity.prefab_entity_id,
        .has_changes = false,
        .transform_changed = false,
        .name_changed = false,
        .component_changes = .{},
    };

    // 检测名称变化
    if (!std.mem.eql(u8, entity.name, prefab_entity.name)) {
        diff.name_changed = true;
        diff.has_changes = true;
    }

    // 检测变换变化
    const et = &entity.local_transform;
    const pt = &prefab_entity.local_transform;
    if (!std.mem.eql(f32, et.translation[0..3], pt.translation[0..3]) or
        !std.mem.eql(f32, et.rotation[0..4], pt.rotation[0..4]) or
        !std.mem.eql(f32, et.scale[0..3], pt.scale[0..3]))
    {
        diff.transform_changed = true;
        diff.has_changes = true;
    }

    // 检测组件变化
    if (!equalOptionalComponents(entity.mesh, prefab_entity.mesh)) {
        diff.component_changes.mesh_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.material, prefab_entity.material)) {
        diff.component_changes.material_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.light, prefab_entity.light)) {
        diff.component_changes.light_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.camera, prefab_entity.camera)) {
        diff.component_changes.camera_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.vfx, prefab_entity.vfx)) {
        diff.component_changes.vfx_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.rigidbody, prefab_entity.rigidbody)) {
        diff.component_changes.rigidbody_changed = true;
        diff.has_changes = true;
    }

    return diff;
}

/// 比较两个可选组件是否相等
fn equalOptionalComponents(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.meta.eql(a.?, b.?);
}

/// 检查实体是否是 Prefab 实例
pub fn isPrefabInstance(self: *const World, entity_id: EntityId) bool {
    const entity = self.getEntityConst(entity_id) orelse return false;
    return entity.prefab_entity_id != null;
}

/// 获取实体的 Prefab 覆盖数据
pub fn getPrefabOverride(self: *const World, entity_id: EntityId) ?*const prefab_mod.PrefabInstanceOverride {
    const entity = self.getEntityConst(entity_id) orelse return null;
    if (entity.prefab_instance_override) |*override| {
        return override;
    }
    return null;
}

/// 应用 Prefab 覆盖 (恢复到原始值)
pub fn revertPrefabOverride(self: *World, entity_id: EntityId) !void {
    const entity = self.getEntity(entity_id) orelse return error.EntityNotFound;
    if (entity.prefab_instance_override) |*override| {
        // 恢复覆盖的字段
        if (override.override_mask.local_transform) {
            if (override.local_transform_override) |transform| {
                entity.local_transform = transform;
            }
        }
        if (override.override_mask.visible) {
            if (override.visible_override) |visible| {
                entity.visible = visible;
            }
        }
        // 释放覆盖数据
        override.deinit(self.allocator);
        entity.prefab_instance_override = null;
    }
}

test "renderable bounds frustum query reuses cached bounds for visible BVH candidates" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const near_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });
    _ = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 8.0, 0.0, 0.0 },
    });

    const query_frustum = frustum_mod.Frustum{
        .planes = .{
            .{ .normal = .{ 1.0, 0.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ -1.0, 0.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 1.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, -1.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 0.0, 1.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 0.0, -1.0 }, .distance = -2.5 },
        },
    };

    const bounds_items = try world.queryRenderableBoundsInFrustum(std.testing.allocator, query_frustum);
    defer std.testing.allocator.free(bounds_items);

    try std.testing.expectEqual(@as(usize, 1), bounds_items.len);
    try std.testing.expectEqual(near_cube, bounds_items[0].id);
    try std.testing.expectEqualDeep(world.worldBoundsConst(near_cube).?, bounds_items[0].bounds);
}

test "renderable ray bounds query returns sorted cached bounds candidates" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const near_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });
    const far_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 6.0, 0.0, 0.0 },
    });

    const candidates = try world.queryRenderableRayBounds(
        std.testing.allocator,
        .{ -4.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(near_cube, candidates[0].id);
    try std.testing.expectEqual(far_cube, candidates[1].id);
    try std.testing.expect(candidates[0].enter_distance <= candidates[1].enter_distance);
    try std.testing.expectEqualDeep(world.worldBoundsConst(near_cube).?, candidates[0].bounds);
    try std.testing.expectEqualDeep(world.worldBoundsConst(far_cube).?, candidates[1].bounds);
}

test "renderable partition caches update incrementally for create and destroy" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const first = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });

    const initial_query = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial_query);
    try std.testing.expectEqual(@as(usize, 1), world.static_renderable_items.items.len);
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_items.items.len);
    try std.testing.expect(world.static_renderable_item_indices.contains(first));

    const second = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 6.0, 0.0, 0.0 },
    });

    const after_create = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(after_create);
    try std.testing.expectEqual(@as(usize, 2), world.static_renderable_items.items.len);
    try std.testing.expect(world.static_renderable_item_indices.contains(second));

    try std.testing.expect(world.destroyEntity(first));
    const after_destroy = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(after_destroy);
    try std.testing.expectEqual(@as(usize, 1), world.static_renderable_items.items.len);
    try std.testing.expect(!world.static_renderable_item_indices.contains(first));
    try std.testing.expect(world.static_renderable_item_indices.contains(second));
    try std.testing.expectEqual(second, world.static_renderable_items.items[0].id);
}
