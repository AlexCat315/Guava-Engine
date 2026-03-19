const std = @import("std");
const rhi_types = @import("../rhi/types.zig");
const AABB = @import("../math/aabb.zig").AABB;

pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    tangent: [4]f32,
    color: [4]f32,
    uv: [2]f32,
    joints: [4]u16 = .{ 0, 0, 0, 0 },
    weights: [4]f32 = .{ 1.0, 0.0, 0.0, 0.0 },
};

pub const MeshResource = struct {
    name: []u8,
    vertices: []Vertex,
    indices: []u32,
    primitive_type: rhi_types.PrimitiveType = .triangle_list,
    local_bounds: AABB = .{},

    pub fn deinit(self: *MeshResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vertices);
        allocator.free(self.indices);
        self.* = undefined;
    }
};

pub const MeshResourceDesc = struct {
    name: []const u8,
    vertices: []const Vertex,
    indices: []const u32,
    primitive_type: rhi_types.PrimitiveType = .triangle_list,
};

pub fn clone(allocator: std.mem.Allocator, desc: MeshResourceDesc) !MeshResource {
    var local_bounds = AABB.empty();
    for (desc.vertices) |vertex| {
        local_bounds.expand(vertex.position);
    }

    return .{
        .name = try allocator.dupe(u8, desc.name),
        .vertices = try allocator.dupe(Vertex, desc.vertices),
        .indices = try allocator.dupe(u32, desc.indices),
        .primitive_type = desc.primitive_type,
        .local_bounds = local_bounds,
    };
}
