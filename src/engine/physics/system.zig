const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const vec3 = @import("../math/vec3.zig");

const physics_log = std.log.scoped(.physics);
const epsilon: f32 = 0.0001;
const jolt_state_allocator = std.heap.page_allocator;

pub const TriggerEvent = struct {
    entity_a: EntityId,
    entity_b: EntityId,
    kind: TriggerEventKind,
};

pub const TriggerEventKind = enum(u8) {
    enter,
    stay,
    exit,
};

const PhysicsEvent = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityId,
    rigidbody_added: EntityId,
    rigidbody_removed: EntityId,
    collider_added: EntityId,
    collider_removed: EntityId,
    transform_changed: EntityId,
};

const PhysicsBodyHandle = struct {
    body_id: u32,
    cached_desc: JoltBodyDesc,
};

var g_physics_event_queue: std.ArrayListUnmanaged(PhysicsEvent) = .empty;
var g_physics_event_mutex: std.Thread.Mutex = .{};
var g_trigger_event_queue: std.ArrayListUnmanaged(TriggerEvent) = .empty;
var g_trigger_event_mutex: std.Thread.Mutex = .{};
var g_trigger_callback: ?*const fn (TriggerEvent) void = null;

const jolt_flag_has_box: u32 = 1 << 0;
const jolt_flag_has_sphere: u32 = 1 << 1;
const jolt_flag_has_mesh_proxy: u32 = 1 << 2;
const jolt_flag_body_is_sensor: u32 = 1 << 3;
const jolt_flag_allow_sleep: u32 = 1 << 4;

const StepSnapshot = struct {
    dynamic_bodies: usize,
    static_bodies: usize,
    contacts_resolved: usize,
};

const ContactResolution = struct {
    translation: components.Vec3,
};

const JoltBodyDesc = extern struct {
    entity_id: u64,
    motion_type: u32,
    flags: u32,
    mass: f32,
    gravity_scale: f32,
    linear_damping: f32,
    max_linear_speed: f32,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    box_half_extents: [3]f32,
    box_center: [3]f32,
    sphere_radius: f32,
    sphere_center: [3]f32,
    mesh_half_extents: [3]f32,
    mesh_center: [3]f32,
    layer_id: u16,
    layer_group: u16,
};

const JoltStepConfig = extern struct {
    delta_seconds: f32,
    gravity: [3]f32,
    collision_steps: u32,
    temp_allocator_size_bytes: u32,
    max_bodies: u32,
    num_body_mutexes: u32,
    max_body_pairs: u32,
    max_contact_constraints: u32,
};

const JoltBodyState = extern struct {
    entity_id: u64,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
};

const JoltStepStats = extern struct {
    dynamic_bodies: u32,
    static_bodies: u32,
    contacts_resolved: u32,
    state_count: u32,
    success: u8,
    reserved0: u8,
    reserved1: u16,
};

const JoltContext = opaque {};

const JoltBackendLimits = struct {
    temp_allocator_size_bytes: u32,
    max_bodies: u32,
    num_body_mutexes: u32,
    max_body_pairs: u32,
    max_contact_constraints: u32,

    fn eql(self: JoltBackendLimits, other: JoltBackendLimits) bool {
        return self.temp_allocator_size_bytes == other.temp_allocator_size_bytes and
            self.max_bodies == other.max_bodies and
            self.num_body_mutexes == other.num_body_mutexes and
            self.max_body_pairs == other.max_body_pairs and
            self.max_contact_constraints == other.max_contact_constraints;
    }
};

const JoltWorldState = struct {
    context: *JoltContext,
    limits: JoltBackendLimits,
};

extern fn guava_jolt_context_create(config: *const JoltStepConfig) callconv(.c) ?*JoltContext;
extern fn guava_jolt_context_destroy(context: *JoltContext) callconv(.c) void;
extern fn guava_jolt_context_step(
    context: *JoltContext,
    bodies: [*]const JoltBodyDesc,
    body_count: usize,
    config: *const JoltStepConfig,
    out_states: [*]JoltBodyState,
    state_capacity: usize,
    out_stats: *JoltStepStats,
) callconv(.c) bool;
extern fn guava_jolt_context_add_or_update_body(
    context: *JoltContext,
    desc: *const JoltBodyDesc,
    delta_seconds: f32,
) callconv(.c) bool;
extern fn guava_jolt_context_remove_body(
    context: *JoltContext,
    entity_id: u64,
) callconv(.c) bool;
extern fn guava_jolt_context_step_incremental(
    context: *JoltContext,
    delta_seconds: f32,
    collision_steps: u32,
    out_states: [*]JoltBodyState,
    state_capacity: usize,
    out_stats: *JoltStepStats,
) callconv(.c) bool;

