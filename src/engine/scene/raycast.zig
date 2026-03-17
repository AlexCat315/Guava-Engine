const std = @import("std");
const components = @import("components.zig");
const world_mod = @import("world.zig");

pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
};

pub const SurfaceRaycastHit = struct {
    entity_id: world_mod.EntityId,
    distance: f32,
    position: [3]f32,
    normal: [3]f32,
};

pub fn raycastSurface(world: *const world_mod.World, ray: Ray) ?SurfaceRaycastHit {
    const normalized_direction = normalize(ray.direction);
    var best_hit: ?SurfaceRaycastHit = null;

    for (world.entities.items) |entity| {
        if (!entity.visible or entity.editor_only) {
            continue;
        }
        const mesh_component = entity.mesh orelse continue;
        const mesh_handle = mesh_component.handle orelse continue;
        const mesh = world.resources.mesh(mesh_handle) orelse continue;
        if (mesh.primitive_type != .triangle_list or mesh.indices.len < 3) {
            continue;
        }

        const world_transform = world.worldTransform(entity.id) orelse entity.transform;
        var triangle_index: usize = 0;
        while (triangle_index + 2 < mesh.indices.len) : (triangle_index += 3) {
            const v0 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index]].position);
            const v1 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index + 1]].position);
            const v2 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index + 2]].position);
            const hit = rayTriangleIntersection(ray.origin, normalized_direction, v0, v1, v2) orelse continue;

            if (best_hit == null or hit.distance < best_hit.?.distance) {
                best_hit = .{
                    .entity_id = entity.id,
                    .distance = hit.distance,
                    .position = hit.position,
                    .normal = faceCamera(normalize(cross(sub(v1, v0), sub(v2, v0))), normalized_direction),
                };
            }
        }
    }

    return best_hit;
}

const TriangleHit = struct {
    distance: f32,
    position: [3]f32,
};

fn rayTriangleIntersection(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?TriangleHit {
    const epsilon: f32 = 0.00001;
    const edge1 = sub(v1, v0);
    const edge2 = sub(v2, v0);
    const pvec = cross(ray_direction, edge2);
    const determinant = dot(edge1, pvec);

    if (@abs(determinant) <= epsilon) {
        return null;
    }

    const inverse_determinant = 1.0 / determinant;
    const tvec = sub(ray_origin, v0);
    const u = dot(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) {
        return null;
    }

    const qvec = cross(tvec, edge1);
    const v = dot(ray_direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) {
        return null;
    }

    const distance = dot(edge2, qvec) * inverse_determinant;
    if (distance <= epsilon) {
        return null;
    }

    return .{
        .distance = distance,
        .position = add(ray_origin, scale(ray_direction, distance)),
    };
}

fn transformPoint(transform: components.Transform, point: [3]f32) [3]f32 {
    return add(
        transform.translation,
        rotateVec3Euler(transform.rotation_euler, mul(transform.scale, point)),
    );
}

fn rotateVec3Euler(rotation: [3]f32, vector: [3]f32) [3]f32 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn rotateX(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

fn faceCamera(normal: [3]f32, ray_direction: [3]f32) [3]f32 {
    if (dot(normal, ray_direction) > 0.0) {
        return scale(normal, -1.0);
    }
    return normal;
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mul(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

fn scale(vector: [3]f32, scalar: f32) [3]f32 {
    return .{ vector[0] * scalar, vector[1] * scalar, vector[2] * scalar };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn length(vector: [3]f32) f32 {
    return std.math.sqrt(dot(vector, vector));
}

fn normalize(vector: [3]f32) [3]f32 {
    const len = length(vector);
    if (len <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return scale(vector, 1.0 / len);
}

test "raycastSurface hits the nearest visible triangle" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();

    const front = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, 0.0 },
        .rotation_euler = .{ -std.math.pi * 0.5, 0.0, 0.0 },
    });
    _ = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, -3.0 },
        .rotation_euler = .{ -std.math.pi * 0.5, 0.0, 0.0 },
    });

    const hit = raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }).?;

    try std.testing.expectEqual(front, hit.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hit.position[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit.distance, 0.0001);
}

test "raycastSurface ignores editor only meshes" {
    var world = world_mod.World.init(std.testing.allocator);
    defer world.deinit();

    const mesh_handle = try world.resources.ensurePrimitiveMesh(.plane);
    const material_handle = try world.resources.ensureDefaultMaterial();
    _ = try world.createEntity(.{
        .name = "HiddenPreview",
        .editor_only = true,
        .mesh = .{
            .handle = mesh_handle,
            .primitive = .plane,
        },
        .material = .{
            .handle = material_handle,
        },
        .transform = .{
            .rotation_euler = .{ -std.math.pi * 0.5, 0.0, 0.0 },
        },
    });

    try std.testing.expect(raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }) == null);
}
