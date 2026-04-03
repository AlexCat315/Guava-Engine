///! handlers/entity.zig — per-entity inspection & mutation.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const EntityId = ctx_mod.EntityId;

pub fn getTransform(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;
    const t = entity.local_transform;
    try ctx.reply(.{
        .position = .{ .x = t.translation[0], .y = t.translation[1], .z = t.translation[2] },
        .rotation = .{ .x = t.rotation[0], .y = t.rotation[1], .z = t.rotation[2], .w = t.rotation[3] },
        .scale = .{ .x = t.scale[0], .y = t.scale[1], .z = t.scale[2] },
    });
}

pub fn setTransform(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    const t_obj = try ctx.paramObj("transform");
    if (t_obj.get("position")) |pos| {
        if (ctx_mod.readVec3(pos)) |v| entity.local_transform.translation = v;
    }
    if (t_obj.get("rotation")) |rot| {
        if (ctx_mod.readQuat(rot)) |q| entity.local_transform.rotation = q;
    }
    if (t_obj.get("scale")) |scale| {
        if (ctx_mod.readVec3(scale)) |v| entity.local_transform.scale = v;
    }
    ctx.layer.world.markDirty(eid);
    try ctx.reply(.{});
}

pub fn setName(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const name = try ctx.param([]const u8, "name");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    ctx.layer.world.allocator.free(entity.name);
    entity.name = try ctx.layer.world.allocator.dupe(u8, name);
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

pub fn getComponents(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

    const Entry = struct { type: []const u8 };
    var list = std.ArrayList(Entry).empty;
    defer list.deinit(ctx.allocator);

    inline for (ctx_mod.component_fields) |field| {
        if (@field(entity, field.name) != null) {
            try list.append(ctx.allocator, .{ .type = field.display_name });
        }
    }
    try ctx.reply(.{ .components = list.items });
}
