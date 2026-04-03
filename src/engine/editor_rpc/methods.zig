///! RPC method dispatch — maps JSON-RPC method names to engine operations.
///!
///! All methods run on the main thread (called from Server.processPending),
///! so they have safe access to World, Renderer, and EditorState.
///!
///! Adding a new method:
///!   1. Add a variant to the `Method` enum
///!   2. Add a case in the `execute` switch — the compiler enforces exhaustiveness
///!   That's it. The capabilities list is auto-generated from the enum.
const std = @import("std");
const core = @import("../core/layer.zig");
const world_mod = @import("../scene/world.zig");
const components = @import("../scene/components.zig");

const World = world_mod.World;
const Entity = world_mod.Entity;
const EntityId = world_mod.EntityId;

const log = std.log.scoped(.editor_rpc_methods);

// ── Method Registry ─────────────────────────────────────────────────
// Zig's comptime enum + exhaustive switch guarantees every method is
// handled. `std.meta.stringToEnum` provides O(1) name → enum dispatch.

const Method = enum {
    @"editor.ping",
    @"editor.getCapabilities",
    @"scene.getHierarchy",
    @"scene.createEntity",
    @"scene.deleteEntity",
    @"entity.getTransform",
    @"entity.setTransform",
    @"entity.setName",
    @"entity.getComponents",
    @"editor.setSelection",
    @"editor.undo",
    @"editor.redo",
    @"playback.play",
    @"playback.pause",
    @"playback.stop",
};

const method_names = blk: {
    const fields = @typeInfo(Method).@"enum".fields;
    var result: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| result[i] = f.name;
    break :blk result;
};

const Subscription = enum {
    @"on:scene.changed",
    @"on:selection.changed",
    @"on:console.log",
    @"on:viewport.metrics",
};

const subscription_names = blk: {
    const fields = @typeInfo(Subscription).@"enum".fields;
    var result: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| result[i] = f.name;
    break :blk result;
};

// ── Public API ──────────────────────────────────────────────────────

/// Dispatch a raw JSON-RPC request payload. Returns the JSON response
/// string to send back (caller owns the memory), or null for notifications.
pub fn dispatch(allocator: std.mem.Allocator, payload: []const u8, layer_context: *core.LayerContext) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return try errorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return try errorResponse(allocator, null, -32600, "Invalid Request"),
    };

    const method_val = obj.get("method") orelse return try errorResponse(allocator, null, -32600, "Missing method");
    const method_str = switch (method_val) {
        .string => |s| s,
        else => return try errorResponse(allocator, null, -32600, "Method must be string"),
    };

    const id_val = obj.get("id");
    const params = obj.get("params");

    // Notifications (no id) — fire-and-forget
    if (id_val == null) {
        log.debug("Received notification: {s}", .{method_str});
        return null;
    }

    // Look up method
    const method = std.meta.stringToEnum(Method, method_str) orelse {
        return try errorResponse(allocator, id_val, -32601, "MethodNotFound");
    };

    const result_json = execute(method, allocator, params, layer_context) catch |err| {
        return try errorResponse(allocator, id_val, -32603, @errorName(err));
    };

    return try successResponse(allocator, id_val, result_json);
}

// ── Method Dispatch (exhaustive switch) ─────────────────────────────

fn execute(method: Method, allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    return switch (method) {
        .@"editor.ping" => try json(allocator, .{ .pong = true }),
        .@"editor.getCapabilities" => try json(allocator, .{
            .version = "0.1.0",
            .methods = &method_names,
            .subscriptions = &subscription_names,
        }),
        .@"scene.getHierarchy" => try sceneGetHierarchy(allocator, ctx),
        .@"scene.createEntity" => try sceneCreateEntity(allocator, params, ctx),
        .@"scene.deleteEntity" => try sceneDeleteEntity(allocator, params, ctx),
        .@"entity.getTransform" => try entityGetTransform(allocator, params, ctx),
        .@"entity.setTransform" => try entitySetTransform(allocator, params, ctx),
        .@"entity.setName" => try entitySetName(allocator, params, ctx),
        .@"entity.getComponents" => try entityGetComponents(allocator, params, ctx),
        .@"editor.setSelection" => try editorSetSelection(allocator, params, ctx),
        .@"editor.undo" => json(allocator, .{}), // TODO: wire to history.undo()
        .@"editor.redo" => json(allocator, .{}), // TODO: wire to history.redo()
        .@"playback.play" => blk: {
            ctx.playback_controller.setState(.playing);
            break :blk try json(allocator, .{});
        },
        .@"playback.pause" => blk: {
            ctx.playback_controller.setState(.paused);
            break :blk try json(allocator, .{});
        },
        .@"playback.stop" => blk: {
            ctx.playback_controller.setState(.stopped);
            break :blk try json(allocator, .{});
        },
    };
}