export fn GuavaJoltEnqueueTriggerEvent(event: *const extern struct {
    entity_a: u64,
    entity_b: u64,
    kind: u8,
}) void {
    g_trigger_event_mutex.lock();
    defer g_trigger_event_mutex.unlock();
    
    const trigger_event = TriggerEvent{
        .entity_a = event.entity_a,
        .entity_b = event.entity_b,
        .kind = @enumFromInt(event.kind),
    };
    
    g_trigger_event_queue.append(jolt_state_allocator, trigger_event) catch return;
    
    if (g_trigger_callback) |callback| {
        callback(trigger_event);
    }
}

var g_logged_config = false;
var g_logged_jolt_backend = false;
var g_logged_jolt_fallback = false;
var g_last_snapshot: ?StepSnapshot = null;
var g_jolt_world_states: std.AutoHashMapUnmanaged(usize, JoltWorldState) = .empty;
var g_jolt_world_states_mutex: std.Thread.Mutex = .{};

pub const Backend = enum {
    jolt,
    builtin,
};

pub const Config = struct {
    enabled: bool = true,
    backend: Backend = .jolt,
    allow_builtin_fallback: bool = true,
    fixed_timestep_seconds: f32 = 1.0 / 60.0,
    max_substeps_per_frame: u8 = 4,
    gravity: components.Vec3 = .{ 0.0, -9.81, 0.0 },
    contact_offset: f32 = 0.005,
    max_linear_speed: f32 = 100.0,
    jolt_collision_steps: u32 = 1,
    jolt_temp_allocator_size_bytes: u32 = 10 * 1024 * 1024,
    jolt_max_bodies: u32 = 65_536,
    jolt_num_body_mutexes: u32 = 0,
    jolt_max_body_pairs: u32 = 65_536,
    jolt_max_contact_constraints: u32 = 10_240,
};

pub const StepStats = struct {
    dynamic_bodies: usize = 0,
    static_bodies: usize = 0,
    contacts_resolved: usize = 0,
};

pub fn initPhysicsEvents() void {
    g_physics_event_queue = .{};
    g_trigger_event_queue = .{};
    g_trigger_callback = null;
}

pub fn deinitPhysicsEvents() void {
    g_physics_event_queue.deinit(jolt_state_allocator);
    g_trigger_event_queue.deinit(jolt_state_allocator);
}

pub fn setTriggerCallback(callback: ?*const fn (TriggerEvent) void) void {
    g_trigger_callback = callback;
}

pub fn pollTriggerEvents() []const TriggerEvent {
    g_trigger_event_mutex.lock();
    defer g_trigger_event_mutex.unlock();
    return g_trigger_event_queue.items;
}

pub fn clearTriggerEvents() void {
    g_trigger_event_mutex.lock();
    defer g_trigger_event_mutex.unlock();
    g_trigger_event_queue.clearRetainingCapacity();
}

pub fn enqueuePhysicsEvent(event: PhysicsEvent) void {
    g_physics_event_mutex.lock();
    defer g_physics_event_mutex.unlock();
    g_physics_event_queue.append(jolt_state_allocator, event) catch return;
}

pub fn deinitWorld(world: *scene_mod.World) void {
    releaseJoltWorldState(@intFromPtr(world));
}

pub fn step(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
    if (!config.enabled or delta_seconds <= epsilon) {
        releaseJoltWorldState(@intFromPtr(world));
        return .{};
    }

    logConfigOnce(config);
    return switch (config.backend) {
        .builtin => blk: {
            releaseJoltWorldState(@intFromPtr(world));
            break :blk stepBuiltin(world, delta_seconds, config);
        },
        .jolt => stepJolt(world, delta_seconds, config),
    };
}

fn stepBuiltin(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
    var stats = StepStats{};
    world.updateHierarchy();
    countBodies(world, &stats);

    integrateDynamicBodies(world, delta_seconds, config);
    world.updateHierarchy();

    stats.contacts_resolved = resolveStaticContacts(world, config);
    world.updateHierarchy();

    maybeLogStepSnapshot(stats);
    return stats;
}

