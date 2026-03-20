const std = @import("std");
const handles = @import("../assets/handles.zig");
const command_mod = @import("../core/command.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const core = @import("../core/layer.zig");
const protocol = @import("protocol.zig");
const resources_mod = @import("resources/mod.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");

pub const Error = error{
    ToolNotFound,
    InvalidArguments,
    ShuttingDown,
};

pub const PendingRequest = struct {
    tool_name: []u8,
    command: command_mod.Command,

    fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

pub const CallResponse = struct {
    tool_name: []u8,
    result: command_mod.ExecutionResult,

    pub fn deinit(self: *CallResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?PendingRequest = null,
    response: ?CallResponse = null,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.shutdown();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending) |*pending| {
            pending.deinit(self.allocator);
            self.pending = null;
        }
        if (self.response) |*response| {
            response.deinit(self.allocator);
            self.response = null;
        }
    }

    pub fn shutdown(self: *Bridge) void {
        self.mutex.lock();
        self.shutting_down = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    pub fn submitJson(self: *Bridge, tool_name: []const u8, arguments: ?std.json.Value) !CallResponse {
        var request = try parseToolCallAlloc(self.allocator, tool_name, arguments);
        errdefer request.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        while ((self.pending != null or self.response != null) and !self.shutting_down) {
            self.condition.wait(&self.mutex);
        }
        if (self.shutting_down) {
            return error.ShuttingDown;
        }

        self.pending = request;
        self.condition.broadcast();

        while (self.response == null and !self.shutting_down) {
            self.condition.wait(&self.mutex);
        }
        if (self.shutting_down and self.response == null) {
            return error.ShuttingDown;
        }

        const response = self.response.?;
        self.response = null;
        self.condition.broadcast();
        return response;
    }

    pub fn processPending(self: *Bridge, layer_context: *core.LayerContext, store: *resources_mod.SnapshotStore) !void {
        self.mutex.lock();
        if (self.pending == null or self.response != null) {
            self.mutex.unlock();
            return;
        }
        var request = self.pending.?;
        self.pending = null;
        self.mutex.unlock();

        const result = command_queue_mod.executeOne(layer_context.world, request.command) catch |err| {
            request.deinit(self.allocator);
            return err;
        };
        request.command.deinit(self.allocator);

        layer_context.world.updateHierarchy();
        try store.replaceFromRenderer(layer_context.world, layer_context.renderer);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.response = .{
            .tool_name = request.tool_name,
            .result = result,
        };
        self.condition.broadcast();
    }
};

pub fn parseToolCallAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) !PendingRequest {
    const owned_tool_name = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(owned_tool_name);

    if (std.mem.eql(u8, tool_name, "create_entity")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .create_entity = try parseCreateEntityAlloc(allocator, arguments),
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "delete_entity")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .delete_entity = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "rename_entity")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .rename_entity = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    .name = try parseRequiredStringAlloc(allocator, arguments, "name"),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_parent")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .set_parent = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    .parent_id = try parseOptionalEntityId(arguments, "parent_id"),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_local_transform")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .set_local_transform = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    .transform = try parseRequiredTransform(arguments, "transform"),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_world_transform")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .set_world_transform = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    .transform = try parseRequiredTransform(arguments, "transform"),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_visible")) {
        return .{
            .tool_name = owned_tool_name,
            .command = .{
                .set_visible = .{
                    .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    .visible = try parseRequiredBool(arguments, "visible"),
                },
            },
        };
    }

    return error.ToolNotFound;
}

pub fn buildSummaryAlloc(allocator: std.mem.Allocator, response: CallResponse) ![]u8 {
    if (response.result.err) |err| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            @tagName(err),
        });
    }

    if (response.result.entity_id) |entity_id| {
        return std.fmt.allocPrint(allocator, "{s} ok: entity {d}, changed={}", .{
            response.tool_name,
            entity_id,
            response.result.changed,
        });
    }

    return std.fmt.allocPrint(allocator, "{s} ok: changed={}", .{
        response.tool_name,
        response.result.changed,
    });
}

fn parseCreateEntityAlloc(allocator: std.mem.Allocator, arguments: ?std.json.Value) !command_mod.Command.CreateEntity {
    const args = try requireObject(arguments);
    return .{
        .name = try parseRequiredStringAllocFromObject(allocator, args, "name"),
        .parent = try parseOptionalEntityIdFromObject(args, "parent"),
        .local_transform = try parseTransformFromObject(args, "local_transform", .{}),
        .camera = if (optionalObjectField(args, "camera")) |camera_value| try parseCamera(camera_value) else null,
        .mesh = if (optionalObjectField(args, "mesh")) |mesh_value| try parseMesh(mesh_value) else null,
        .material = if (optionalObjectField(args, "material")) |material_value| try parseMaterial(material_value) else null,
        .light = if (optionalObjectField(args, "light")) |light_value| try parseLight(light_value) else null,
        .vfx = if (optionalObjectField(args, "vfx")) |vfx_value| try parseVfx(vfx_value) else null,
        .visible = try parseBoolFromObject(args, "visible", true),
        .editor_only = try parseBoolFromObject(args, "editor_only", false),
        .is_folder = try parseBoolFromObject(args, "is_folder", false),
    };
}

