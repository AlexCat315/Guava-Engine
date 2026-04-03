///! RPC method dispatch framework with comptime auto-discovery.
///!
///! **Adding a new RPC method: just add a `pub fn` to `handlers`.**
///! Everything else (dispatch, capabilities, error handling) is generated.
///!
///!   // Example: adding a new method "editor.clearLogs"
///!   pub fn @"editor.clearLogs"(ctx: *Ctx) !void {
///!       ctx.layer.console.clear();
///!       try ctx.reply(.{});
///!   }
///!
///! That's it. No enum, no switch, no capabilities list update.
const std = @import("std");
const core = @import("../core/layer.zig");
const world_mod = @import("../scene/world.zig");

const World = world_mod.World;
const Entity = world_mod.Entity;
const EntityId = world_mod.EntityId;

const log = std.log.scoped(.editor_rpc);

// ═══════════════════════════════════════════════════════════════════
//  RPC Call Context — passed to every handler
// ═══════════════════════════════════════════════════════════════════

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
    layer: *core.LayerContext,
    _result: ?[]u8 = null,

    /// Read a required parameter by key, auto-coercing JSON type.
    pub fn param(self: *Ctx, comptime T: type, key: []const u8) !T {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return coerce(T, val);
    }

    /// Read an optional parameter by key. Returns null if missing.
    pub fn paramOpt(self: *Ctx, comptime T: type, key: []const u8) !?T {
        const p = self.params orelse return null;
        const val = p.object.get(key) orelse return null;
        return try coerce(T, val);
    }

    /// Read a required JSON array parameter.
    pub fn paramArray(self: *Ctx, key: []const u8) !std.json.Array {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return switch (val) {
            .array => |a| a,
            else => error.InvalidArguments,
        };
    }

    /// Read a required JSON object parameter.
    pub fn paramObj(self: *Ctx, key: []const u8) !std.json.ObjectMap {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return switch (val) {
            .object => |o| o,
            else => error.InvalidArguments,
        };
    }

    /// Send the result back. Call once per handler.
    pub fn reply(self: *Ctx, value: anytype) !void {
        self._result = try json(self.allocator, value);
    }

    fn coerce(comptime T: type, val: std.json.Value) !T {
        return switch (T) {
            u64 => switch (val) {
                .integer => |i| @intCast(i),
                .float => |f| @intFromFloat(f),
                else => error.InvalidArguments,
            },
            i64 => switch (val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => error.InvalidArguments,
            },
            f32 => switch (val) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => error.InvalidArguments,
            },
            f64 => switch (val) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => error.InvalidArguments,
            },
            bool => switch (val) {
                .bool => |b| b,
                else => error.InvalidArguments,
            },
            []const u8 => switch (val) {
                .string => |s| s,
                else => error.InvalidArguments,
            },
            else => @compileError("Unsupported param type: " ++ @typeName(T)),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════
//  Handler Definitions — THIS IS THE ONLY PLACE YOU EDIT
// ═══════════════════════════════════════════════════════════════════

