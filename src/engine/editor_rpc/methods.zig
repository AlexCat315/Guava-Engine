///! RPC method dispatch — maps JSON-RPC method names to engine operations.
///!
///! All methods run on the main thread (called from Server.processPending),
///! so they have safe access to World, Renderer, and EditorState.
const std = @import("std");
const core = @import("../core/layer.zig");
const world_mod = @import("../scene/world.zig");
const components = @import("../scene/components.zig");

const World = world_mod.World;
const Entity = world_mod.Entity;
const EntityId = world_mod.EntityId;

const log = std.log.scoped(.editor_rpc_methods);

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

    // Extract fields
    const method_val = obj.get("method") orelse return try errorResponse(allocator, null, -32600, "Missing method");
    const method = switch (method_val) {
        .string => |s| s,
        else => return try errorResponse(allocator, null, -32600, "Method must be string"),
    };

    const id_val = obj.get("id");
    const params = obj.get("params");

    // Notifications (no id) — process but don't respond
    if (id_val == null) {
        handleNotification(method, params, layer_context);
        return null;
    }

    // Dispatch to handler
    const result_json = callMethod(allocator, method, params, layer_context) catch |err| {
        return try errorResponse(allocator, id_val, -32603, @errorName(err));
    };

    return try successResponse(allocator, id_val, result_json);
}

fn callMethod(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: ?std.json.Value,
    layer_context: *core.LayerContext,
) ![]u8 {
    // ── Lifecycle ──────────────────────────────────────────────
    if (std.mem.eql(u8, method, "editor.ping")) {
        return try stringify(allocator, .{ .pong = true });
    }

    if (std.mem.eql(u8, method, "editor.getCapabilities")) {
        return try stringify(allocator, .{
            .version = "0.1.0",
            .methods = &[_][]const u8{
                "editor.ping",
                "editor.getCapabilities",
                "scene.getHierarchy",
                "scene.createEntity",
                "scene.deleteEntity",
                "entity.getTransform",
                "entity.setTransform",
                "entity.setName",
                "editor.undo",
                "editor.redo",
                "playback.play",
                "playback.pause",
                "playback.stop",
            },
            .subscriptions = &[_][]const u8{
                "on:scene.changed",
                "on:selection.changed",
                "on:console.log",
                "on:viewport.metrics",
            },
        });
    }

    // ── Scene Hierarchy ───────────────────────────────────────
    if (std.mem.eql(u8, method, "scene.getHierarchy")) {
        return try getSceneHierarchy(allocator, layer_context);
    }

    if (std.mem.eql(u8, method, "scene.createEntity")) {
        return try createEntity(allocator, params, layer_context);
    }

    if (std.mem.eql(u8, method, "scene.deleteEntity")) {
        return try deleteEntity(allocator, params, layer_context);
    }

    // ── Entity ────────────────────────────────────────────────
    if (std.mem.eql(u8, method, "entity.getTransform")) {
        return try getEntityTransform(allocator, params, layer_context);
    }

    if (std.mem.eql(u8, method, "entity.setTransform")) {
        return try setEntityTransform(allocator, params, layer_context);
    }

    if (std.mem.eql(u8, method, "entity.setName")) {
        return try setEntityName(allocator, params, layer_context);
    }

    // ── Editor Actions ────────────────────────────────────────
    if (std.mem.eql(u8, method, "editor.undo")) {
        // TODO: Wire to history.undo() when EditorState is accessible via layer_context
        return try stringify(allocator, .{});
    }

    if (std.mem.eql(u8, method, "editor.redo")) {
        // TODO: Wire to history.redo()
        return try stringify(allocator, .{});
    }

    // ── Playback ──────────────────────────────────────────────
    if (std.mem.eql(u8, method, "playback.play")) {
        layer_context.playback_controller.setState(.playing);
        return try stringify(allocator, .{});
    }

    if (std.mem.eql(u8, method, "playback.pause")) {
        layer_context.playback_controller.setState(.paused);
        return try stringify(allocator, .{});
    }

    if (std.mem.eql(u8, method, "playback.stop")) {
        layer_context.playback_controller.setState(.stopped);
        return try stringify(allocator, .{});
    }

    return error.MethodNotFound;
}

fn handleNotification(method: []const u8, params: ?std.json.Value, layer_context: *core.LayerContext) void {
    _ = params;
    _ = layer_context;
    log.debug("Received notification: {s}", .{method});
}

