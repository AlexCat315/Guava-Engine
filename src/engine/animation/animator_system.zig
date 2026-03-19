const std = @import("std");
const animation_clip_mod = @import("../assets/animation_clip_resource.zig");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const quat = @import("../math/quat.zig");

pub fn update(world: *world_mod.World, delta_seconds: f32) void {
    if (delta_seconds <= 0.0) {
        return;
    }

    var entity_index: usize = 0;
    while (entity_index < world.entities.items.len) : (entity_index += 1) {
        const entity_id = world.entities.items[entity_index].id;
        const animator_value = world.entities.items[entity_index].animator orelse continue;
        if (!animator_value.playing) {
            continue;
        }

        const clip_handle = animator_value.default_clip_handle orelse continue;
        const clip = world.resources.animationClip(clip_handle) orelse continue;
        const targets = world.animatorTargets(entity_id) orelse continue;

        var next_animator = animator_value;
        const scaled_delta = delta_seconds * next_animator.speed;
        next_animator.time_seconds += scaled_delta;
        const sampled_time = resolvePlaybackTime(&next_animator, clip.duration);
        applyClip(world, targets, clip, sampled_time);
        world.entities.items[entity_index].animator = next_animator;
    }
}

fn resolvePlaybackTime(animator: *components.Animator, duration: f32) f32 {
    if (duration <= 0.0001) {
        animator.time_seconds = 0.0;
        animator.playing = false;
        return 0.0;
    }

    if (animator.looping) {
        animator.time_seconds = wrapTime(animator.time_seconds, duration);
        return animator.time_seconds;
    }

    if (animator.time_seconds <= 0.0) {
        animator.time_seconds = 0.0;
        if (animator.speed < 0.0) {
            animator.playing = false;
        }
        return 0.0;
    }
    if (animator.time_seconds >= duration) {
        animator.time_seconds = duration;
        if (animator.speed >= 0.0) {
            animator.playing = false;
        }
        return duration;
    }
    return animator.time_seconds;
}

fn wrapTime(time_seconds: f32, duration: f32) f32 {
    var wrapped = @mod(time_seconds, duration);
    if (wrapped < 0.0) {
        wrapped += duration;
    }
    return wrapped;
}

fn applyClip(
    world: *world_mod.World,
    targets: []const world_mod.EntityId,
    clip: *const animation_clip_mod.AnimationClipResource,
    sample_time: f32,
) void {
    for (clip.translation_tracks) |track| {
        if (track.target_entity_index >= targets.len) {
            continue;
        }
        const entity = world.getEntity(targets[track.target_entity_index]) orelse continue;
        const sampled = sampleVec3Track(track.interpolation, track.times, track.values, sample_time);
        if (!std.meta.eql(entity.local_transform.translation, sampled)) {
            entity.local_transform.translation = sampled;
            world.markDirty(entity.id);
        }
    }

    for (clip.rotation_tracks) |track| {
        if (track.target_entity_index >= targets.len) {
            continue;
        }
        const entity = world.getEntity(targets[track.target_entity_index]) orelse continue;
        const sampled = sampleQuatTrack(track.interpolation, track.times, track.values, sample_time);
        if (!std.meta.eql(entity.local_transform.rotation, sampled)) {
            entity.local_transform.rotation = sampled;
            world.markDirty(entity.id);
        }
    }

    for (clip.scale_tracks) |track| {
        if (track.target_entity_index >= targets.len) {
            continue;
        }
        const entity = world.getEntity(targets[track.target_entity_index]) orelse continue;
        const sampled = sampleVec3Track(track.interpolation, track.times, track.values, sample_time);
        if (!std.meta.eql(entity.local_transform.scale, sampled)) {
            entity.local_transform.scale = sampled;
            world.markDirty(entity.id);
        }
    }
}

fn sampleVec3Track(
    interpolation: animation_clip_mod.Interpolation,
    times: []const f32,
    values: []const [3]f32,
    sample_time: f32,
) [3]f32 {
    if (times.len == 0 or values.len == 0) {
        return .{ 0.0, 0.0, 0.0 };
    }
    if (times.len == 1 or sample_time <= times[0]) {
        return values[0];
    }

    const last_index = times.len - 1;
    if (sample_time >= times[last_index]) {
        return values[last_index];
    }

    const segment = findTrackSegment(times, sample_time);
    const start_time = times[segment];
    const end_time = times[segment + 1];
    const t = if (@abs(end_time - start_time) <= 0.00001) 0.0 else (sample_time - start_time) / (end_time - start_time);

    return switch (interpolation) {
        .step => values[segment],
        .linear, .cubic_spline => lerpVec3(values[segment], values[segment + 1], t),
    };
}