fn requireObject(arguments: ?std.json.Value) Error!std.json.ObjectMap {
    const value = arguments orelse return error.InvalidArguments;
    return switch (value) {
        .object => |object| object,
        else => error.InvalidArguments,
    };
}

fn parseRequiredStringAlloc(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    field_name: []const u8,
) ![]u8 {
    return parseRequiredStringAllocFromObject(allocator, try requireObject(arguments), field_name);
}

fn parseRequiredStringAllocFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]u8 {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidArguments,
    };
}

fn parseRequiredEntityId(arguments: ?std.json.Value, field_name: []const u8) !scene_mod.EntityId {
    return parseRequiredEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseRequiredEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !scene_mod.EntityId {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return try parseEntityIdValue(value);
}

fn parseOptionalEntityId(arguments: ?std.json.Value, field_name: []const u8) !?scene_mod.EntityId {
    return parseOptionalEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseOptionalEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !?scene_mod.EntityId {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => try parseEntityIdValue(value),
    };
}

fn parseRequiredBool(arguments: ?std.json.Value, field_name: []const u8) !bool {
    return parseRequiredBoolFromObject(try requireObject(arguments), field_name);
}

fn parseRequiredBoolFromObject(object: std.json.ObjectMap, field_name: []const u8) !bool {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidArguments,
    };
}

fn parseBoolFromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: bool) !bool {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidArguments,
    };
}

fn parseRequiredTransform(arguments: ?std.json.Value, field_name: []const u8) !components.Transform {
    return parseTransformFromObject(try requireObject(arguments), field_name, null);
}

fn parseTransformFromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: ?components.Transform,
) !components.Transform {
    const value = object.get(field_name) orelse return default_value orelse error.InvalidArguments;
    return try parseTransformValue(value);
}

fn parseTransformValue(value: std.json.Value) !components.Transform {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    return .{
        .translation = try parseVec3FromObject(object, "translation", .{ 0.0, 0.0, 0.0 }),
        .rotation = try parseQuatFromObject(object, "rotation", .{ 0.0, 0.0, 0.0, 1.0 }),
        .scale = try parseVec3FromObject(object, "scale", .{ 1.0, 1.0, 1.0 }),
    };
}

fn parseCamera(object: std.json.ObjectMap) !components.Camera {
    var camera = components.Camera{};
    camera.is_primary = try parseBoolFromObject(object, "is_primary", camera.is_primary);

    if (optionalObjectField(object, "projection")) |projection_value| {
        if (optionalObjectField(projection_value, "perspective")) |perspective_value| {
            camera.projection = .{
                .perspective = .{
                    .fov_y_radians = try parseF32FromObject(perspective_value, "fov_y_radians", 1.0471976),
                    .near_clip = try parseF32FromObject(perspective_value, "near_clip", 0.1),
                    .far_clip = try parseF32FromObject(perspective_value, "far_clip", 1000.0),
                },
            };
        } else if (optionalObjectField(projection_value, "orthographic")) |orthographic_value| {
            camera.projection = .{
                .orthographic = .{
                    .size = try parseF32FromObject(orthographic_value, "size", 10.0),
                    .near_clip = try parseF32FromObject(orthographic_value, "near_clip", -1.0),
                    .far_clip = try parseF32FromObject(orthographic_value, "far_clip", 1.0),
                },
            };
        } else {
            return error.InvalidArguments;
        }
    }

    return camera;
}

fn parseMesh(object: std.json.ObjectMap) !components.Mesh {
    return .{
        .handle = try parseOptionalHandleFromObject(handles.MeshHandle, object, "handle"),
        .primitive = try parseEnumFromObject(components.Primitive, object, "primitive", .custom),
    };
}

fn parseMaterial(object: std.json.ObjectMap) !components.Material {
    return .{
        .handle = try parseOptionalHandleFromObject(handles.MaterialHandle, object, "handle"),
        .shading = try parseEnumFromObject(components.ShadingModel, object, "shading", .pbr_metallic_roughness),
        .base_color_factor = try parseVec4FromObject(object, "base_color_factor", .{ 1.0, 1.0, 1.0, 1.0 }),
        .emissive_factor = try parseVec3FromObject(object, "emissive_factor", .{ 0.0, 0.0, 0.0 }),
        .metallic_factor = try parseF32FromObject(object, "metallic_factor", 1.0),
        .roughness_factor = try parseF32FromObject(object, "roughness_factor", 1.0),
        .alpha_cutoff = try parseF32FromObject(object, "alpha_cutoff", 0.5),
        .double_sided = try parseBoolFromObject(object, "double_sided", false),
    };
}