fn stepJolt(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
    if (!g_logged_jolt_backend) {
        physics_log.info("physics backend jolt active (persistent body cache)", .{});
        g_logged_jolt_backend = true;
    }

    world.updateHierarchy();

    var stats = StepStats{};
    countBodies(world, &stats);

    const limits = effectiveJoltBackendLimits(config, stats.dynamic_bodies + stats.static_bodies);
    const jolt_config = buildJoltStepConfig(config, delta_seconds, limits);
    const context = ensureJoltWorldContext(world, &jolt_config, limits) orelse
        return stepJoltFallback(world, delta_seconds, config, stats);

    processPhysicsEvents(world, context, config);

    var body_states = std.ArrayList(JoltBodyState).empty;
    defer body_states.deinit(world.allocator);
    body_states.resize(world.allocator, stats.dynamic_bodies) catch return stepJoltFallback(world, delta_seconds, config, stats);

    var jolt_stats = JoltStepStats{
        .dynamic_bodies = 0,
        .static_bodies = 0,
        .contacts_resolved = 0,
        .state_count = 0,
        .success = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };

    const success = guava_jolt_context_step_incremental(
        context,
        delta_seconds,
        config.jolt_collision_steps,
        body_states.items.ptr,
        body_states.items.len,
        &jolt_stats,
    );
    if (!success or jolt_stats.success == 0) {
        releaseJoltWorldState(@intFromPtr(world));
        return stepJoltFallback(world, delta_seconds, config, stats);
    }

    applyJoltBodyStates(world, body_states.items[0..@min(body_states.items.len, @as(usize, @intCast(jolt_stats.state_count)))]);
    world.updateHierarchy();

    stats.dynamic_bodies = jolt_stats.dynamic_bodies;
    stats.static_bodies = jolt_stats.static_bodies;
    stats.contacts_resolved = jolt_stats.contacts_resolved;
    maybeLogStepSnapshot(stats);
    return stats;
}

fn processPhysicsEvents(world: *scene_mod.World, context: *JoltContext, config: Config) void {
    g_physics_event_mutex.lock();
    defer g_physics_event_mutex.unlock();

    for (g_physics_event_queue.items) |event| {
        switch (event) {
            .entity_created => |entity_id| {
                if (world.getEntityConst(entity_id)) |entity| {
                    if (buildJoltBodyDesc(world, entity, config)) |desc| {
                        _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                    }
                }
            },
            .entity_destroyed => |entity_id| {
                _ = guava_jolt_context_remove_body(context, entity_id);
            },
            .rigidbody_added, .collider_added => |entity_id| {
                if (world.getEntityConst(entity_id)) |entity| {
                    if (buildJoltBodyDesc(world, entity, config)) |desc| {
                        _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                    }
                }
            },
            .rigidbody_removed, .collider_removed => |entity_id| {
                _ = guava_jolt_context_remove_body(context, entity_id);
            },
            .transform_changed => |entity_id| {
                if (world.getEntityConst(entity_id)) |entity| {
                    if (entity.rigidbody != null or hasAnyCollider(entity)) {
                        if (buildJoltBodyDesc(world, entity, config)) |desc| {
                            _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                        }
                    }
                }
            },
        }
    }

    g_physics_event_queue.clearRetainingCapacity();
}

fn stepJoltFallback(world: *scene_mod.World, delta_seconds: f32, config: Config, fallback_counts: StepStats) StepStats {
    if (!config.allow_builtin_fallback) {
        maybeLogStepSnapshot(fallback_counts);
        return fallback_counts;
    }

    if (!g_logged_jolt_fallback) {
        physics_log.warn("jolt backend failed; falling back to builtin solver", .{});
        g_logged_jolt_fallback = true;
    }
    return stepBuiltin(world, delta_seconds, config);
}

fn buildJoltStepConfig(config: Config, delta_seconds: f32, limits: JoltBackendLimits) JoltStepConfig {
    return .{
        .delta_seconds = delta_seconds,
        .gravity = config.gravity,
        .collision_steps = @max(config.jolt_collision_steps, 1),
        .temp_allocator_size_bytes = limits.temp_allocator_size_bytes,
        .max_bodies = limits.max_bodies,
        .num_body_mutexes = limits.num_body_mutexes,
        .max_body_pairs = limits.max_body_pairs,
        .max_contact_constraints = limits.max_contact_constraints,
    };
}

