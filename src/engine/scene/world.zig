const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const gltf_import = @import("../assets/gltf_import.zig");
const components = @import("components.zig");

const compose_epsilon = 0.0001;

pub const EntityId = u64;

pub const Entity = struct {
    id: EntityId,
    name: []u8,
    parent: ?EntityId = null,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    editor_only: bool = false,
};

pub const EntityDesc = struct {
    name: []const u8,
    parent: ?EntityId = null,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    editor_only: bool = false,
};

pub const Summary = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    resources: assets_lib.ResourceLibrary,
    entities: std.ArrayList(Entity) = .empty,
    next_id: EntityId = 1,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .resources = assets_lib.ResourceLibrary.init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        self.clearStorage(false);
    }

    pub fn clear(self: *World) void {
        self.clearStorage(true);
    }

    fn clearStorage(self: *World, reinitialize: bool) void {
        for (self.entities.items) |entity| {
            self.allocator.free(entity.name);
        }
        self.entities.deinit(self.allocator);
        self.resources.deinit();
        if (reinitialize) {
            self.entities = .empty;
            self.resources = assets_lib.ResourceLibrary.init(self.allocator);
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

        const owned_name = try self.allocator.dupe(u8, desc.name);
        try self.entities.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .parent = desc.parent,
            .transform = desc.transform,
            .camera = desc.camera,
            .mesh = desc.mesh,
            .material = desc.material,
            .light = desc.light,
            .editor_only = desc.editor_only,
        });

        return id;
    }

    pub fn getEntity(self: *World, id: EntityId) ?*Entity {
        for (self.entities.items) |*entity| {
            if (entity.id == id) {
                return entity;
            }
        }
        return null;
    }

    pub fn getEntityConst(self: *const World, id: EntityId) ?*const Entity {
        for (self.entities.items) |*entity| {
            if (entity.id == id) {
                return entity;
            }
        }
        return null;
    }

    pub fn hasEntity(self: *const World, id: EntityId) bool {
        return self.getEntityConst(id) != null;
    }

    pub fn parentEntity(self: *const World, id: EntityId) ?EntityId {
        const entity = self.getEntityConst(id) orelse return null;
        return entity.parent;
    }

    pub fn worldTransform(self: *const World, id: EntityId) ?components.Transform {
        return self.worldTransformRecursive(id, 0);
    }

    pub fn setEntityWorldTransform(self: *World, id: EntityId, world_transform: components.Transform) bool {
        const entity = self.getEntity(id) orelse return false;
        if (entity.parent) |parent_id| {
            const parent_world = self.worldTransform(parent_id) orelse return false;
            entity.transform = relativeTransform(parent_world, world_transform);
        } else {
            entity.transform = world_transform;
        }
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

        entity.parent = parent_id;
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
        entity.parent = parent_id;
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
            .transform = transform,
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
            .transform = transform,
        });
    }

    pub fn createCameraEntity(self: *World, transform: components.Transform) !EntityId {
        const entity_name = try self.nextAvailableName("Camera");
        defer self.allocator.free(entity_name);

        return self.createEntity(.{
            .name = entity_name,
            .transform = transform,
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
            .transform = light_transform,
            .mesh = mesh,
            .material = material,
            .light = .{
                .kind = kind,
                .intensity = intensity,
                .range = if (kind == .point) 12.0 else 10.0,
            },
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
            .transform = .{
                .translation = .{ 0.0, 1.5, 5.0 },
            },
        });

        _ = try self.createEntity(.{
            .name = "Sun",
            .light = .{
                .kind = .directional,
                .intensity = 4.0,
            },
            .transform = .{
                .rotation_euler = .{ -0.9, 0.6, 0.0 },
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
            .transform = .{
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
            .transform = .{
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

    pub fn importGltfStaticModelInstance(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
    ) !gltf_import.ImportReport {
        return gltf_import.importStaticModelInstance(self, path, root_transform);
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
            return composeTransform(parent_world, entity.transform);
        }
        return entity.transform;
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
        for (self.entities.items, 0..) |entity, index| {
            if (entity.id == id) {
                self.allocator.free(entity.name);
                _ = self.entities.orderedRemove(index);
                return;
            }
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
            .transform = source.transform,
            .camera = duplicate_camera,
            .mesh = source.mesh,
            .material = source.material,
            .light = source.light,
            .editor_only = source.editor_only,
        });

        for (child_ids.items) |child_id| {
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
    return .{
        .translation = addVec3(
            parent.translation,
            rotateVec3Euler(parent.rotation_euler, mulVec3(parent.scale, local.translation)),
        ),
        .rotation_euler = addVec3(parent.rotation_euler, local.rotation_euler),
        .scale = mulVec3(parent.scale, local.scale),
    };
}

fn relativeTransform(parent: components.Transform, world: components.Transform) components.Transform {
    const delta = subVec3(world.translation, parent.translation);
    const local_translation = divVec3Safe(
        inverseRotateVec3Euler(parent.rotation_euler, delta),
        parent.scale,
    );

    return .{
        .translation = local_translation,
        .rotation_euler = subVec3(world.rotation_euler, parent.rotation_euler),
        .scale = divVec3Safe(world.scale, parent.scale),
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

fn addVec3(a: components.Vec3, b: components.Vec3) components.Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn subVec3(a: components.Vec3, b: components.Vec3) components.Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mulVec3(a: components.Vec3, b: components.Vec3) components.Vec3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

fn divVec3Safe(a: components.Vec3, b: components.Vec3) components.Vec3 {
    return .{
        a[0] / if (@abs(b[0]) <= compose_epsilon) 1.0 else b[0],
        a[1] / if (@abs(b[1]) <= compose_epsilon) 1.0 else b[1],
        a[2] / if (@abs(b[2]) <= compose_epsilon) 1.0 else b[2],
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
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), root.transform.translation[0], 0.0001);

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

test "world hierarchy composes transforms and preserves world space on reparent" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const parent_a = try world.createEntity(.{
        .name = "ParentA",
        .transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });
    const parent_b = try world.createEntity(.{
        .name = "ParentB",
        .transform = .{
            .translation = .{ 10.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = parent_a,
        .transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });

    const before = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), before.translation[0], 0.0001);

    try std.testing.expect(try world.setParent(child, parent_b));
    const after = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), after.translation[0], 0.0001);
    const local = world.getEntityConst(child).?.transform;
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), local.translation[0], 0.0001);
}

test "duplicateEntity copies subtrees and destroyEntity removes descendants" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "RigRoot",
        .transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "RigChild",
        .parent = root,
        .transform = .{
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