fn sampleQuatTrack(
    interpolation: animation_clip_mod.Interpolation,
    times: []const f32,
    values: []const [4]f32,
    sample_time: f32,
) [4]f32 {
    if (times.len == 0 or values.len == 0) {
        return quat.identity();
    }
    if (times.len == 1 or sample_time <= times[0]) {
        return quat.normalize(values[0]);
    }

    const last_index = times.len - 1;
    if (sample_time >= times[last_index]) {
        return quat.normalize(values[last_index]);
    }

    const segment = findTrackSegment(times, sample_time);
    const start_time = times[segment];
    const end_time = times[segment + 1];
    const t = if (@abs(end_time - start_time) <= 0.00001) 0.0 else (sample_time - start_time) / (end_time - start_time);

    return switch (interpolation) {
        .step => quat.normalize(values[segment]),
        .linear, .cubic_spline => slerpQuat(values[segment], values[segment + 1], t),
    };
}

fn findTrackSegment(times: []const f32, sample_time: f32) usize {
    var index: usize = 0;
    while (index + 1 < times.len) : (index += 1) {
        if (sample_time < times[index + 1]) {
            return index;
        }
    }
    return times.len - 2;
}

fn lerpVec3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        std.math.lerp(a[0], b[0], t),
        std.math.lerp(a[1], b[1], t),
        std.math.lerp(a[2], b[2], t),
    };
}

fn slerpQuat(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var qa = quat.normalize(a);
    var qb = quat.normalize(b);
    var dot_value = qa[0] * qb[0] + qa[1] * qb[1] + qa[2] * qb[2] + qa[3] * qb[3];

    if (dot_value < 0.0) {
        qb = .{ -qb[0], -qb[1], -qb[2], -qb[3] };
        dot_value = -dot_value;
    }

    if (dot_value > 0.9995) {
        qa = .{
            std.math.lerp(qa[0], qb[0], t),
            std.math.lerp(qa[1], qb[1], t),
            std.math.lerp(qa[2], qb[2], t),
            std.math.lerp(qa[3], qb[3], t),
        };
        return quat.normalize(qa);
    }

    const theta_0 = std.math.acos(std.math.clamp(dot_value, -1.0, 1.0));
    const theta = theta_0 * t;
    const sin_theta = std.math.sin(theta);
    const sin_theta_0 = std.math.sin(theta_0);

    const s0 = std.math.cos(theta) - dot_value * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;
    return .{
        qa[0] * s0 + qb[0] * s1,
        qa[1] * s0 + qb[1] * s1,
        qa[2] * s0 + qb[2] * s1,
        qa[3] * s0 + qb[3] * s1,
    };
}

test "animator system samples translation and looping time" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{
        .name = "Bone",
    });
    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = undefined,
        },
    });

    const clip_handle = try world.resources.createAnimationClip(.{
        .name = "Move",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 2.0, 0.0, 0.0 } },
            },
        },
    });
    world.getEntity(animator_id).?.animator.?.default_clip_handle = clip_handle;
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    update(&world, 0.5);
    const target = world.getEntityConst(target_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), target.local_transform.translation[0], 0.0001);

    update(&world, 0.75);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    try std.testing.expect(animator.time_seconds < 1.0);
}

test "animator system stops non-looping clips at the end" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{ .name = "Target" });
    const clip_handle = try world.resources.createAnimationClip(.{
        .name = "Rotate",
        .duration = 0.5,
        .rotation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 0.5 },
                .values = &.{ .{ 0.0, 0.0, 0.0, 1.0 }, .{ 0.0, 0.70710677, 0.0, 0.70710677 } },
            },
        },
    });
    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = clip_handle,
            .looping = false,
        },
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    update(&world, 1.0);
    const animator = world.getEntityConst(animator_id).?.animator.?;
    const target = world.getEntityConst(target_id).?;
    try std.testing.expect(!animator.playing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.70710677), target.local_transform.rotation[1], 0.0001);
}
