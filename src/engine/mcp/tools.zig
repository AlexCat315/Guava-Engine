const std = @import("std");
const handles = @import("../assets/handles.zig");
const command_mod = @import("../core/command.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const query_engine = @import("../core/query_engine.zig");
const core = @import("../core/layer.zig");
const script_resource_mod = @import("../assets/script_resource.zig");
const protocol = @import("protocol.zig");
const resources_mod = @import("resources/mod.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const wasm_compiler = @import("../script/wasm_compiler.zig");

pub const Error = error{
    ToolNotFound,
    InvalidArguments,
    ShuttingDown,
};

const CommandRequest = struct {
    tool_name: []u8,
    command: command_mod.Command,

    fn deinit(self: *CommandRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

const CompileScriptRequest = struct {
    tool_name: []u8,
    script_handle: ?handles.ScriptHandle = null,
    entity_id: ?scene_mod.EntityId = null,
    source: ?[]u8 = null,
    source_path: ?[]u8 = null,
    description: ?[]u8 = null,
    enabled: bool = true,

    fn deinit(self: *CompileScriptRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.source) |source| allocator.free(source);
        if (self.source_path) |source_path| allocator.free(source_path);
        if (self.description) |description| allocator.free(description);
        self.* = undefined;
    }
};

const QueryRequest = struct {
    tool_name: []u8,
    id: ?scene_mod.EntityId = null,
    name_contains: ?[]u8 = null,
    has_component: ?[]u8 = null,
    parent_id: ?scene_mod.EntityId = null,
    visible: ?bool = null,
    origin: ?components.Vec3 = null,
    radius: ?f32 = null,
    limit: usize = 50,
    offset: usize = 0,
    count_only: bool = false,

    fn deinit(self: *QueryRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.name_contains) |name_contains| allocator.free(name_contains);
        if (self.has_component) |has_component| allocator.free(has_component);
        self.* = undefined;
    }

    fn filter(self: QueryRequest) query_engine.Filter {
        return .{
            .id = self.id,
            .name_contains = self.name_contains,
            .has_component = self.has_component,
            .parent_id = self.parent_id,
            .visible = self.visible,
            .origin = self.origin,
            .radius = self.radius,
            .limit = self.limit,
            .offset = self.offset,
            .count_only = self.count_only,
        };
    }
};

pub const PendingRequest = union(enum) {
    command: CommandRequest,
    compile_script: CompileScriptRequest,
    query_entities: QueryRequest,

    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*command| command.deinit(allocator),
            .compile_script => |*compile| compile.deinit(allocator),
            .query_entities => |*query| query.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ToolResult = struct {
    kind: enum {
        command,
        compile_script,
        query,
    } = .command,
    changed: bool = false,
    entity_id: ?scene_mod.EntityId = null,
    script_handle: ?handles.ScriptHandle = null,
    command_error: ?command_mod.CommandError = null,
    script_error: ?[]u8 = null,
    compiled: bool = false,
    attached: bool = false,
    query_result: ?query_engine.ResultSet = null,

    fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.script_error) |message| allocator.free(message);
        if (self.query_result) |*query_result| query_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const CallResponse = struct {
    tool_name: []u8,
    result: ToolResult,

    pub fn deinit(self: *CallResponse, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
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

        const response_tool_name = try self.allocator.dupe(u8, switch (request) {
            .command => |command_request| command_request.tool_name,
            .compile_script => |compile_request| compile_request.tool_name,
            .query_entities => |query_request| query_request.tool_name,
        });
        errdefer self.allocator.free(response_tool_name);

        const result = switch (request) {
            .command => |command_request| blk: {
                const execution = command_queue_mod.executeOne(layer_context.world, command_request.command) catch |err| {
                    request.deinit(self.allocator);
                    return err;
                };
                break :blk ToolResult{
                    .kind = .command,
                    .changed = execution.changed,
                    .entity_id = execution.entity_id,
                    .command_error = execution.err,
                };
            },
            .compile_script => |compile_request| blk: {
                break :blk try processCompileScriptRequest(self.allocator, layer_context, compile_request);
            },
            .query_entities => |query_request| blk: {
                break :blk ToolResult{
                    .kind = .query,
                    .query_result = try query_engine.queryAlloc(self.allocator, layer_context.world, query_request.filter()),
                };
            },
        };
        request.deinit(self.allocator);

        layer_context.world.updateHierarchy();
        try store.replaceFromRenderer(layer_context.world, layer_context.renderer);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.response = .{
            .tool_name = response_tool_name,
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

    if (std.mem.eql(u8, tool_name, "compile_script")) {
        return .{
            .compile_script = .{
                .tool_name = owned_tool_name,
                .script_handle = try parseOptionalScriptHandle(arguments, "script_handle"),
                .entity_id = try parseOptionalEntityId(arguments, "entity_id"),
                .source = try parseOptionalStringAlloc(allocator, arguments, "source"),
                .source_path = try parseOptionalStringAlloc(allocator, arguments, "source_path"),
                .description = try parseOptionalStringAlloc(allocator, arguments, "description"),
                .enabled = try parseBoolFromObject(try requireObject(arguments), "enabled", true),
            },
        };
    }

    if (std.mem.eql(u8, tool_name, "query_entities")) {
        return .{
            .query_entities = try parseQueryRequestAlloc(allocator, owned_tool_name, arguments),
        };
    }

    if (std.mem.eql(u8, tool_name, "create_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .create_entity = try parseCreateEntityAlloc(allocator, arguments),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "delete_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .delete_entity = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "rename_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .rename_entity = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .name = try parseRequiredStringAlloc(allocator, arguments, "name"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_parent")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .set_parent = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .parent_id = try parseOptionalEntityId(arguments, "parent_id"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_local_transform")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .set_local_transform = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .transform = try parseRequiredTransform(arguments, "transform"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_world_transform")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .set_world_transform = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .transform = try parseRequiredTransform(arguments, "transform"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_visible")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .command = .{
                    .set_visible = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .visible = try parseRequiredBool(arguments, "visible"),
                    },
                },
            },
        };
    }

    return error.ToolNotFound;
}

pub fn buildSummaryAlloc(allocator: std.mem.Allocator, response: CallResponse) ![]u8 {
    if (response.result.script_error) |message| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            message,
        });
    }

    if (response.result.command_error) |err| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            @tagName(err),
        });
    }

    if (response.result.kind == .compile_script) {
        return std.fmt.allocPrint(allocator, "{s} ok: script_handle={any}, compiled={}, attached={}", .{
            response.tool_name,
            response.result.script_handle,
            response.result.compiled,
            response.result.attached,
        });
    }

    if (response.result.kind == .query) {
        const query = response.result.query_result.?;
        return std.fmt.allocPrint(allocator, "{s} ok: total={}, returned={}, offset={}, limit={}, truncated={}, count_only={}", .{
            response.tool_name,
            query.total,
            query.items.len,
            query.offset,
            query.limit,
            query.truncated,
            query.count_only,
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

fn processCompileScriptRequest(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
    request: CompileScriptRequest,
) !ToolResult {
    const runtime = layer_context.script_runtime orelse return .{
        .kind = .compile_script,
        .script_error = try allocator.dupe(u8, "script runtime is not available in this context"),
    };

    runtime.bindWorld(layer_context.world);
    if (layer_context.command_queue) |queue| {
        runtime.bindCommandQueue(queue);
    }

    var source_bytes: []u8 = undefined;
    var owns_source = false;
    defer if (owns_source) allocator.free(source_bytes);

    var resource: ?*script_resource_mod.ScriptResource = null;
    if (request.script_handle) |handle| {
        resource = layer_context.world.resources.scriptMutable(handle);
    }

    if (request.source) |source| {
        source_bytes = source;
    } else if (request.source_path) |source_path| {
        source_bytes = try std.fs.cwd().readFileAlloc(allocator, source_path, 8 * 1024 * 1024);
        owns_source = true;
    } else if (resource) |existing_resource| {
        source_bytes = try allocator.dupe(u8, existing_resource.source);
        owns_source = true;
    } else {
        return .{
            .kind = .compile_script,
            .script_error = try allocator.dupe(u8, "compile_script requires source, source_path, or an existing script_handle"),
        };
    }

    var compile_result = try wasm_compiler.compileZigSourceAlloc(allocator, .{
        .source = source_bytes,
        .script_name = if (request.description) |description| description else "ai_script",
    });
    defer compile_result.deinit(allocator);

    switch (compile_result) {
        .compile_error => |message| {
            runtime.recordEvent(.{
                .script_handle = request.script_handle,
                .entity_id = request.entity_id,
                .phase = .compile,
                .severity = .@"error",
                .message = message,
            });
            return .{
                .kind = .compile_script,
                .entity_id = request.entity_id,
                .script_handle = request.script_handle,
                .script_error = try allocator.dupe(u8, message),
            };
        },
        .success => |artifact| {
            const handle = if (request.script_handle) |existing_handle| blk: {
                const existing_resource = resource orelse return .{
                    .kind = .compile_script,
                    .entity_id = request.entity_id,
                    .script_handle = request.script_handle,
                    .script_error = try allocator.dupe(u8, "script_handle does not exist"),
                };
                existing_resource.language = .wasm;
                replaceOwnedSlice(allocator, &existing_resource.source, source_bytes) catch return error.OutOfMemory;
                replaceOwnedSlice(allocator, &existing_resource.bytecode, artifact.bytecode) catch return error.OutOfMemory;
                replaceOwnedSlice(allocator, &existing_resource.user_data, artifact.parameter_schema) catch return error.OutOfMemory;
                if (request.description) |description| {
                    replaceOwnedSlice(allocator, &existing_resource.description, description) catch return error.OutOfMemory;
                }
                if (request.source_path) |source_path| {
                    replaceOwnedSlice(allocator, &existing_resource.source_path, source_path) catch return error.OutOfMemory;
                    existing_resource.last_modified = readFileMtime(source_path) catch existing_resource.last_modified;
                } else {
                    existing_resource.last_modified = std.time.microTimestamp();
                }
                break :blk existing_handle;
            } else blk: {
                const description = request.description orelse "AI Wasm Script";
                const source_path = request.source_path orelse "";
                const created_handle = try layer_context.world.resources.createScript(.{
                    .source = source_bytes,
                    .language = .wasm,
                    .entry_fn = "guava_on_update",
                    .description = description,
                    .source_path = source_path,
                });
                const created_resource = layer_context.world.resources.scriptMutable(created_handle).?;
                created_resource.bytecode = try allocator.dupe(u8, artifact.bytecode);
                allocator.free(created_resource.user_data);
                created_resource.user_data = try allocator.dupe(u8, artifact.parameter_schema);
                created_resource.last_modified = if (source_path.len != 0)
                    readFileMtime(source_path) catch std.time.microTimestamp()
                else
                    std.time.microTimestamp();
                break :blk created_handle;
            };

            if (request.source_path) |source_path| {
                if (runtime.hot_reload) |*hr| {
                    try hr.registerScript(source_path, handle);
                }
            }

            if (request.script_handle != null) {
                runtime.reloadScript(handle) catch {
                    return .{
                        .kind = .compile_script,
                        .entity_id = request.entity_id,
                        .script_handle = handle,
                        .compiled = true,
                        .script_error = try allocator.dupe(u8, runtime.getVM(.wasm).?.getError()),
                    };
                };
            }

            var attached = false;
            if (request.entity_id) |entity_id| {
                if (layer_context.world.getEntity(entity_id)) |entity| {
                    const previous_parameters = if (entity.script) |existing_script| existing_script.parameters else &.{};
                    entity.script = .{
                        .script_handle = handle,
                        .language = .wasm,
                        .instance_id = null,
                        .enabled = request.enabled,
                        .parameters = previous_parameters,
                    };
                    runtime.reconcileWorld(layer_context.world);
                    attached = true;
                } else {
                    return .{
                        .kind = .compile_script,
                        .changed = true,
                        .entity_id = entity_id,
                        .script_handle = handle,
                        .compiled = true,
                        .script_error = try allocator.dupe(u8, "entity_id does not exist"),
                    };
                }
            }

            runtime.recordEvent(.{
                .script_handle = handle,
                .entity_id = request.entity_id,
                .phase = .compile,
                .severity = .info,
                .message = "compiled wasm script",
            });

            return .{
                .kind = .compile_script,
                .changed = true,
                .entity_id = request.entity_id,
                .script_handle = handle,
                .compiled = true,
                .attached = attached,
            };
        },
    }
}

fn replaceOwnedSlice(allocator: std.mem.Allocator, target: *[]const u8, next: []const u8) !void {
    allocator.free(target.*);
    target.* = try allocator.dupe(u8, next);
}

fn readFileMtime(path: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mtime;
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

fn parseQueryRequestAlloc(
    allocator: std.mem.Allocator,
    owned_tool_name: []u8,
    arguments: ?std.json.Value,
) !QueryRequest {
    const args = try requireObject(arguments);

    const id = try parseOptionalEntityIdFromObject(args, "id");
    const name_contains = try parseOptionalStringAllocFromObject(allocator, args, "name_contains");
    errdefer if (name_contains) |text| allocator.free(text);
    const has_component = try parseOptionalStringAllocFromObject(allocator, args, "has_component");
    errdefer if (has_component) |text| allocator.free(text);
    if (has_component) |component_name| {
        if (!query_engine.isComponentNameSupported(component_name)) {
            return error.InvalidArguments;
        }
    }

    const has_origin = args.get("origin") != null;
    const has_radius = args.get("radius") != null;
    if (has_origin != has_radius) {
        return error.InvalidArguments;
    }

    const origin = if (has_origin)
        try parseVec3Value(args.get("origin").?)
    else
        null;
    const radius = if (has_radius) blk: {
        const value = try parseF32Value(args.get("radius").?);
        if (value < 0.0) return error.InvalidArguments;
        break :blk value;
    } else null;

    return .{
        .tool_name = owned_tool_name,
        .id = id,
        .name_contains = name_contains,
        .has_component = has_component,
        .parent_id = try parseOptionalEntityIdFromObject(args, "parent_id"),
        .visible = try parseOptionalBoolFromObject(args, "visible"),
        .origin = origin,
        .radius = radius,
        .limit = try parseUsizeFromObject(args, "limit", 50),
        .offset = try parseUsizeFromObject(args, "offset", 0),
        .count_only = try parseBoolFromObject(args, "count_only", false),
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

fn parseOptionalStringAlloc(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    field_name: []const u8,
) !?[]u8 {
    return parseOptionalStringAllocFromObject(allocator, try requireObject(arguments), field_name);
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

fn parseOptionalStringAllocFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]u8 {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidArguments,
    };
}

fn parseRequiredEntityId(arguments: ?std.json.Value, field_name: []const u8) !scene_mod.EntityId {
    return parseRequiredEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseOptionalScriptHandle(arguments: ?std.json.Value, field_name: []const u8) !?handles.ScriptHandle {
    const object = try requireObject(arguments);
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => try parseScriptHandleValue(value),
    };
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

fn parseScriptHandleValue(value: std.json.Value) !handles.ScriptHandle {
    const raw = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidArguments,
    };
    if (raw <= 0) {
        return error.InvalidArguments;
    }
    return @enumFromInt(@as(u32, @intCast(raw)));
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

fn parseOptionalBoolFromObject(object: std.json.ObjectMap, field_name: []const u8) !?bool {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
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

fn parseUsizeFromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: usize) !usize {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .integer => |number| std.math.cast(usize, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(usize, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
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

    switch (request) {
        .command => |command_request| {
            try std.testing.expectEqualStrings("create_entity", command_request.tool_name);
            switch (command_request.command) {
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

test "parseToolCallAlloc parses query_entities with paging and radius filters" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "query_entities",
        \\  "arguments": {
        \\    "name_contains": "light",
        \\    "has_component": "light",
        \\    "visible": true,
        \\    "origin": [0, 0, 0],
        \\    "radius": 12,
        \\    "limit": 10,
        \\    "offset": 5,
        \\    "count_only": false
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

    switch (request) {
        .query_entities => |query| {
            try std.testing.expectEqualStrings("query_entities", query.tool_name);
            try std.testing.expectEqualStrings("light", query.name_contains.?);
            try std.testing.expectEqualStrings("light", query.has_component.?);
            try std.testing.expectEqual(@as(?bool, true), query.visible);
            try std.testing.expectApproxEqAbs(@as(f32, 12.0), query.radius.?, 0.0001);
            try std.testing.expectEqual(@as(usize, 10), query.limit);
            try std.testing.expectEqual(@as(usize, 5), query.offset);
            try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, &query.origin.?);
        },
        else => return error.UnexpectedCommandTag,
    }
}