fn effectiveJoltBackendLimits(config: Config, body_count: usize) JoltBackendLimits {
    const max_u32 = std.math.maxInt(u32);
    const body_count_u32 = @as(u32, @intCast(@min(body_count, max_u32)));
    const body_count_plus_padding = saturatingAddU32(body_count_u32, 16);
    const estimated_pairs = saturatingAddU32(saturatingMulU32(body_count_u32, 4), 16);
    const estimated_contacts = saturatingAddU32(saturatingMulU32(body_count_u32, 8), 16);
    return .{
        .temp_allocator_size_bytes = @max(config.jolt_temp_allocator_size_bytes, 1024 * 1024),
        .max_bodies = @max(config.jolt_max_bodies, body_count_plus_padding),
        .num_body_mutexes = config.jolt_num_body_mutexes,
        .max_body_pairs = @max(config.jolt_max_body_pairs, estimated_pairs),
        .max_contact_constraints = @max(config.jolt_max_contact_constraints, estimated_contacts),
    };
}

fn ensureJoltWorldContext(
    world: *scene_mod.World,
    create_config: *const JoltStepConfig,
    limits: JoltBackendLimits,
) ?*JoltContext {
    const key = @intFromPtr(world);
    g_jolt_world_states_mutex.lock();
    defer g_jolt_world_states_mutex.unlock();

    if (g_jolt_world_states.getPtr(key)) |state| {
        if (state.limits.eql(limits)) {
            return state.context;
        }

        guava_jolt_context_destroy(state.context);
        const replacement = guava_jolt_context_create(create_config) orelse {
            _ = g_jolt_world_states.remove(key);
            return null;
        };
        state.* = .{
            .context = replacement,
            .limits = limits,
        };
        return replacement;
    }

    const context = guava_jolt_context_create(create_config) orelse return null;
    g_jolt_world_states.put(jolt_state_allocator, key, .{
        .context = context,
        .limits = limits,
    }) catch {
        guava_jolt_context_destroy(context);
        return null;
    };
    return context;
}

fn releaseJoltWorldState(key: usize) void {
    g_jolt_world_states_mutex.lock();
    defer g_jolt_world_states_mutex.unlock();

    if (g_jolt_world_states.fetchRemove(key)) |removed| {
        guava_jolt_context_destroy(removed.value.context);
    }
}

fn applyJoltBodyStates(world: *scene_mod.World, body_states: []const JoltBodyState) void {
    for (body_states) |state| {
        const entity = world.getEntityConst(state.entity_id) orelse continue;
        const body = entity.rigidbody orelse continue;
        if (body.motion_type == .static) {
            continue;
        }

        var world_transform = entity.world_transform_cache;
        world_transform.translation = state.position;
        world_transform.rotation = state.rotation;
        _ = world.setEntityWorldTransform(state.entity_id, world_transform);

        if (world.getEntity(state.entity_id)) |entity_mut| {
            if (entity_mut.rigidbody) |*body_mut| {
                body_mut.linear_velocity = state.linear_velocity;
            }
        }
    }
}

