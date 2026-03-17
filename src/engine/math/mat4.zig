const std = @import("std");
const components = @import("../scene/components.zig");
const quat = @import("quat.zig");

pub const Mat4 = [16]f32;

pub fn identity() Mat4 {
    return .{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
}

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var result: Mat4 = [_]f32{0.0} ** 16;

    var col: usize = 0;
    while (col < 4) : (col += 1) {
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var value: f32 = 0.0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                value += get(a, row, i) * get(b, i, col);
            }
            set(&result, row, col, value);
        }
    }

    return result;
}

pub fn translation(offset: components.Vec3) Mat4 {
    var result = identity();
    set(&result, 0, 3, offset[0]);
    set(&result, 1, 3, offset[1]);
    set(&result, 2, 3, offset[2]);
    return result;
}

pub fn scale(factors: components.Vec3) Mat4 {
    var result = identity();
    set(&result, 0, 0, factors[0]);
    set(&result, 1, 1, factors[1]);
    set(&result, 2, 2, factors[2]);
    return result;
}

pub fn rotationX(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 1, 1, c);
    set(&result, 1, 2, -s);
    set(&result, 2, 1, s);
    set(&result, 2, 2, c);
    return result;
}

pub fn rotationY(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 0, 0, c);
    set(&result, 0, 2, s);
    set(&result, 2, 0, -s);
    set(&result, 2, 2, c);
    return result;
}

pub fn rotationZ(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 0, 0, c);
    set(&result, 0, 1, -s);
    set(&result, 1, 0, s);
    set(&result, 1, 1, c);
    return result;
}

pub fn transformMatrix(transform: components.Transform) Mat4 {
    const rotate = quat.toMat4(transform.rotation);
    return mul(mul(translation(transform.translation), rotate), scale(transform.scale));
}

pub fn viewMatrix(transform: components.Transform) Mat4 {
    const inverse_translate = translation(.{
        -transform.translation[0],
        -transform.translation[1],
        -transform.translation[2],
    });
    const inverse_rotate = quat.toMat4(quat.inverse(transform.rotation));
    return mul(inverse_rotate, inverse_translate);
}

pub fn perspective(fov_y_radians: f32, aspect_ratio: f32, near_clip: f32, far_clip: f32) Mat4 {
    const f = 1.0 / std.math.tan(fov_y_radians * 0.5);
    var result: Mat4 = [_]f32{0.0} ** 16;
    set(&result, 0, 0, f / aspect_ratio);
    set(&result, 1, 1, f);
    set(&result, 2, 2, far_clip / (near_clip - far_clip));
    set(&result, 2, 3, (far_clip * near_clip) / (near_clip - far_clip));
    set(&result, 3, 2, -1.0);
    return result;
}

pub fn orthographic(size: f32, aspect_ratio: f32, near_clip: f32, far_clip: f32) Mat4 {
    const half_height = size * 0.5;
    const half_width = half_height * aspect_ratio;
    var result = identity();
    set(&result, 0, 0, 1.0 / half_width);
    set(&result, 1, 1, 1.0 / half_height);
    set(&result, 2, 2, 1.0 / (near_clip - far_clip));
    set(&result, 3, 2, near_clip / (near_clip - far_clip));
    return result;
}

pub fn projectionForCamera(camera: components.Camera, aspect_ratio: f32) Mat4 {
    return switch (camera.projection) {
        .perspective => |proj| perspective(
            proj.fov_y_radians,
            aspect_ratio,
            proj.near_clip,
            proj.far_clip,
        ),
        .orthographic => |proj| orthographic(
            proj.size,
            aspect_ratio,
            proj.near_clip,
            proj.far_clip,
        ),
    };
}

fn get(matrix: Mat4, row: usize, col: usize) f32 {
    return matrix[col * 4 + row];
}

fn set(matrix: *Mat4, row: usize, col: usize, value: f32) void {
    matrix[col * 4 + row] = value;
}

test "transform matrix keeps translation in the last column" {
    const matrix = transformMatrix(.{
        .translation = .{ 2.0, 3.0, 4.0 },
    });

    try std.testing.expectEqual(@as(f32, 2.0), matrix[12]);
    try std.testing.expectEqual(@as(f32, 3.0), matrix[13]);
    try std.testing.expectEqual(@as(f32, 4.0), matrix[14]);
}

test "perspective matrix keeps clip w positive for points in front of the camera" {
    const matrix = perspective(1.0471976, 1.0, 0.1, 1000.0);
    const view_space_point = [_]f32{ 0.0, 0.0, -5.0, 1.0 };
    const clip_w =
        matrix[3] * view_space_point[0] +
        matrix[7] * view_space_point[1] +
        matrix[11] * view_space_point[2] +
        matrix[15] * view_space_point[3];

    try std.testing.expect(clip_w > 0.0);
}
