const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const vec3 = @import("../math/vec3.zig");

const physics_log = std.log.scoped(.physics);
const epsilon: f32 = 0.0001;

const StepSnapshot = struct {
    dynamic_bodies: usize,
    static_bodies: usize,
    contacts_resolved: usize,
};

const ContactResolution = struct {
    translation: components.Vec3,
};

var g_logged_config = false;
var g_last_snapshot: ?StepSnapshot = null;

pub const Config = struct {
    enabled: bool = true,
    fixed_timestep_seconds: f32 = 1.0 / 60.0,
    max_substeps_per_frame: u8 = 4,
    gravity: components.Vec3 = .{ 0.0, -9.81, 0.0 },
    contact_offset: f32 = 0.005,
    max_linear_speed: f32 = 100.0,
};

pub const StepStats = struct {
    dynamic_bodies: usize = 0,
    static_bodies: usize = 0,
    contacts_resolved: usize = 0,
};

pub fn step(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
    var stats = StepStats{};
    if (!config.enabled or delta_seconds <= epsilon) {
        return stats;
    }

    logConfigOnce(config);
    world.updateHierarchy();
    countBodies(world, &stats);

    integrateDynamicBodies(world, delta_seconds, config);
    world.updateHierarchy();

    stats.contacts_resolved = resolveStaticContacts(world, config);
    world.updateHierarchy();

    maybeLogStepSnapshot(stats);
    return stats;
}

fn countBodies(world: *const scene_mod.World, stats: *StepStats) void {
    for (world.entities.items) |entity| {
        if (entity.rigidbody) |body| {
            switch (body.motion_type) {
                .dynamic => stats.dynamic_bodies += 1,
                .static, .kinematic => stats.static_bodies += 1,
            }
        } else if (hasAnyCollider(&entity)) {
            stats.static_bodies += 1;
        }
    }
}

fn integrateDynamicBodies(world: *scene_mod.World, delta_seconds: f32, config: Config) void {
    var index: usize = 0;
    while (index < world.entities.items.len) : (index += 1) {
        const entity_id = world.entities.items[index].id;
        var apply_transform = false;
        var next_world_transform: components.Transform = undefined;

        {
            const entity = &world.entities.items[index];
            const body = entity.rigidbody orelse continue;
            if (body.motion_type != .dynamic) {
                continue;
            }

            var updated_body = body;
            updated_body.linear_velocity = vec3.add(
                updated_body.linear_velocity,
                vec3.scale(config.gravity, updated_body.gravity_scale * delta_seconds),
            );

            const damping = std.math.clamp(1.0 - updated_body.linear_damping * delta_seconds, 0.0, 1.0);
            updated_body.linear_velocity = vec3.scale(updated_body.linear_velocity, damping);

            const speed = vec3.length(updated_body.linear_velocity);
            if (speed > config.max_linear_speed and speed > epsilon) {
                updated_body.linear_velocity = vec3.scale(updated_body.linear_velocity, config.max_linear_speed / speed);
            }

            next_world_transform = entity.world_transform_cache;
            next_world_transform.translation = vec3.add(
                next_world_transform.translation,
                vec3.scale(updated_body.linear_velocity, delta_seconds),
            );

            entity.rigidbody = updated_body;
            apply_transform = true;
        }

        if (apply_transform) {
            _ = world.setEntityWorldTransform(entity_id, next_world_transform);
        }
    }
}

fn resolveStaticContacts(world: *scene_mod.World, config: Config) usize {
    var contact_count: usize = 0;
    var index: usize = 0;
    while (index < world.entities.items.len) : (index += 1) {
        const entity_id = world.entities.items[index].id;

        var current_transform: components.Transform = undefined;
        var current_velocity: components.Vec3 = undefined;
        var has_contact = false;

        {
            const entity = &world.entities.items[index];
            const body = entity.rigidbody orelse continue;
            if (body.motion_type != .dynamic or isTriggerOnly(entity)) {
                continue;
            }

            current_transform = entity.world_transform_cache;
            current_velocity = body.linear_velocity;
        }

        var self_bounds = colliderBoundsForEntityTransform(world, entity_id, current_transform) orelse continue;

        var other_index: usize = 0;
        while (other_index < world.entities.items.len) : (other_index += 1) {
            if (other_index == index) {
                continue;
            }

            const other = &world.entities.items[other_index];
            if (!isStaticCollisionTarget(other) or isTriggerOnly(other)) {
                continue;
            }

            const other_bounds = colliderBoundsForEntityTransform(world, other.id, other.world_transform_cache) orelse continue;
            const resolution = resolveAabbPenetration(self_bounds, other_bounds, current_velocity, config.contact_offset) orelse continue;

            current_transform.translation = vec3.add(current_transform.translation, resolution.translation);
            current_velocity = zeroVelocityOnResolvedAxes(current_velocity, resolution.translation);
            self_bounds = translateBounds(self_bounds, resolution.translation);
            contact_count += 1;
            has_contact = true;
        }

        if (!has_contact) {
            continue;
        }

        _ = world.setEntityWorldTransform(entity_id, current_transform);
        if (world.getEntity(entity_id)) |entity| {
            if (entity.rigidbody) |*body| {
                body.linear_velocity = current_velocity;
            }
        }
    }

    return contact_count;
}

