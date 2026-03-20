const std = @import("std");
const command_mod = @import("command.zig");
const scene_mod = @import("../scene/scene.zig");
const components_mod = @import("../scene/components.zig");

pub const CommandQueue = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(command_mod.Command) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandQueue {
        return .{
            .allocator = allocator,
            .commands = .empty,
        };
    }

    pub fn deinit(self: *CommandQueue) void {
        self.clear();
        self.commands.deinit(self.allocator);
    }

    pub fn clear(self: *CommandQueue) void {
        for (self.commands.items) |*command| {
            command.deinit(self.allocator);
        }
        self.commands.clearRetainingCapacity();
    }

    pub fn len(self: *const CommandQueue) usize {
        return self.commands.items.len;
    }

    pub fn enqueueCreateEntity(self: *CommandQueue, spec: command_mod.CreateEntitySpec) !void {
        try self.commands.append(self.allocator, .{
            .create_entity = .{
                .name = try self.allocator.dupe(u8, spec.name),
                .parent = spec.parent,
                .local_transform = spec.local_transform,
                .visible = spec.visible,
                .editor_only = spec.editor_only,
                .is_folder = spec.is_folder,
            },
        });
    }

    pub fn enqueueDeleteEntity(self: *CommandQueue, entity_id: scene_mod.EntityId) !void {
        try self.commands.append(self.allocator, .{
            .delete_entity = .{ .entity_id = entity_id },
        });
    }

    pub fn enqueueRenameEntity(self: *CommandQueue, entity_id: scene_mod.EntityId, name: []const u8) !void {
        try self.commands.append(self.allocator, .{
            .rename_entity = .{
                .entity_id = entity_id,
                .name = try self.allocator.dupe(u8, name),
            },
        });
    }

    pub fn enqueueSetParent(self: *CommandQueue, entity_id: scene_mod.EntityId, parent_id: ?scene_mod.EntityId) !void {
        try self.commands.append(self.allocator, .{
            .set_parent = .{
                .entity_id = entity_id,
                .parent_id = parent_id,
            },
        });
    }

    pub fn enqueueSetLocalTransform(self: *CommandQueue, entity_id: scene_mod.EntityId, transform: components_mod.Transform) !void {
        if (self.tryCoalesceTransform(.set_local_transform, entity_id, transform)) {
            return;
        }
        try self.commands.append(self.allocator, .{
            .set_local_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        });
    }

    pub fn enqueueSetWorldTransform(self: *CommandQueue, entity_id: scene_mod.EntityId, transform: components_mod.Transform) !void {
        if (self.tryCoalesceTransform(.set_world_transform, entity_id, transform)) {
            return;
        }
        try self.commands.append(self.allocator, .{
            .set_world_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        });
    }

    pub fn enqueueSetVisible(self: *CommandQueue, entity_id: scene_mod.EntityId, visible: bool) !void {
        try self.commands.append(self.allocator, .{
            .set_visible = .{
                .entity_id = entity_id,
                .visible = visible,
            },
        });
    }

    pub fn executeAll(self: *CommandQueue, world: *scene_mod.World) ![]command_mod.ExecutionResult {
        const command_count = self.commands.items.len;
        if (command_count == 0) {
            return try self.allocator.alloc(command_mod.ExecutionResult, 0);
        }

        var results = try self.allocator.alloc(command_mod.ExecutionResult, command_count);
        errdefer self.allocator.free(results);

        for (self.commands.items, 0..) |*command, index| {
            results[index] = try executeCommand(world, command.*);
            command.deinit(self.allocator);
        }
        self.commands.clearRetainingCapacity();

        return results;
    }

    fn tryCoalesceTransform(
        self: *CommandQueue,
        comptime tag: std.meta.Tag(command_mod.Command),
        entity_id: scene_mod.EntityId,
        transform: components_mod.Transform,
    ) bool {
        if (self.commands.items.len == 0) {
            return false;
        }

        const last = &self.commands.items[self.commands.items.len - 1];
        switch (last.*) {
            .set_local_transform => |*pending| {
                if (pending.entity_id != entity_id) {
                    return false;
                }
                if (tag == .set_local_transform) {
                    pending.transform = transform;
                } else {
                    last.* = .{
                        .set_world_transform = .{
                            .entity_id = entity_id,
                            .transform = transform,
                        },
                    };
                }
                return true;
            },
            .set_world_transform => |*pending| {
                if (pending.entity_id != entity_id) {
                    return false;
                }
                if (tag == .set_world_transform) {
                    pending.transform = transform;
                } else {
                    last.* = .{
                        .set_local_transform = .{
                            .entity_id = entity_id,
                            .transform = transform,
                        },
                    };
                }
                return true;
            },
            else => return false,
        }
    }
};

