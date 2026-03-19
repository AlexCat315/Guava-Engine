const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");

pub const ItemId = u64;

pub const BoundsItem = struct {
    id: ItemId,
    bounds: AABB,
};

const Node = struct {
    bounds: AABB,
    left: ?u32,
    right: ?u32,
    parent: ?u32,
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
    item_indices: std.AutoHashMap(ItemId, usize),
    item_leaf_nodes: std.AutoHashMap(ItemId, u32),
    pending_additions: std.ArrayList(BoundsItem) = .empty,
    pending_addition_indices: std.AutoHashMap(ItemId, usize),
    pending_removals: std.AutoHashMap(ItemId, void),
    dirty: bool = true,

    const max_leaf_items: usize = 4;
    const max_incremental_overlay_items: usize = 24;

    pub fn init(allocator: std.mem.Allocator) StaticBoundsBvh {
        return .{
            .allocator = allocator,
            .item_indices = std.AutoHashMap(ItemId, usize).init(allocator),
            .item_leaf_nodes = std.AutoHashMap(ItemId, u32).init(allocator),
            .pending_addition_indices = std.AutoHashMap(ItemId, usize).init(allocator),
            .pending_removals = std.AutoHashMap(ItemId, void).init(allocator),
        };
    }

    pub fn deinit(self: *StaticBoundsBvh) void {
        self.items.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.item_indices.deinit();
        self.item_leaf_nodes.deinit();
        self.pending_additions.deinit(self.allocator);
        self.pending_addition_indices.deinit();
        self.pending_removals.deinit();
        self.* = undefined;
    }

    pub fn markDirty(self: *StaticBoundsBvh) void {
        self.dirty = true;
    }

    pub fn itemCount(self: *const StaticBoundsBvh) usize {
        return (self.items.items.len -| self.pending_removals.count()) + self.pending_additions.items.len;
    }

    pub fn nodeCount(self: *const StaticBoundsBvh) usize {
        return self.nodes.items.len;
    }

    pub fn rebuild(self: *StaticBoundsBvh, source_items: []const BoundsItem) !void {
        self.items.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.item_indices.clearRetainingCapacity();
        self.item_leaf_nodes.clearRetainingCapacity();
        self.pending_additions.clearRetainingCapacity();
        self.pending_addition_indices.clearRetainingCapacity();
        self.pending_removals.clearRetainingCapacity();

        if (source_items.len == 0) {
            self.dirty = false;
            return;
        }

        try self.items.appendSlice(self.allocator, source_items);
        _ = try self.buildNode(0, self.items.items.len, null);
        self.dirty = false;
    }

    pub fn updateItemBounds(self: *StaticBoundsBvh, id: ItemId, bounds: AABB) bool {
        if (self.pending_addition_indices.get(id)) |item_index| {
            self.pending_additions.items[item_index].bounds = bounds;
            return true;
        }
        if (self.pending_removals.contains(id)) {
            return false;
        }
        const item_index = self.item_indices.get(id) orelse return false;
        const leaf_node_index = self.item_leaf_nodes.get(id) orelse return false;
        self.items.items[item_index].bounds = bounds;
        self.refitFromNode(leaf_node_index);
        self.dirty = false;
        return true;
    }

    pub fn insertItem(self: *StaticBoundsBvh, item: BoundsItem) bool {
        if (self.dirty) {
            return false;
        }

        if (self.pending_addition_indices.get(item.id)) |item_index| {
            self.pending_additions.items[item_index] = item;
            return true;
        }

        if (self.pending_removals.remove(item.id)) {
            return self.updateItemBounds(item.id, item.bounds);
        }

        if (self.item_indices.contains(item.id)) {
            return self.updateItemBounds(item.id, item.bounds);
        }

        const next_index = self.pending_additions.items.len;
        self.pending_additions.append(self.allocator, item) catch return false;
        self.pending_addition_indices.put(item.id, next_index) catch {
            _ = self.pending_additions.pop();
            return false;
        };
        self.markDirtyIfOverlayTooLarge();
        return true;
    }

    pub fn removeItem(self: *StaticBoundsBvh, id: ItemId) bool {
        if (self.dirty) {
            return false;
        }

        if (self.pending_addition_indices.get(id)) |item_index| {
            self.removePendingAdditionAt(item_index);
            return true;
        }

        if (!self.item_indices.contains(id) or self.pending_removals.contains(id)) {
            return false;
        }

        self.pending_removals.put(id, {}) catch return false;
        self.markDirtyIfOverlayTooLarge();
        return true;
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

        if (self.nodes.items.len > 0) {
            try self.collectRayCandidatesRecursive(allocator, 0, ray_origin, ray_direction, max_distance, &candidates);
        }
        try self.collectPendingRayCandidates(allocator, ray_origin, ray_direction, max_distance, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryFrustumCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]ItemId {
        var candidates = std.ArrayList(ItemId).empty;
        errdefer candidates.deinit(allocator);

        if (self.nodes.items.len > 0) {
            try self.collectFrustumCandidatesRecursive(allocator, 0, frustum, &candidates);
        }
        try self.collectPendingFrustumCandidates(allocator, frustum, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    fn buildNode(self: *StaticBoundsBvh, start: usize, end: usize, parent: ?u32) !u32 {
        var node_bounds = AABB.empty();
        for (self.items.items[start..end]) |item| {
            node_bounds.expandAABB(item.bounds);
        }

        const node_index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .bounds = node_bounds,
            .left = null,
            .right = null,
            .parent = parent,
            .start = @intCast(start),
            .count = @intCast(end - start),
        });

        const item_count = end - start;
        if (item_count <= max_leaf_items) {
            for (self.items.items[start..end], start..) |item, item_index| {
                self.item_indices.put(item.id, item_index) catch return error.OutOfMemory;
                self.item_leaf_nodes.put(item.id, node_index) catch return error.OutOfMemory;
            }
            return node_index;
        }

        const axis = longestAxis(node_bounds);
        std.sort.heap(BoundsItem, self.items.items[start..end], axis, lessThanCentroid);
        const mid = start + item_count / 2;

        const left_index = try self.buildNode(start, mid, node_index);
        const right_index = try self.buildNode(mid, end, node_index);
        self.nodes.items[node_index] = .{
            .bounds = node_bounds,
            .left = left_index,
            .right = right_index,
            .parent = parent,
            .start = @intCast(start),
            .count = 0,
        };
        return node_index;
    }

    fn refitFromNode(self: *StaticBoundsBvh, start_node_index: u32) void {
        var current: ?u32 = start_node_index;
        while (current) |node_index| {
            self.refitSingleNode(node_index);
            current = self.nodes.items[node_index].parent;
        }
    }

    fn refitSingleNode(self: *StaticBoundsBvh, node_index: u32) void {
        const node = self.nodes.items[node_index];
        var bounds = AABB.empty();
        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                bounds.expandAABB(item.bounds);
            }
        } else {
            bounds.expandAABB(self.nodes.items[node.left.?].bounds);
            bounds.expandAABB(self.nodes.items[node.right.?].bounds);
        }
        self.nodes.items[node_index].bounds = bounds;
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
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
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

    fn collectFrustumCandidatesRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        frustum: frustum_mod.Frustum,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (!frustum.intersectsAABB(node.bounds)) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
                if (frustum.intersectsAABB(item.bounds)) {
                    try candidates.append(allocator, item.id);
                }
            }
            return;
        }

        try self.collectFrustumCandidatesRecursive(allocator, node.left.?, frustum, candidates);
        try self.collectFrustumCandidatesRecursive(allocator, node.right.?, frustum, candidates);
    }

    fn collectPendingRayCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        for (self.pending_additions.items) |item| {
            if (item.bounds.rayIntersection(ray_origin, ray_direction, max_distance) != null) {
                try candidates.append(allocator, item.id);
            }
        }
    }

    fn collectPendingFrustumCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        for (self.pending_additions.items) |item| {
            if (frustum.intersectsAABB(item.bounds)) {
                try candidates.append(allocator, item.id);
            }
        }
    }

    fn removePendingAdditionAt(self: *StaticBoundsBvh, item_index: usize) void {
        const removed_id = self.pending_additions.items[item_index].id;
        const moved_item = self.pending_additions.items[self.pending_additions.items.len - 1];
        _ = self.pending_additions.swapRemove(item_index);
        _ = self.pending_addition_indices.remove(removed_id);
        if (item_index < self.pending_additions.items.len) {
            self.pending_addition_indices.put(moved_item.id, item_index) catch {};
        }
    }

    fn markDirtyIfOverlayTooLarge(self: *StaticBoundsBvh) void {
        const overlay_items = self.pending_additions.items.len + self.pending_removals.count();
        if (overlay_items >= max_incremental_overlay_items or
            overlay_items * 2 > self.items.items.len + self.pending_additions.items.len)
        {
            self.dirty = true;
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

test "StaticBoundsBvh can refit a moved item in place" {
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
    });

    try std.testing.expect(bvh.updateItemBounds(2, .{
        .min = .{ 10.0, -1.0, -1.0 },
        .max = .{ 12.0, 1.0, 1.0 },
    }));

    const old_ray_candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        9.0,
    );
    defer std.testing.allocator.free(old_ray_candidates);
    try std.testing.expectEqual(@as(usize, 1), old_ray_candidates.len);
    try std.testing.expectEqual(@as(ItemId, 1), old_ray_candidates[0]);

    const moved_ray_candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ 8.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        8.0,
    );
    defer std.testing.allocator.free(moved_ray_candidates);
    try std.testing.expectEqual(@as(usize, 1), moved_ray_candidates.len);
    try std.testing.expectEqual(@as(ItemId, 2), moved_ray_candidates[0]);
}

test "StaticBoundsBvh supports incremental insert and remove overlays" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        },
    });
    const initial_node_count = bvh.nodeCount();

    try std.testing.expect(bvh.insertItem(.{
        .id = 2,
        .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
    }));
    try std.testing.expectEqual(initial_node_count, bvh.nodeCount());

    const with_insert = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(with_insert);
    try std.testing.expectEqual(@as(usize, 2), with_insert.len);

    try std.testing.expect(bvh.removeItem(1));
    try std.testing.expectEqual(initial_node_count, bvh.nodeCount());

    const after_remove = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_remove);
    try std.testing.expectEqual(@as(usize, 1), after_remove.len);
    try std.testing.expectEqual(@as(ItemId, 2), after_remove[0]);
}