fn buildJoltBodyDesc(world: *const scene_mod.World, entity: *const scene_mod.Entity, config: Config) ?JoltBodyDesc {
    if (!hasAnyCollider(entity)) {
        return null;
    }

    const body = entity.rigidbody orelse components.Rigidbody{ .motion_type = .static };
    const world_transform = entity.world_transform_cache;
    const scale_abs = absVec3(world_transform.scale);
    
    const layer_info = extractLayerInfo(entity);

    var desc = JoltBodyDesc{
        .entity_id = entity.id,
        .motion_type = motionTypeToJolt(body.motion_type),
        .flags = if (isTriggerOnly(entity)) jolt_flag_body_is_sensor else 0,
        .mass = body.mass,
        .gravity_scale = body.gravity_scale,
        .linear_damping = body.linear_damping,
        .max_linear_speed = config.max_linear_speed,
        .position = world_transform.translation,
        .rotation = world_transform.rotation,
        .linear_velocity = body.linear_velocity,
        .box_half_extents = .{ 0.0, 0.0, 0.0 },
        .box_center = .{ 0.0, 0.0, 0.0 },
        .sphere_radius = 0.0,
        .sphere_center = .{ 0.0, 0.0, 0.0 },
        .mesh_half_extents = .{ 0.0, 0.0, 0.0 },
        .mesh_center = .{ 0.0, 0.0, 0.0 },
        .layer_id = layer_info.id,
        .layer_group = layer_info.group,
    };
    if (body.allow_sleep) {
        desc.flags |= jolt_flag_allow_sleep;
    }

    if (entity.box_collider) |collider| {
        desc.flags |= jolt_flag_has_box;
        desc.box_half_extents = maxVec3(vec3.mul(scale_abs, collider.half_extents), .{ epsilon, epsilon, epsilon });
        desc.box_center = vec3.mul(world_transform.scale, collider.center);
    }

    if (entity.sphere_collider) |collider| {
        desc.flags |= jolt_flag_has_sphere;
        desc.sphere_radius = @max(maxComponent(scale_abs) * collider.radius, epsilon);
        desc.sphere_center = vec3.mul(world_transform.scale, collider.center);
    }

    if (entity.mesh_collider) |collider| {
        if (resolveAttachedMeshBounds(world, entity, collider)) |mesh_bounds| {
            const scaled_bounds = mesh_bounds.transformed(.{
                .scale = world_transform.scale,
            });
            if (scaled_bounds.isValid()) {
                desc.flags |= jolt_flag_has_mesh_proxy;
                desc.mesh_center = scaled_bounds.centroid();
                desc.mesh_half_extents = maxVec3(
                    vec3.scale(scaled_bounds.extent(), 0.5),
                    .{ epsilon, epsilon, epsilon },
                );
            }
        }
    }

    return if ((desc.flags & (jolt_flag_has_box | jolt_flag_has_sphere | jolt_flag_has_mesh_proxy)) != 0) desc else null;
}

fn extractLayerInfo(entity: *const scene_mod.Entity) struct { id: u16, group: u16 } {
    if (entity.box_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    if (entity.sphere_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    if (entity.mesh_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    return .{ .id = 0, .group = 0xFFFF };
}

fn motionTypeToJolt(motion_type: components.RigidbodyMotionType) u32 {
    return switch (motion_type) {
        .static => 0,
        .dynamic => 1,
        .kinematic => 2,
    };
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
        "physics config enabled backend={s} fixed_dt={d:.5} gravity=({d:.2},{d:.2},{d:.2}) max_substeps={d}",
        .{
            @tagName(config.backend),
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

fn absVec3(value: components.Vec3) components.Vec3 {
    return .{ @abs(value[0]), @abs(value[1]), @abs(value[2]) };
}

fn maxComponent(value: components.Vec3) f32 {
    return @max(value[0], @max(value[1], value[2]));
}

fn maxVec3(value: components.Vec3, min_value: components.Vec3) components.Vec3 {
    return .{
        @max(value[0], min_value[0]),
        @max(value[1], min_value[1]),
        @max(value[2], min_value[2]),
    };
}

fn saturatingAddU32(lhs: u32, rhs: u32) u32 {
    const sum, const overflowed = @addWithOverflow(lhs, rhs);
    return if (overflowed != 0) std.math.maxInt(u32) else sum;
}

fn saturatingMulU32(lhs: u32, rhs: u32) u32 {
    const product, const overflowed = @mulWithOverflow(lhs, rhs);
    return if (overflowed != 0) std.math.maxInt(u32) else product;
}

fn runGroundContactScenario(config: Config) !void {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    defer deinitWorld(&world);

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
        _ = step(&world, 1.0 / 60.0, config);
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), body.world_transform_cache.translation[1], 0.08);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[1], 0.08);
}

fn runKinematicWallScenario(config: Config) !void {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    defer deinitWorld(&world);

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
        _ = step(&world, 1.0 / 60.0, config);
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expect(body.world_transform_cache.translation[0] <= 1.0 + 0.08);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[0], 0.08);
}

test "physics builtin step integrates gravity and resolves static box contact" {
    try runGroundContactScenario(.{
        .backend = .builtin,
    });
}

test "physics jolt step integrates gravity and resolves static box contact" {
    try runGroundContactScenario(.{
        .backend = .jolt,
    });
}

test "physics builtin step preserves kinematic bodies as static colliders" {
    try runKinematicWallScenario(.{
        .backend = .builtin,
    });
}

test "physics jolt step preserves kinematic bodies as static colliders" {
    try runKinematicWallScenario(.{
        .backend = .jolt,
    });
}