// ── Handler Implementations ─────────────────────────────────────────

fn sceneGetHierarchy(allocator: std.mem.Allocator, ctx: *core.LayerContext) ![]u8 {
    const world = ctx.world;
    var roots = std.ArrayList(EntityNodeJson).empty;
    defer {
        for (roots.items) |*node| freeEntityNode(allocator, node);
        roots.deinit(allocator);
    }

    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            const node = buildEntityNode(allocator, world, entity.id) catch continue;
            try roots.append(allocator, node);
        }
    }

    return try json(allocator, .{ .roots = roots.items });
}

fn sceneCreateEntity(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const name_str = if (params) |p| (if (p.object.get("name")) |n| switch (n) {
        .string => |s| s,
        else => "New Entity",
    } else "New Entity") else "New Entity";

    const owned_name = try ctx.world.allocator.dupe(u8, name_str);
    const entity_id = try ctx.world.createEntity(.{ .name = owned_name });
    return try json(allocator, .{ .entityId = entity_id });
}

fn sceneDeleteEntity(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const entity_id = try getEntityIdParam(params);
    _ = ctx.world.destroyEntity(entity_id);
    return try json(allocator, .{});
}

fn entityGetTransform(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const entity_id = try getEntityIdParam(params);
    const entity = ctx.world.getEntityConst(entity_id) orelse return error.EntityNotFound;

    const t = entity.local_transform;
    return try json(allocator, .{
        .position = .{ .x = t.translation[0], .y = t.translation[1], .z = t.translation[2] },
        .rotation = .{ .x = t.rotation[0], .y = t.rotation[1], .z = t.rotation[2], .w = t.rotation[3] },
        .scale = .{ .x = t.scale[0], .y = t.scale[1], .z = t.scale[2] },
    });
}

fn entitySetTransform(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const eid = try getEntityIdParam(params);
    const p = params orelse return error.InvalidArguments;
    const entity = ctx.world.getEntity(eid) orelse return error.EntityNotFound;

    if (p.object.get("transform")) |t_val| {
        const t_obj = switch (t_val) {
            .object => |o| o,
            else => return error.InvalidArguments,
        };
        if (t_obj.get("position")) |pos| {
            if (readVec3(pos)) |v| entity.local_transform.translation = v;
        }
        if (t_obj.get("rotation")) |rot| {
            if (readQuat(rot)) |q| entity.local_transform.rotation = q;
        }
        if (t_obj.get("scale")) |scale| {
            if (readVec3(scale)) |v| entity.local_transform.scale = v;
        }
        ctx.world.markDirty(eid);
    }

    return try json(allocator, .{});
}

fn entitySetName(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const eid = try getEntityIdParam(params);
    const p = params orelse return error.InvalidArguments;

    const name = switch (p.object.get("name") orelse return error.InvalidArguments) {
        .string => |s| s,
        else => return error.InvalidArguments,
    };

    const entity = ctx.world.getEntity(eid) orelse return error.EntityNotFound;
    ctx.world.allocator.free(entity.name);
    entity.name = try ctx.world.allocator.dupe(u8, name);
    ctx.world.markSceneChanged();

    return try json(allocator, .{});
}

fn entityGetComponents(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const entity_id = try getEntityIdParam(params);
    const entity = ctx.world.getEntityConst(entity_id) orelse return error.EntityNotFound;

    // Comptime iteration over all optional component fields
    const ComponentEntry = struct { type: []const u8 };
    var list = std.ArrayList(ComponentEntry).empty;
    defer list.deinit(allocator);

    inline for (component_fields) |field| {
        if (@field(entity, field.name) != null) {
            try list.append(allocator, .{ .type = field.display_name });
        }
    }

    return try json(allocator, .{ .components = list.items });
}

