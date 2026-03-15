const std = @import("std");
const components = @import("components.zig");

pub const EntityId = u64;

pub const Entity = struct {
    id: EntityId,
    name: []u8,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
};

pub const EntityDesc = struct {
    name: []const u8,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
};

pub const Summary = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(Entity) = .empty,
    next_id: EntityId = 1,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scene) void {
        for (self.entities.items) |entity| {
            self.allocator.free(entity.name);
        }
        self.entities.deinit(self.allocator);
    }

    pub fn createEntity(self: *Scene, desc: EntityDesc) !EntityId {
        const id = self.next_id;
        self.next_id += 1;

        const owned_name = try self.allocator.dupe(u8, desc.name);
        try self.entities.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .transform = desc.transform,
            .camera = desc.camera,
            .mesh = desc.mesh,
            .material = desc.material,
            .light = desc.light,
        });

        return id;
    }

    pub fn getEntity(self: *Scene, id: EntityId) ?*Entity {
        for (self.entities.items) |*entity| {
            if (entity.id == id) {
                return entity;
            }
        }
        return null;
    }

    pub fn findEntityByName(self: *Scene, name: []const u8) ?*Entity {
        for (self.entities.items) |*entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity;
            }
        }
        return null;
    }

    pub fn summary(self: *const Scene) Summary {
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

    pub fn bootstrap3D(self: *Scene) !void {
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
            .mesh = .{ .primitive = .plane },
            .material = .{},
            .transform = .{
                .scale = .{ 10.0, 1.0, 10.0 },
            },
        });

        _ = try self.createEntity(.{
            .name = "Hero",
            .mesh = .{ .primitive = .cube },
            .material = .{},
            .transform = .{
                .translation = .{ 0.0, 1.0, 0.0 },
            },
        });
    }
};

test "bootstrap creates a minimal 3D scene" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.bootstrap3D();

    const result = scene.summary();
    try std.testing.expectEqual(@as(usize, 4), result.entity_count);
    try std.testing.expectEqual(@as(usize, 1), result.camera_count);
    try std.testing.expectEqual(@as(usize, 2), result.mesh_count);
    try std.testing.expectEqual(@as(usize, 1), result.light_count);
    try std.testing.expect(scene.findEntityByName("Hero") != null);
}
