const std = @import("std");
const vec3 = @import("vec3.zig");
const quat = @import("quat.zig");
const components = @import("../scene/components.zig");

pub const AABB = struct {
    min: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
    max: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },

    pub fn empty() AABB {
        return .{};
    }

    pub fn expand(self: *AABB, point: [3]f32) void {
        self.min[0] = @min(self.min[0], point[0]);
        self.min[1] = @min(self.min[1], point[1]);
        self.min[2] = @min(self.min[2], point[2]);

        self.max[0] = @max(self.max[0], point[0]);
        self.max[1] = @max(self.max[1], point[1]);
        self.max[2] = @max(self.max[2], point[2]);
    }

    pub fn expandAABB(self: *AABB, other: AABB) void {
        self.min[0] = @min(self.min[0], other.min[0]);
        self.min[1] = @min(self.min[1], other.min[1]);
        self.min[2] = @min(self.min[2], other.min[2]);

        self.max[0] = @max(self.max[0], other.max[0]);
        self.max[1] = @max(self.max[1], other.max[1]);
        self.max[2] = @max(self.max[2], other.max[2]);
    }

    pub fn isValid(self: AABB) bool {
        return self.min[0] <= self.max[0] and self.min[1] <= self.max[1] and self.min[2] <= self.max[2];
    }

    pub fn transformed(self: AABB, transform: components.Transform) AABB {
        if (!self.isValid()) return self;

        // Extract 8 corners
        const corners = [_][3]f32{
            .{ self.min[0], self.min[1], self.min[2] },
            .{ self.max[0], self.min[1], self.min[2] },
            .{ self.min[0], self.max[1], self.min[2] },
            .{ self.max[0], self.max[1], self.min[2] },
            .{ self.min[0], self.min[1], self.max[2] },
            .{ self.max[0], self.min[1], self.max[2] },
            .{ self.min[0], self.max[1], self.max[2] },
            .{ self.max[0], self.max[1], self.max[2] },
        };

        var result = AABB.empty();
        for (corners) |corner| {
            const scaled = vec3.mul(corner, transform.scale);
            const rotated = quat.rotateVec3(transform.rotation, scaled);
            const translated = vec3.add(rotated, transform.translation);
            result.expand(translated);
        }

        return result;
    }
};