fn parseLight(object: std.json.ObjectMap) !components.Light {
    return .{
        .kind = try parseEnumFromObject(components.LightKind, object, "kind", .directional),
        .color = try parseVec3FromObject(object, "color", .{ 1.0, 1.0, 1.0 }),
        .intensity = try parseF32FromObject(object, "intensity", 1.0),
        .range = try parseF32FromObject(object, "range", 10.0),
    };
}

fn parseVfx(object: std.json.ObjectMap) !components.Vfx {
    return .{
        .kind = try parseEnumFromObject(components.VfxKind, object, "kind", .fountain),
        .looping = try parseBoolFromObject(object, "looping", true),
        .emission_rate = try parseF32FromObject(object, "emission_rate", 18.0),
        .particle_lifetime = try parseF32FromObject(object, "particle_lifetime", 1.25),
        .speed = try parseF32FromObject(object, "speed", 2.2),
        .max_particles = try parseU16FromObject(object, "max_particles", 24),
        .radius = try parseF32FromObject(object, "radius", 0.55),
        .spread = try parseF32FromObject(object, "spread", 0.35),
        .size = try parseF32FromObject(object, "size", 0.12),
        .color = try parseVec3FromObject(object, "color", .{ 1.0, 0.58, 0.26 }),
    };
}

fn optionalObjectField(object: std.json.ObjectMap, field_name: []const u8) ?std.json.ObjectMap {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .object => |child| child,
        .null => null,
        else => null,
    };
}

fn parseEntityIdValue(value: std.json.Value) !scene_mod.EntityId {
    return switch (value) {
        .integer => |number| std.math.cast(scene_mod.EntityId, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(scene_mod.EntityId, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseOptionalHandleFromObject(comptime T: type, object: std.json.ObjectMap, field_name: []const u8) !?T {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => @enumFromInt(try parseHandleIntValue(value)),
    };
}

fn parseHandleIntValue(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |number| std.math.cast(u32, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(u32, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseF32FromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: f32) !f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseF32Value(value);
}

fn parseU16FromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: u16) !u16 {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .integer => |number| std.math.cast(u16, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(u16, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseF32Value(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        else => error.InvalidArguments,
    };
}

fn parseVec3FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [3]f32,
) ![3]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec3Value(value);
}

fn parseVec4FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec4Value(value);
}

fn parseQuatFromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    return try parseVec4FromObject(object, field_name, default_value);
}

fn parseVec3Value(value: std.json.Value) ![3]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 3) {
        return error.InvalidArguments;
    }

    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
    };
}

fn parseVec4Value(value: std.json.Value) ![4]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 4) {
        return error.InvalidArguments;
    }

    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
        try parseF32Value(array.items[3]),
    };
}

fn parseEnumFromObject(
    comptime T: type,
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: T,
) !T {
    const value = object.get(field_name) orelse return default_value;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidArguments,
    };
    return std.meta.stringToEnum(T, text) orelse error.InvalidArguments;
}

test "parseToolCallAlloc parses create_entity with nested components" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "create_entity",
        \\  "arguments": {
        \\    "name": "McpLight",
        \\    "parent": 4,
        \\    "local_transform": {
        \\      "translation": [1, 2, 3],
        \\      "rotation": [0, 0, 0, 1],
        \\      "scale": [0.5, 0.5, 0.5]
        \\    },
        \\    "light": {
        \\      "kind": "spot",
        \\      "intensity": 24.0,
        \\      "range": 12.0
        \\    },
        \\    "visible": false
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var request = try parseToolCallAlloc(
        std.testing.allocator,
        parsed.value.object.get("name").?.string,
        parsed.value.object.get("arguments").?,
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("create_entity", request.tool_name);
    switch (request.command) {
        .create_entity => |create| {
            try std.testing.expectEqualStrings("McpLight", create.name);
            try std.testing.expectEqual(@as(?scene_mod.EntityId, 4), create.parent);
            try std.testing.expectApproxEqAbs(@as(f32, 3.0), create.local_transform.translation[2], 0.0001);
            try std.testing.expect(!create.visible);
            try std.testing.expect(create.light != null);
            try std.testing.expectEqual(components.LightKind.spot, create.light.?.kind);
            try std.testing.expectApproxEqAbs(@as(f32, 24.0), create.light.?.intensity, 0.0001);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "parseToolCallAlloc rejects invalid transform payloads" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "entity_id": 42,
        \\  "transform": {
        \\    "translation": [1, 2]
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        parseToolCallAlloc(std.testing.allocator, "set_local_transform", parsed.value),
    );
}
