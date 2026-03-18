const std = @import("std");
const engine = @import("guava");

pub const EntitySnapshot = struct {
    id: engine.scene.EntityId,
    name: []u8,
    parent: ?engine.scene.EntityId = null,
    local_transform: engine.scene.Transform = .{},
    camera: ?engine.scene.Camera = null,
    mesh: ?engine.scene.Mesh = null,
    material: ?engine.scene.Material = null,
    light: ?engine.scene.Light = null,
    vfx: ?engine.scene.Vfx = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    children: std.ArrayList(EntitySnapshot) = .empty,

    pub fn deinit(self: *EntitySnapshot, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const SelectionSnapshot = struct {
    entity_ids: std.ArrayList(engine.scene.EntityId) = .empty,

    pub fn fromSlice(allocator: std.mem.Allocator, entity_ids: []const engine.scene.EntityId) !SelectionSnapshot {
        var snapshot: SelectionSnapshot = .{};
        errdefer snapshot.deinit(allocator);
        try snapshot.entity_ids.ensureTotalCapacity(allocator, entity_ids.len);
        snapshot.entity_ids.appendSliceAssumeCapacity(entity_ids);
        return snapshot;
    }

    pub fn clone(self: *const SelectionSnapshot, allocator: std.mem.Allocator) !SelectionSnapshot {
        return fromSlice(allocator, self.entity_ids.items);
    }

    pub fn deinit(self: *SelectionSnapshot, allocator: std.mem.Allocator) void {
        self.entity_ids.deinit(allocator);
        self.* = .{};
    }
};

pub const SceneSnapshotCommand = struct {
    before: []u8,
    after: []u8,
    selection_before: SelectionSnapshot = .{},
    selection_after: SelectionSnapshot = .{},

    pub fn deinit(self: *SceneSnapshotCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.before);
        allocator.free(self.after);
        self.selection_before.deinit(allocator);
        self.selection_after.deinit(allocator);
        self.* = undefined;
    }
};

pub const SubtreeDelta = struct {
    before: ?EntitySnapshot = null,
    after: ?EntitySnapshot = null,

    pub fn deinit(self: *SubtreeDelta, allocator: std.mem.Allocator) void {
        if (self.before) |*snapshot| {
            snapshot.deinit(allocator);
        }
        if (self.after) |*snapshot| {
            snapshot.deinit(allocator);
        }
        self.* = undefined;
    }
};

pub const SubtreeDeltaCommand = struct {
    deltas: std.ArrayList(SubtreeDelta) = .empty,
    selection_before: SelectionSnapshot = .{},
    selection_after: SelectionSnapshot = .{},

    pub fn deinit(self: *SubtreeDeltaCommand, allocator: std.mem.Allocator) void {
        for (self.deltas.items) |*delta| {
            delta.deinit(allocator);
        }
        self.deltas.deinit(allocator);
        self.selection_before.deinit(allocator);
        self.selection_after.deinit(allocator);
        self.* = undefined;
    }
};

pub const EditorCommand = union(enum) {
    scene_snapshot: SceneSnapshotCommand,
    subtree_delta: SubtreeDeltaCommand,

    pub fn deinit(self: *EditorCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scene_snapshot => |*command| command.deinit(allocator),
            .subtree_delta => |*command| command.deinit(allocator),
        }
    }
};