fn colliderBoundsForEntityTransform(
    world: *const scene_mod.World,
    entity_id: scene_mod.EntityId,
    world_transform: components.Transform,
) ?AABB {
    const entity = world.getEntityConst(entity_id) orelse return null;
    var combined = AABB.empty();

    if (entity.box_collider) |collider| {
        const local_bounds = AABB{
            .min = vec3.sub(collider.center, collider.half_extents),
            .max = vec3.add(collider.center, collider.half_extents),
        };
        combined.expandAABB(local_bounds.transformed(world_transform));
    }

    if (entity.sphere_collider) |collider| {
        const radius_vec: components.Vec3 = .{ collider.radius, collider.radius, collider.radius };
        const local_bounds = AABB{
            .min = vec3.sub(collider.center, radius_vec),
            .max = vec3.add(collider.center, radius_vec),
        };
        combined.expandAABB(local_bounds.transformed(world_transform));
    }

    if (entity.mesh_collider) |collider| {
        if (resolveAttachedMeshBounds(world, entity, collider)) |mesh_bounds| {
            combined.expandAABB(mesh_bounds.transformed(world_transform));
        }
    }

    return if (combined.isValid()) combined else null;
}

fn resolveAttachedMeshBounds(
    world: *const scene_mod.World,
    entity: *const scene_mod.Entity,
    collider: components.MeshCollider,
) ?AABB {
    if (!collider.use_attached_mesh) {
        return null;
    }

    if (entity.mesh) |mesh| {
        if (mesh.handle) |handle| {
            if (world.resources.mesh(handle)) |mesh_resource| {
                return mesh_resource.local_bounds;
            }
        }
    }

    if (entity.skinned_mesh) |skinned_mesh| {
        if (skinned_mesh.mesh_handle) |handle| {
            if (world.resources.mesh(handle)) |mesh_resource| {
                return mesh_resource.local_bounds;
            }
        }
    }

    return null;
}

fn hasAnyCollider(entity: *const scene_mod.Entity) bool {
    return entity.box_collider != null or entity.sphere_collider != null or entity.mesh_collider != null;
}

fn isStaticCollisionTarget(entity: *const scene_mod.Entity) bool {
    if (!hasAnyCollider(entity)) {
        return false;
    }

    if (entity.rigidbody) |body| {
        return body.motion_type != .dynamic;
    }

    return true;
}

fn isTriggerOnly(entity: *const scene_mod.Entity) bool {
    var has_collider = false;
    var has_solid = false;

    if (entity.box_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }
    if (entity.sphere_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }
    if (entity.mesh_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }

    return has_collider and !has_solid;
}

fn translateBounds(bounds: AABB, offset: components.Vec3) AABB {
    return .{
        .min = vec3.add(bounds.min, offset),
        .max = vec3.add(bounds.max, offset),
    };
}