// ── Method Implementations ──────────────────────────────────────────

fn getSceneHierarchy(allocator: std.mem.Allocator, layer_context: *core.LayerContext) ![]u8 {
    const world = layer_context.world;
    var roots = std.ArrayList(EntityNodeJson).empty;
    defer {
        for (roots.items) |*node| freeEntityNode(allocator, node);
        roots.deinit(allocator);
    }

    // Iterate all entities, collect roots (no parent)
    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            const node = buildEntityNode(allocator, world, entity.id) catch continue;
            try roots.append(allocator, node);
        }
    }

    return try stringify(allocator, .{ .roots = roots.items });
}

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

    // Use entity's children list directly
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

fn createEntity(allocator: std.mem.Allocator, params: ?std.json.Value, layer_context: *core.LayerContext) ![]u8 {
    const name_str = if (params) |p| (if (p.object.get("name")) |n| switch (n) {
        .string => |s| s,
        else => "New Entity",
    } else "New Entity") else "New Entity";

    // World takes ownership of name, so we must dupe it with the world's allocator
    const owned_name = try layer_context.world.allocator.dupe(u8, name_str);
    const entity_id = try layer_context.world.createEntity(.{ .name = owned_name });
    return try stringify(allocator, .{ .entityId = entity_id });
}

fn deleteEntity(allocator: std.mem.Allocator, params: ?std.json.Value, layer_context: *core.LayerContext) ![]u8 {
    const entity_id = try getEntityIdParam(params);
    _ = layer_context.world.destroyEntity(entity_id);
    return try stringify(allocator, .{});
}

fn getEntityTransform(allocator: std.mem.Allocator, params: ?std.json.Value, layer_context: *core.LayerContext) ![]u8 {
    const entity_id = try getEntityIdParam(params);
    const entity = layer_context.world.getEntityConst(entity_id) orelse
        return error.EntityNotFound;

    const t = entity.local_transform;
    return try stringify(allocator, .{
        .position = .{ .x = t.translation[0], .y = t.translation[1], .z = t.translation[2] },
        .rotation = .{ .x = t.rotation[0], .y = t.rotation[1], .z = t.rotation[2], .w = t.rotation[3] },
        .scale = .{ .x = t.scale[0], .y = t.scale[1], .z = t.scale[2] },
    });
}

fn setEntityTransform(allocator: std.mem.Allocator, params: ?std.json.Value, layer_context: *core.LayerContext) ![]u8 {
    const eid = try getEntityIdParam(params);
    const p = params orelse return error.InvalidArguments;

    const entity = layer_context.world.getEntity(eid) orelse
        return error.EntityNotFound;

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
        layer_context.world.markDirty(eid);
    }

    return try stringify(allocator, .{});
}

fn setEntityName(allocator: std.mem.Allocator, params: ?std.json.Value, layer_context: *core.LayerContext) ![]u8 {
    const eid = try getEntityIdParam(params);
    const p = params orelse return error.InvalidArguments;

    const name = switch (p.object.get("name") orelse return error.InvalidArguments) {
        .string => |s| s,
        else => return error.InvalidArguments,
    };

    const entity = layer_context.world.getEntity(eid) orelse
        return error.EntityNotFound;

    // Free old name, allocate new one
    layer_context.world.allocator.free(entity.name);
    entity.name = try layer_context.world.allocator.dupe(u8, name);
    layer_context.world.markSceneChanged();

    return try stringify(allocator, .{});
}

// ── Helpers ──────────────────────────────────────────────────────────

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
    const x = jsonFloat(obj.get("x") orelse return null);
    const y = jsonFloat(obj.get("y") orelse return null);
    const z = jsonFloat(obj.get("z") orelse return null);
    return .{ x, y, z };
}

fn readQuat(val: std.json.Value) ?[4]f32 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    const x = jsonFloat(obj.get("x") orelse return null);
    const y = jsonFloat(obj.get("y") orelse return null);
    const z = jsonFloat(obj.get("z") orelse return null);
    const w = jsonFloat(obj.get("w") orelse return null);
    return .{ x, y, z, w };
}

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
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

    // Build: {"jsonrpc":"2.0","id":<id>,"result":<result>}
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    const w = &adapter.new_interface;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
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
    try w.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
    try w.flush();
    if (adapter.err) |err| return err;

    return try buf.toOwnedSlice(allocator);
}
