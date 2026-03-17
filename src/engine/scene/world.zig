const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const gltf_import = @import("../assets/gltf_import.zig");
const raycast_mod = @import("raycast.zig");
const components = @import("components.zig");
const vec3 = @import("../math/vec3.zig");
const AABB = @import("../math/aabb.zig").AABB;
const job_system_mod = @import("../core/job_system.zig");

const compose_epsilon = 0.0001;

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
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    children: std.ArrayListUnmanaged(EntityId) = .empty,

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        allocator.free(self.name);
    }
};

pub const EntityDesc = struct {
    name: []const u8,
    parent: ?EntityId = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
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
};

pub const World = struct {
    allocator: std.mem.Allocator,
    resources: assets_lib.ResourceLibrary,
    entities: std.ArrayList(Entity) = .empty,
    id_to_index: std.AutoHashMap(EntityId, usize),
    next_id: EntityId = 1,
    job_system: ?*job_system_mod.JobSystem = null,

    pub fn init(allocator: std.mem.Allocator, job_system: ?*job_system_mod.JobSystem) World {
        return .{
            .allocator = allocator,
            .resources = assets_lib.ResourceLibrary.init(allocator, job_system),
            .id_to_index = std.AutoHashMap(EntityId, usize).init(allocator),
            .job_system = job_system,
        };
    }

    pub fn deinit(self: *World) void {
        self.clearStorage(false);
    }

    pub fn clear(self: *World) void {
        self.clearStorage(true);
    }

    fn clearStorage(self: *World, reinitialize: bool) void {
        for (self.entities.items) |*entity| {
            entity.deinit(self.allocator);
        }
        self.entities.deinit(self.allocator);
        self.id_to_index.deinit();
        self.resources.deinit();
        if (reinitialize) {
            self.entities = .empty;
            self.id_to_index = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.resources = assets_lib.ResourceLibrary.init(self.allocator, self.job_system);
            self.next_id = 1;
        }
    }

    pub fn createEntity(self: *World, desc: EntityDesc) !EntityId {
        if (desc.parent) |parent_id| {
            if (!self.hasEntity(parent_id)) {
                return error.ParentNotFound;
            }
        }

        const id = self.next_id;
        self.next_id += 1;

        const index = self.entities.items.len;
        try self.entities.append(self.allocator, .{
            .id = id,
            .name = try self.allocator.dupe(u8, desc.name),
            .parent = desc.parent,
            .local_transform = desc.local_transform,
            .camera = desc.camera,
            .mesh = desc.mesh,
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
        if (entity.dirty) return;
        entity.dirty = true;
        for (entity.children.items) |child_id| {
            self.markDirty(child_id);
        }
    }

    pub fn setLocalTransform(self: *World, id: EntityId, local_transform: components.Transform) void {
        const entity = self.getEntity(id) orelse return;
        entity.local_transform = local_transform;
        self.markDirty(id);
    }

    pub fn localTransform(self: *const World, id: EntityId) components.Transform {
        const entity = self.getEntityConst(id) orelse return .{};
        return entity.local_transform;
    }

    pub fn updateTransforms(self: *World) void {
        for (self.entities.items) |*entity| {
            if (entity.parent == null and entity.dirty) {
                self.updateTransformRecursive(entity.id, null);
            }
        }
    }

    fn updateTransformRecursive(self: *World, id: EntityId, parent_world: ?components.Transform) void {
        const entity = self.getEntity(id) orelse return;

        const new_world = if (parent_world) |pw| composeTransform(pw, entity.local_transform) else entity.local_transform;
        entity.world_transform_cache = new_world;
        entity.dirty = false;

        for (entity.children.items) |child_id| {
            self.updateTransformRecursive(child_id, new_world);
        }
    }

    pub fn worldTransform(self: *World, id: EntityId) ?components.Transform {
        const entity = self.getEntity(id) orelse return null;
        if (!entity.dirty) {
            return entity.world_transform_cache;
        }

        const parent_world = if (entity.parent) |parent_id| self.worldTransform(parent_id) else null;
        const new_world = if (parent_world) |pw| composeTransform(pw, entity.local_transform) else entity.local_transform;

        // Re-fetch entity because worldTransform(parent_id) might have reallocated entities array
        const entity_ref = self.getEntity(id).?;
        entity_ref.world_transform_cache = new_world;
        entity_ref.dirty = false;
        return new_world;
    }

    pub fn worldTransformConst(self: *const World, id: EntityId) ?components.Transform {
        const entity = self.getEntityConst(id) orelse return null;
        if (!entity.dirty) {
            return entity.world_transform_cache;
        }
        return self.worldTransformRecursive(id, 0);
    }

    pub fn worldBounds(self: *World, id: EntityId) ?AABB {
        const entity = self.getEntity(id) orelse return null;
        if (!entity.dirty and entity.world_bounds_cache != null) {
            return entity.world_bounds_cache.?;
        }

        const world_transform_val = self.worldTransform(id) orelse return null;
        var bounds: ?AABB = null;

        const re_entity = self.getEntity(id).?;
        if (re_entity.mesh) |mesh_component| {
            if (mesh_component.handle) |handle| {
                if (self.resources.mesh(handle)) |mesh| {
                    bounds = mesh.local_bounds.transformed(world_transform_val);
                }
            }
        }

        re_entity.world_bounds_cache = bounds;
        return bounds;
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

        var index = subtree.items.len;
        while (index > 0) {
            index -= 1;
            self.removeEntityById(subtree.items[index]);
        }
        return true;
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
            if (entity.mesh != null) {
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

    pub fn raycastSurface(self: *const World, ray: raycast_mod.Ray) ?raycast_mod.SurfaceRaycastHit {
        return raycast_mod.raycastSurface(self, ray);
    }

    pub fn assets(self: *World) *assets_lib.ResourceLibrary {
        return &self.resources;
    }

    fn worldTransformRecursive(self: *const World, id: EntityId, depth: usize) ?components.Transform {
        if (depth > self.entities.items.len) {
            return null;
        }

        const entity = self.getEntityConst(id) orelse return null;
        if (entity.parent) |parent_id| {
            const parent_world = self.worldTransformRecursive(parent_id, depth + 1) orelse return null;
            return composeTransform(parent_world, entity.local_transform);
        }
        return entity.local_transform;
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

        return duplicate_id;
    }

    fn nextAvailableName(self: *const World, base_name: []const u8) ![]u8 {
        return self.nextAvailableDerivedName(base_name, "");
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
};

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
    var world = World.init(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const report = try world.importGltfStaticModel(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ -2.0, 0.0, 0.0 },
        },
    );

    try std.testing.expectEqual(@as(usize, 2), report.entity_count);
    try std.testing.expectEqual(@as(usize, 2), report.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), report.material_count);
    try std.testing.expectEqual(@as(usize, 1), report.texture_count);
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase_0") != null);
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase_1") != null);

    const imported = world.findEntityByName("guava_showcase_GuavaShowcase_0").?;
    const mesh = world.resources.mesh(imported.mesh.?.handle.?).?;
    const material = world.resources.material(imported.material.?.handle.?).?;

    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].normal[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].tangent[0], 0.0001);
    try std.testing.expect(material.base_color_texture != null);
}

test "glTF instance import creates a movable root entity" {
    var world = World.init(std.testing.allocator);
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

    const imported = world.findEntityByName("guava_showcase_GuavaShowcase_0").?;
    try std.testing.expectEqual(report.root_entity.?, imported.parent.?);
    const imported_world = world.worldTransform(imported.id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), imported_world.translation[0], 0.0001);
    try std.testing.expectEqual(@as(usize, 3), report.entity_count);
}

test "world supports editor duplicate and destroy operations" {
    var world = World.init(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const folder = try world.createFolderEntity(.{
        .translation = .{ 2.0, 0.0, 0.0 },
    });
    try std.testing.expect(world.getEntityConst(folder).?.is_folder);
    try std.testing.expect(!world.getEntityConst(folder).?.editor_only);

    const duplicate = try world.duplicateEntity(folder);
    try std.testing.expect(world.getEntityConst(duplicate).?.is_folder);
}