fn editorSetSelection(allocator: std.mem.Allocator, params: ?std.json.Value, ctx: *core.LayerContext) ![]u8 {
    const p = params orelse return try json(allocator, .{});
    const ids_val = p.object.get("entityIds") orelse return try json(allocator, .{});
    const ids_arr = switch (ids_val) {
        .array => |a| a,
        else => return try json(allocator, .{}),
    };

    var ids = std.ArrayList(EntityId).empty;
    defer ids.deinit(allocator);

    for (ids_arr.items) |item| {
        const id: EntityId = switch (item) {
            .integer => |i| @intCast(i),
            .float => |f| @intFromFloat(f),
            else => continue,
        };
        try ids.append(allocator, id);
    }

    _ = try ctx.renderer.selection_history.replaceSelection(ids.items);
    return try json(allocator, .{});
}

// ── Entity Tree ─────────────────────────────────────────────────────

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

// ── Component Field Table (comptime) ────────────────────────────────
// Maps Entity struct fields to display names. Adding a component to
// Entity automatically gets picked up here — just add to this table.

const ComponentField = struct { name: []const u8, display_name: []const u8 };
const component_fields = [_]ComponentField{
    .{ .name = "camera", .display_name = "Camera" },
    .{ .name = "mesh", .display_name = "Mesh" },
    .{ .name = "skinned_mesh", .display_name = "SkinnedMesh" },
    .{ .name = "animator", .display_name = "Animator" },
    .{ .name = "rigidbody", .display_name = "Rigidbody" },
    .{ .name = "box_collider", .display_name = "BoxCollider" },
    .{ .name = "sphere_collider", .display_name = "SphereCollider" },
    .{ .name = "mesh_collider", .display_name = "MeshCollider" },
    .{ .name = "constraint", .display_name = "Constraint" },
    .{ .name = "material", .display_name = "Material" },
    .{ .name = "light", .display_name = "Light" },
    .{ .name = "vfx", .display_name = "Vfx" },
    .{ .name = "script", .display_name = "Script" },
    .{ .name = "audio_source", .display_name = "AudioSource" },
    .{ .name = "audio_listener", .display_name = "AudioListener" },
    .{ .name = "nav_agent", .display_name = "NavAgent" },
};

// ── Helpers ─────────────────────────────────────────────────────────

fn getEntityIdParam(params: ?std.json.Value) !EntityId {
    const p = params orelse return error.InvalidArguments;
    const id_val = p.object.get("entityId") orelse return error.InvalidArguments;
    return switch (id_val) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => error.InvalidArguments,
    };
}

fn readVec3(val: std.json.Value) ?[3]f32 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    return .{
        jsonFloat(obj.get("x") orelse return null),
        jsonFloat(obj.get("y") orelse return null),
        jsonFloat(obj.get("z") orelse return null),
    };
}

fn readQuat(val: std.json.Value) ?[4]f32 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    return .{
        jsonFloat(obj.get("x") orelse return null),
        jsonFloat(obj.get("y") orelse return null),
        jsonFloat(obj.get("z") orelse return null),
        jsonFloat(obj.get("w") orelse return null),
    };
}

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

/// Serialize any comptime-known struct to JSON.
fn json(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var buf: [4096]u8 = undefined;
    var adapter = writer.adaptToNewApi(&buf);
    try std.json.Stringify.value(value, .{}, &adapter.new_interface);
    try adapter.new_interface.flush();
    if (adapter.err) |err| return err;
    return try output.toOwnedSlice(allocator);
}

fn successResponse(allocator: std.mem.Allocator, id: ?std.json.Value, result_json: []u8) ![]u8 {
    defer allocator.free(result_json);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    const w = &adapter.new_interface;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(w, id);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
    try w.flush();
    if (adapter.err) |err| return err;

    return try buf.toOwnedSlice(allocator);
}

fn errorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    const w = &adapter.new_interface;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
    try w.flush();
    if (adapter.err) |err| return err;

    return try buf.toOwnedSlice(allocator);
}

fn writeJsonId(w: anytype, id: ?std.json.Value) !void {
    if (id) |id_val| {
        switch (id_val) {
            .integer => |i| try w.print("{d}", .{i}),
            .string => |s| {
                try w.writeAll("\"");
                try w.writeAll(s);
                try w.writeAll("\"");
            },
            else => try w.writeAll("null"),
        }
    } else {
        try w.writeAll("null");
    }
}