fn resolveAabbPenetration(
    dynamic_bounds: AABB,
    static_bounds: AABB,
    velocity: components.Vec3,
    contact_offset: f32,
) ?ContactResolution {
    if (!dynamic_bounds.isValid() or !static_bounds.isValid()) {
        return null;
    }

    if (dynamic_bounds.max[0] <= static_bounds.min[0] or dynamic_bounds.min[0] >= static_bounds.max[0] or
        dynamic_bounds.max[1] <= static_bounds.min[1] or dynamic_bounds.min[1] >= static_bounds.max[1] or
        dynamic_bounds.max[2] <= static_bounds.min[2] or dynamic_bounds.min[2] >= static_bounds.max[2])
    {
        return null;
    }

    const move_x = chooseSeparation(
        dynamic_bounds.min[0],
        dynamic_bounds.max[0],
        static_bounds.min[0],
        static_bounds.max[0],
        velocity[0],
        contact_offset,
    );
    const move_y = chooseSeparation(
        dynamic_bounds.min[1],
        dynamic_bounds.max[1],
        static_bounds.min[1],
        static_bounds.max[1],
        velocity[1],
        contact_offset,
    );
    const move_z = chooseSeparation(
        dynamic_bounds.min[2],
        dynamic_bounds.max[2],
        static_bounds.min[2],
        static_bounds.max[2],
        velocity[2],
        contact_offset,
    );

    var translation: components.Vec3 = .{ move_x, 0.0, 0.0 };
    var min_axis_move = @abs(move_x);

    if (@abs(move_y) < min_axis_move) {
        min_axis_move = @abs(move_y);
        translation = .{ 0.0, move_y, 0.0 };
    }
    if (@abs(move_z) < min_axis_move) {
        translation = .{ 0.0, 0.0, move_z };
    }

    return .{ .translation = translation };
}

fn chooseSeparation(
    dynamic_min: f32,
    dynamic_max: f32,
    static_min: f32,
    static_max: f32,
    axis_velocity: f32,
    contact_offset: f32,
) f32 {
    const move_negative = static_min - dynamic_max - contact_offset;
    const move_positive = static_max - dynamic_min + contact_offset;

    if (axis_velocity > epsilon) {
        return move_negative;
    }
    if (axis_velocity < -epsilon) {
        return move_positive;
    }

    return if (@abs(move_negative) < @abs(move_positive)) move_negative else move_positive;
}

fn zeroVelocityOnResolvedAxes(velocity: components.Vec3, translation: components.Vec3) components.Vec3 {
    var result = velocity;
    if (@abs(translation[0]) > epsilon) {
        result[0] = 0.0;
    }
    if (@abs(translation[1]) > epsilon) {
        result[1] = 0.0;
    }
    if (@abs(translation[2]) > epsilon) {
        result[2] = 0.0;
    }
    return result;
}

fn logConfigOnce(config: Config) void {
    if (g_logged_config) {
        return;
    }

    physics_log.info(
        "physics config enabled fixed_dt={d:.5} gravity=({d:.2},{d:.2},{d:.2}) max_substeps={d}",
        .{
            config.fixed_timestep_seconds,
            config.gravity[0],
            config.gravity[1],
            config.gravity[2],
            config.max_substeps_per_frame,
        },
    );
    g_logged_config = true;
}

fn maybeLogStepSnapshot(stats: StepStats) void {
    const snapshot = StepSnapshot{
        .dynamic_bodies = stats.dynamic_bodies,
        .static_bodies = stats.static_bodies,
        .contacts_resolved = stats.contacts_resolved,
    };

    if (g_last_snapshot) |previous| {
        if (previous.dynamic_bodies == snapshot.dynamic_bodies and
            previous.static_bodies == snapshot.static_bodies and
            previous.contacts_resolved == snapshot.contacts_resolved)
        {
            return;
        }
    }

    physics_log.info(
        "physics step active dynamic={d} static={d} contacts={d}",
        .{ snapshot.dynamic_bodies, snapshot.static_bodies, snapshot.contacts_resolved },
    );
    g_last_snapshot = snapshot;
}

test "physics step integrates gravity and resolves static box contact" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "Ground",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 5.0, 0.5, 5.0 } },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_damping = 0.0,
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{
            .translation = .{ 0.0, 3.0, 0.0 },
        },
    });

    var step_index: usize = 0;
    while (step_index < 180) : (step_index += 1) {
        _ = step(&world, 1.0 / 60.0, .{});
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), body.world_transform_cache.translation[1], 0.06);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[1], 0.05);
}

test "physics step preserves kinematic bodies as static colliders" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "Wall",
        .rigidbody = .{ .motion_type = .kinematic },
        .box_collider = .{ .half_extents = .{ 0.5, 2.0, 2.0 } },
        .local_transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_velocity = .{ 5.0, 0.0, 0.0 },
            .gravity_scale = 0.0,
            .linear_damping = 0.0,
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
    });

    var step_index: usize = 0;
    while (step_index < 30) : (step_index += 1) {
        _ = step(&world, 1.0 / 60.0, .{});
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expect(body.world_transform_cache.translation[0] <= 1.0 + 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[0], 0.05);
}