const handlers = struct {
    pub fn @"editor.ping"(ctx: *Ctx) !void {
        try ctx.reply(.{ .pong = true });
    }

    pub fn @"editor.getCapabilities"(ctx: *Ctx) !void {
        try ctx.reply(.{
            .version = "0.1.0",
            .methods = &method_names,
            .subscriptions = &subscription_names,
        });
    }

    pub fn @"scene.getHierarchy"(ctx: *Ctx) !void {
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

    pub fn @"scene.createEntity"(ctx: *Ctx) !void {
        const name_str = (try ctx.paramOpt([]const u8, "name")) orelse "New Entity";
        const owned = try ctx.layer.world.allocator.dupe(u8, name_str);
        const eid = try ctx.layer.world.createEntity(.{ .name = owned });
        try ctx.reply(.{ .entityId = eid });
    }

    pub fn @"scene.deleteEntity"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        _ = ctx.layer.world.destroyEntity(eid);
        try ctx.reply(.{});
    }

    pub fn @"entity.getTransform"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;
        const t = entity.local_transform;
        try ctx.reply(.{
            .position = .{ .x = t.translation[0], .y = t.translation[1], .z = t.translation[2] },
            .rotation = .{ .x = t.rotation[0], .y = t.rotation[1], .z = t.rotation[2], .w = t.rotation[3] },
            .scale = .{ .x = t.scale[0], .y = t.scale[1], .z = t.scale[2] },
        });
    }

    pub fn @"entity.setTransform"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

        const t_obj = try ctx.paramObj("transform");
        if (t_obj.get("position")) |pos| {
            if (readVec3(pos)) |v| entity.local_transform.translation = v;
        }
        if (t_obj.get("rotation")) |rot| {
            if (readQuat(rot)) |q| entity.local_transform.rotation = q;
        }
        if (t_obj.get("scale")) |scale| {
            if (readVec3(scale)) |v| entity.local_transform.scale = v;
        }
        ctx.layer.world.markDirty(eid);
        try ctx.reply(.{});
    }

    pub fn @"entity.setName"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        const name = try ctx.param([]const u8, "name");
        const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

        ctx.layer.world.allocator.free(entity.name);
        entity.name = try ctx.layer.world.allocator.dupe(u8, name);
        ctx.layer.world.markSceneChanged();
        try ctx.reply(.{});
    }

    pub fn @"entity.getComponents"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

        const Entry = struct { type: []const u8 };
        var list = std.ArrayList(Entry).empty;
        defer list.deinit(ctx.allocator);

        inline for (component_fields) |field| {
            if (@field(entity, field.name) != null) {
                try list.append(ctx.allocator, .{ .type = field.display_name });
            }
        }
        try ctx.reply(.{ .components = list.items });
    }

    pub fn @"editor.setSelection"(ctx: *Ctx) !void {
        const arr = try ctx.paramArray("entityIds");
        var ids = std.ArrayList(EntityId).empty;
        defer ids.deinit(ctx.allocator);

        for (arr.items) |item| {
            const id: EntityId = switch (item) {
                .integer => |i| @intCast(i),
                .float => |f| @intFromFloat(f),
                else => continue,
            };
            try ids.append(ctx.allocator, id);
        }
        _ = try ctx.layer.renderer.selection_history.replaceSelection(ids.items);
        try ctx.reply(.{});
    }

    pub fn @"editor.undo"(ctx: *Ctx) !void {
        // TODO: wire to history.undo()
        try ctx.reply(.{});
    }

    pub fn @"editor.redo"(ctx: *Ctx) !void {
        // TODO: wire to history.redo()
        try ctx.reply(.{});
    }

    pub fn @"playback.play"(ctx: *Ctx) !void {
        ctx.layer.playback_controller.setState(.playing);
        try ctx.reply(.{});
    }

    pub fn @"playback.pause"(ctx: *Ctx) !void {
        ctx.layer.playback_controller.setState(.paused);
        try ctx.reply(.{});
    }

    pub fn @"playback.stop"(ctx: *Ctx) !void {
        ctx.layer.playback_controller.setState(.stopped);
        try ctx.reply(.{});
    }

    pub fn @"scene.duplicateEntity"(ctx: *Ctx) !void {
        const eid = try ctx.param(u64, "entityId");
        const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

        const name_src = entity.name;
        const copy_name = try std.fmt.allocPrint(ctx.allocator, "{s} (Copy)", .{name_src});
        defer ctx.allocator.free(copy_name);

        const owned = try ctx.layer.world.allocator.dupe(u8, copy_name);
        const new_id = try ctx.layer.world.createEntity(.{
            .name = owned,
            .parent = entity.parent,
            .local_transform = entity.local_transform,
        });
        try ctx.reply(.{ .entityId = new_id });
    }

    pub fn @"console.clear"(ctx: *Ctx) !void {
        // Log buffer lives Electron-side; engine acknowledges the request.
        try ctx.reply(.{});
    }

    pub fn @"viewport.setGizmoMode"(ctx: *Ctx) !void {
        // TODO: wire to EditorState.manipulation_mode when bridge is available
        _ = try ctx.param([]const u8, "mode");
        try ctx.reply(.{});
    }
};

// Also declare subscriptions (just names — detection logic is in subscriptions.zig)
const subscriptions = [_][]const u8{
    "on:scene.changed",
    "on:selection.changed",
    "on:console.log",
    "on:viewport.metrics",
};

// ═══════════════════════════════════════════════════════════════════
//  Comptime-generated dispatch — DO NOT EDIT MANUALLY
// ═══════════════════════════════════════════════════════════════════

const handler_decls = @typeInfo(handlers).@"struct".decls;

const method_names = blk: {
    var result: [handler_decls.len][]const u8 = undefined;
    for (handler_decls, 0..) |d, i| result[i] = d.name;
    break :blk result;
};

const subscription_names = subscriptions;

fn dispatchToHandler(method_str: []const u8, ctx: *Ctx) !void {
    inline for (handler_decls) |decl| {
        if (std.mem.eql(u8, method_str, decl.name)) {
            return @field(handlers, decl.name)(ctx);
        }
    }
    return error.MethodNotFound;
}

// ═══════════════════════════════════════════════════════════════════
//  Public API — called from server.zig
// ═══════════════════════════════════════════════════════════════════

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

    const method_str = switch (obj.get("method") orelse return try errorResponse(allocator, null, -32600, "Missing method")) {
        .string => |s| s,
        else => return try errorResponse(allocator, null, -32600, "Method must be string"),
    };

    const id_val = obj.get("id");
    const params = obj.get("params");

    // Notifications (no id) — fire-and-forget
    if (id_val == null) {
        log.debug("Notification: {s}", .{method_str});
        return null;
    }

    var ctx = Ctx{
        .allocator = allocator,
        .params = params,
        .layer = layer_context,
    };

    dispatchToHandler(method_str, &ctx) catch |err| {
        return try errorResponse(allocator, id_val, if (err == error.MethodNotFound) @as(i64, -32601) else -32603, @errorName(err));
    };

    return try successResponse(allocator, id_val, ctx._result orelse try json(allocator, .{}));
}

// ═══════════════════════════════════════════════════════════════════
//  Internal helpers
// ═══════════════════════════════════════════════════════════════════

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

fn readVec3(val: std.json.Value) ?[3]f32 {
    const obj = switch (val) { .object => |o| o, else => return null };
    return .{
        jsonFloat(obj.get("x") orelse return null),
        jsonFloat(obj.get("y") orelse return null),
        jsonFloat(obj.get("z") orelse return null),
    };
}

fn readQuat(val: std.json.Value) ?[4]f32 {
    const obj = switch (val) { .object => |o| o, else => return null };
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
