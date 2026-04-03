///! handlers/scene.zig — scene hierarchy & entity lifecycle.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const World = ctx_mod.World;
const EntityId = ctx_mod.EntityId;

pub fn getHierarchy(ctx: *Ctx) !void {
    const world = ctx.layer.world;
    var roots = std.ArrayList(EntityNodeJson).empty;
    defer {
        for (roots.items) |*node| freeEntityNode(ctx.allocator, node);
        roots.deinit(ctx.allocator);
    }

    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            const node = buildEntityNode(ctx.allocator, world, entity.id) catch continue;
            try roots.append(ctx.allocator, node);
        }
    }
    try ctx.reply(.{ .roots = roots.items });
}

pub fn createEntity(ctx: *Ctx) !void {
    const name_str = (try ctx.paramOpt([]const u8, "name")) orelse "New Entity";
    const owned = try ctx.layer.world.allocator.dupe(u8, name_str);
    const eid = try ctx.layer.world.createEntity(.{ .name = owned });
    try ctx.reply(.{ .entityId = eid });
}

pub fn deleteEntity(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    _ = ctx.layer.world.destroyEntity(eid);
    try ctx.reply(.{});
}

pub fn duplicateEntity(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

    const copy_name = try std.fmt.allocPrint(ctx.allocator, "{s} (Copy)", .{entity.name});
    defer ctx.allocator.free(copy_name);

    const owned = try ctx.layer.world.allocator.dupe(u8, copy_name);
    const new_id = try ctx.layer.world.createEntity(.{
        .name = owned,
        .parent = entity.parent,
        .local_transform = entity.local_transform,
    });
    try ctx.reply(.{ .entityId = new_id });
}

// ── Helpers (scene-domain only) ─────────────────────────────────

const EntityNodeJson = struct {
    id: u64,
    name: []const u8,
    visible: bool,
    children: []EntityNodeJson,
};

fn freeEntityNode(allocator: std.mem.Allocator, node: *EntityNodeJson) void {
    for (node.children) |*child| freeEntityNode(allocator, @constCast(child));
    allocator.free(node.children);
}

fn buildEntityNode(allocator: std.mem.Allocator, world: *World, entity_id: EntityId) !EntityNodeJson {
    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    var children_list = std.ArrayList(EntityNodeJson).empty;
    defer children_list.deinit(allocator);

    for (entity.children.items) |child_id| {
        const child_node = buildEntityNode(allocator, world, child_id) catch continue;
        try children_list.append(allocator, child_node);
    }

    return .{
        .id = entity_id,
        .name = entity.name,
        .visible = entity.visible,
        .children = try children_list.toOwnedSlice(allocator),
    };
}
