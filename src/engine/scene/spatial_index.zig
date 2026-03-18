const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;

pub const ItemId = u64;

pub const BoundsItem = struct {
    id: ItemId,
    bounds: AABB,
};

const Node = struct {
    bounds: AABB,
    left: ?u32,
    right: ?u32,
    start: u32,
    count: u32,

    fn isLeaf(self: Node) bool {
        return self.left == null and self.right == null;
    }
};

pub const StaticBoundsBvh = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(BoundsItem) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    dirty: bool = true,

    const max_leaf_items: usize = 4;

    pub fn init(allocator: std.mem.Allocator) StaticBoundsBvh {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StaticBoundsBvh) void {
        self.items.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn markDirty(self: *StaticBoundsBvh) void {
        self.dirty = true;
    }

    pub fn itemCount(self: *const StaticBoundsBvh) usize {
        return self.items.items.len;
    }

    pub fn nodeCount(self: *const StaticBoundsBvh) usize {
        return self.nodes.items.len;
    }

    pub fn rebuild(self: *StaticBoundsBvh, source_items: []const BoundsItem) !void {
        self.items.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();

        if (source_items.len == 0) {
            self.dirty = false;
            return;
        }

        try self.items.appendSlice(self.allocator, source_items);
        _ = try self.buildNode(0, self.items.items.len);
        self.dirty = false;
    }

    pub fn queryRayCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]ItemId {
        var candidates = std.ArrayList(ItemId).empty;
        errdefer candidates.deinit(allocator);

        if (self.nodes.items.len == 0) {
            return try candidates.toOwnedSlice(allocator);
        }

        try self.collectRayCandidatesRecursive(allocator, 0, ray_origin, ray_direction, max_distance, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    fn buildNode(self: *StaticBoundsBvh, start: usize, end: usize) !u32 {
        var node_bounds = AABB.empty();
        for (self.items.items[start..end]) |item| {
            node_bounds.expandAABB(item.bounds);
        }

        const node_index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .bounds = node_bounds,
            .left = null,
            .right = null,
            .start = @intCast(start),
            .count = @intCast(end - start),
        });

        const item_count = end - start;
        if (item_count <= max_leaf_items) {
            return node_index;
        }

        const axis = longestAxis(node_bounds);
        std.sort.heap(BoundsItem, self.items.items[start..end], axis, lessThanCentroid);
        const mid = start + item_count / 2;

        const left_index = try self.buildNode(start, mid);
        const right_index = try self.buildNode(mid, end);
        self.nodes.items[node_index] = .{
            .bounds = node_bounds,
            .left = left_index,
            .right = right_index,
            .start = @intCast(start),
            .count = 0,
        };
        return node_index;
    }

    fn collectRayCandidatesRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (node.bounds.rayIntersection(ray_origin, ray_direction, max_distance) == null) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                try candidates.append(allocator, item.id);
            }
            return;
        }

        const left_index = node.left.?;
        const right_index = node.right.?;
        const left_hit = self.nodes.items[left_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);
        const right_hit = self.nodes.items[right_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);

        if (left_hit != null and right_hit != null) {
            if (left_hit.?.enter_distance <= right_hit.?.enter_distance) {
                try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
            } else {
                try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
            }
            return;
        }

        if (left_hit != null) {
            try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
        }
        if (right_hit != null) {
            try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
        }
    }
};

fn longestAxis(bounds: AABB) usize {
    const extent = bounds.extent();
    if (extent[1] > extent[0] and extent[1] >= extent[2]) {
        return 1;
    }
    if (extent[2] > extent[0] and extent[2] >= extent[1]) {
        return 2;
    }
    return 0;
}

fn lessThanCentroid(axis: usize, lhs: BoundsItem, rhs: BoundsItem) bool {
    return lhs.bounds.centroid()[axis] < rhs.bounds.centroid()[axis];
}

test "StaticBoundsBvh returns only ray-overlapping candidates" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        },
        .{
            .id = 2,
            .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
        },
        .{
            .id = 3,
            .bounds = .{ .min = .{ -1.0, 5.0, -1.0 }, .max = .{ 1.0, 7.0, 1.0 } },
        },
    });

    const candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(@as(ItemId, 1), candidates[0]);
    try std.testing.expectEqual(@as(ItemId, 2), candidates[1]);
}
