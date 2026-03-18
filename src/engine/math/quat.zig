const std = @import("std");
const components = @import("../scene/components.zig");
const vec3 = @import("vec3.zig");

pub const Quat = [4]f32; // x, y, z, w

pub fn identity() Quat {
    return .{ 0.0, 0.0, 0.0, 1.0 };
}

// Create a quaternion from axis-angle representation
pub fn fromAxisAngle(axis: components.Vec3, angle: f32) Quat {
    const half_angle = angle * 0.5;
    const s = std.math.sin(half_angle);
    const c = std.math.cos(half_angle);
    const normalized_axis = vec3.normalize(axis);
    return .{
        normalized_axis[0] * s,
        normalized_axis[1] * s,
        normalized_axis[2] * s,
        c,
    };
}

pub fn mul(a: Quat, b: Quat) Quat {
    return .{
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] + a[1] * b[3] + a[2] * b[0] - a[0] * b[2],
        a[3] * b[2] + a[2] * b[3] + a[0] * b[1] - a[1] * b[0],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    };
}

pub fn normalize(q: Quat) Quat {
    const len = std.math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (len <= 0.00001) {
        return identity();
    }
    return .{ q[0] / len, q[1] / len, q[2] / len, q[3] / len };
}

pub fn inverse(q: Quat) Quat {
    return .{ -q[0], -q[1], -q[2], q[3] };
}

// Convert Euler angles (x: pitch, y: yaw, z: roll) to Quaternion
pub fn fromEuler(euler: components.Vec3) Quat {
    const cx = std.math.cos(euler[0] * 0.5);
    const sx = std.math.sin(euler[0] * 0.5);
    const cy = std.math.cos(euler[1] * 0.5);
    const sy = std.math.sin(euler[1] * 0.5);
    const cz = std.math.cos(euler[2] * 0.5);
    const sz = std.math.sin(euler[2] * 0.5);

    return .{
        sx * cy * cz - cx * sy * sz,
        cx * sy * cz + sx * cy * sz,
        cx * cy * sz - sx * sy * cz,
        cx * cy * cz + sx * sy * sz,
    };
}

// Convert Quaternion to Euler angles (x: pitch, y: yaw, z: roll)
pub fn toEuler(q: Quat) components.Vec3 {
    var euler: components.Vec3 = .{ 0, 0, 0 };

    // x-axis rotation (pitch)
    const sinr_cosp = 2.0 * (q[3] * q[0] + q[1] * q[2]);
    const cosr_cosp = 1.0 - 2.0 * (q[0] * q[0] + q[1] * q[1]);
    euler[0] = std.math.atan2(sinr_cosp, cosr_cosp);

    // y-axis rotation (yaw)
    const sinp = 2.0 * (q[3] * q[1] - q[2] * q[0]);
    if (@abs(sinp) >= 1.0) {
        euler[1] = std.math.copysign(@as(f32, std.math.pi / 2.0), sinp); // use 90 degrees if out of range
    } else {
        euler[1] = std.math.asin(sinp);
    }

    // z-axis rotation (roll)
    const siny_cosp = 2.0 * (q[3] * q[2] + q[0] * q[1]);
    const cosy_cosp = 1.0 - 2.0 * (q[1] * q[1] + q[2] * q[2]);
    euler[2] = std.math.atan2(siny_cosp, cosy_cosp);

    return euler;
}

pub fn fromRotationMatrix(m: [16]f32) Quat {
    const trace = m[0] + m[5] + m[10];
    if (trace > 0.0) {
        const s = 0.5 / std.math.sqrt(trace + 1.0);
        return .{
            (m[6] - m[9]) * s,
            (m[8] - m[2]) * s,
            (m[1] - m[4]) * s,
            0.25 / s,
        };
    } else {
        if (m[0] > m[5] and m[0] > m[10]) {
            const s = 2.0 * std.math.sqrt(1.0 + m[0] - m[5] - m[10]);
            return .{
                0.25 * s,
                (m[1] + m[4]) / s,
                (m[2] + m[8]) / s,
                (m[6] - m[9]) / s,
            };
        } else if (m[5] > m[10]) {
            const s = 2.0 * std.math.sqrt(1.0 + m[5] - m[0] - m[10]);
            return .{
                (m[1] + m[4]) / s,
                0.25 * s,
                (m[6] + m[9]) / s,
                (m[8] - m[2]) / s,
            };
        } else {
            const s = 2.0 * std.math.sqrt(1.0 + m[10] - m[0] - m[5]);
            return .{
                (m[2] + m[8]) / s,
                (m[6] + m[9]) / s,
                0.25 * s,
                (m[1] - m[4]) / s,
            };
        }
    }
}

pub fn rotateVec3(q: Quat, v: components.Vec3) components.Vec3 {
    const q_vec: components.Vec3 = .{ q[0], q[1], q[2] };
    const t = vec3.scale(vec3.cross(q_vec, v), 2.0);
    return vec3.add(v, vec3.add(vec3.scale(t, q[3]), vec3.cross(q_vec, t)));
}

pub fn toMat4(q: Quat) [16]f32 {
    var result: [16]f32 = [_]f32{0} ** 16;
    const x2 = q[0] + q[0];
    const y2 = q[1] + q[1];
    const z2 = q[2] + q[2];
    const xx = q[0] * x2;
    const xy = q[0] * y2;
    const xz = q[0] * z2;
    const yy = q[1] * y2;
    const yz = q[1] * z2;
    const zz = q[2] * z2;
    const wx = q[3] * x2;
    const wy = q[3] * y2;
    const wz = q[3] * z2;

    result[0] = 1.0 - (yy + zz);
    result[1] = xy + wz;
    result[2] = xz - wy;
    result[3] = 0.0;

    result[4] = xy - wz;
    result[5] = 1.0 - (xx + zz);
    result[6] = yz + wx;
    result[7] = 0.0;

    result[8] = xz + wy;
    result[9] = yz - wx;
    result[10] = 1.0 - (xx + yy);
    result[11] = 0.0;

    result[12] = 0.0;
    result[13] = 0.0;
    result[14] = 0.0;
    result[15] = 1.0;

    return result;
}