fn executeCommand(world: *scene_mod.World, command: command_mod.Command) !command_mod.ExecutionResult {
    return switch (command) {
        .create_entity => |create| blk: {
            const entity_id = world.createEntity(.{
                .name = create.name,
                .parent = create.parent,
                .local_transform = create.local_transform,
                .visible = create.visible,
                .editor_only = create.editor_only,
                .is_folder = create.is_folder,
            }) catch |err| {
                break :blk .{
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = true,
                .entity_id = entity_id,
            };
        },
        .delete_entity => |delete| blk: {
            const existed = world.hasEntity(delete.entity_id);
            break :blk .{
                .changed = if (existed) world.destroyEntity(delete.entity_id) else false,
                .entity_id = delete.entity_id,
                .err = if (existed) null else .entity_not_found,
            };
        },
        .rename_entity => |rename| blk: {
            const changed = world.renameEntity(rename.entity_id, rename.name) catch |err| {
                break :blk .{
                    .entity_id = rename.entity_id,
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = changed,
                .entity_id = rename.entity_id,
                .err = if (changed or world.hasEntity(rename.entity_id)) null else .entity_not_found,
            };
        },
        .set_parent => |set_parent| blk: {
            const changed = world.setParent(set_parent.entity_id, set_parent.parent_id) catch |err| {
                break :blk .{
                    .entity_id = set_parent.entity_id,
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = changed,
                .entity_id = set_parent.entity_id,
                .err = if (changed or world.hasEntity(set_parent.entity_id)) null else .entity_not_found,
            };
        },
        .set_local_transform => |set_transform| .{
            .changed = world.setEntityLocalTransform(set_transform.entity_id, set_transform.transform),
            .entity_id = set_transform.entity_id,
            .err = if (world.hasEntity(set_transform.entity_id)) null else .entity_not_found,
        },
        .set_world_transform => |set_transform| .{
            .changed = world.setEntityWorldTransform(set_transform.entity_id, set_transform.transform),
            .entity_id = set_transform.entity_id,
            .err = if (world.hasEntity(set_transform.entity_id)) null else .entity_not_found,
        },
        .set_visible => |set_visible| blk: {
            const entity = world.getEntity(set_visible.entity_id) orelse break :blk .{
                .entity_id = set_visible.entity_id,
                .err = .entity_not_found,
            };
            if (entity.visible == set_visible.visible) {
                break :blk .{
                    .entity_id = set_visible.entity_id,
                };
            }
            entity.visible = set_visible.visible;
            break :blk .{
                .changed = true,
                .entity_id = set_visible.entity_id,
            };
        },
    };
}

fn mapWorldError(err: anyerror) command_mod.CommandError {
    return switch (err) {
        error.ParentNotFound => .parent_not_found,
        error.ParentCycleDetected => .parent_cycle_detected,
        error.EntityIdConflict => .entity_id_conflict,
        else => .entity_not_found,
    };
}

test "CommandQueue executes the minimal entity editing loop" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try queue.enqueueCreateEntity(.{
        .name = "QueuedRoot",
    });
    const created = try queue.executeAll(&world);
    defer std.testing.allocator.free(created);

    try std.testing.expectEqual(@as(usize, 1), created.len);
    try std.testing.expect(created[0].ok());
    const entity_id = created[0].entity_id.?;
    try std.testing.expect(world.hasEntity(entity_id));

    try queue.enqueueRenameEntity(entity_id, "QueuedRootRenamed");
    try queue.enqueueSetVisible(entity_id, false);
    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 1.0, 2.0, 3.0 },
    });
    const updated = try queue.executeAll(&world);
    defer std.testing.allocator.free(updated);

    try std.testing.expectEqual(@as(usize, 3), updated.len);
    try std.testing.expect(updated[0].ok());
    try std.testing.expect(updated[1].ok());
    try std.testing.expect(updated[2].ok());

    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expectEqualStrings("QueuedRootRenamed", entity.name);
    try std.testing.expect(!entity.visible);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), entity.local_transform.translation[0], 0.0001);

    try queue.enqueueDeleteEntity(entity_id);
    const deleted = try queue.executeAll(&world);
    defer std.testing.allocator.free(deleted);

    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expect(deleted[0].ok());
    try std.testing.expect(deleted[0].changed);
    try std.testing.expect(!world.hasEntity(entity_id));
}

test "CommandQueue coalesces consecutive transform writes for the same entity" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Mover" });

    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 1.0, 0.0, 0.0 },
    });
    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 2.0, 0.0, 0.0 },
    });
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    const results = try queue.executeAll(&world);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].ok());
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), world.getEntityConst(entity_id).?.local_transform.translation[0], 0.0001);
}

test "CommandQueue reports parent errors without aborting the batch" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Child" });
    try queue.enqueueSetParent(entity_id, 9999);
    try queue.enqueueRenameEntity(entity_id, "StillRuns");

    const results = try queue.executeAll(&world);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(command_mod.CommandError.parent_not_found, results[0].err.?);
    try std.testing.expect(results[1].ok());
    try std.testing.expectEqualStrings("StillRuns", world.getEntityConst(entity_id).?.name);
}
