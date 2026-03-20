const std = @import("std");
const collaboration_mod = @import("collaboration.zig");
const core = @import("../core/layer.zig");
const protocol = @import("protocol.zig");
const resources_mod = @import("resources/mod.zig");
const tools_mod = @import("tools.zig");

const EmptyObject = struct {};

pub const SyncLayer = struct {
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),

    pub fn asLayer(self: *SyncLayer) core.Layer {
        return .{
            .name = "McpSync",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *core.LayerContext) !void {
        const self: *SyncLayer = @ptrCast(@alignCast(context));
        try self.publish(layer_context);
    }

    fn onUpdate(context: *anyopaque, layer_context: *core.LayerContext) !void {
        const self: *SyncLayer = @ptrCast(@alignCast(context));
        if (self.exit_requested.load(.acquire)) {
            layer_context.window.should_close = true;
            return;
        }

        try self.tool_bridge.processPending(layer_context, self.store);
        _ = try self.collaboration_bridge.processPending(layer_context);
        try self.publish(layer_context);
    }

    fn publish(self: *SyncLayer, layer_context: *core.LayerContext) !void {
        layer_context.world.updateHierarchy();
        try self.store.replaceFromRenderer(layer_context.world, layer_context.renderer);
    }
};

pub fn spawn(
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),
) !std.Thread {
    const server = try std.heap.page_allocator.create(Server);
    errdefer std.heap.page_allocator.destroy(server);
    server.* = .{
        .store = store,
        .tool_bridge = tool_bridge,
        .collaboration_bridge = collaboration_bridge,
        .exit_requested = exit_requested,
    };

    return try std.Thread.spawn(.{}, serverMain, .{server});
}

const Server = struct {
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),
    initialized: bool = false,
    shutdown_received: bool = false,
    negotiated_protocol_version: []const u8 = protocol.default_protocol_version,

    fn requestExit(self: *Server) void {
        self.exit_requested.store(true, .release);
    }

    fn run(self: *Server) !void {
        var pending = std.ArrayList(u8).empty;
        defer pending.deinit(std.heap.page_allocator);

        var stdin_file = std.fs.File.stdin();
        var stdout_file = std.fs.File.stdout();
        var read_buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try stdin_file.read(&read_buffer);
            if (bytes_read == 0) {
                self.requestExit();
                return;
            }

            try pending.appendSlice(std.heap.page_allocator, read_buffer[0..bytes_read]);

            while (try protocol.tryExtractMessageAlloc(std.heap.page_allocator, &pending)) |body| {
                defer std.heap.page_allocator.free(body);
                const should_stop = try self.handleMessage(&stdout_file, body);
                if (should_stop) {
                    self.requestExit();
                    return;
                }
            }
        }
    }

    fn handleMessage(self: *Server, stdout_file: *std.fs.File, body: []const u8) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |err| {
            try writeErrorResponse(stdout_file, null, protocol.ErrorCode.parse_error, @errorName(err), null);
            return false;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try writeErrorResponse(stdout_file, null, protocol.ErrorCode.invalid_request, "Request must be a JSON object.", null);
            return false;
        }

        const method_value = root.object.get("method") orelse {
            try writeErrorResponse(stdout_file, root.object.get("id"), protocol.ErrorCode.invalid_request, "Missing method.", null);
            return false;
        };
        const method = switch (method_value) {
            .string => |text| text,
            else => {
                try writeErrorResponse(stdout_file, root.object.get("id"), protocol.ErrorCode.invalid_request, "Method must be a string.", null);
                return false;
            },
        };
        const id = root.object.get("id");
        const params = root.object.get("params");

        if (id == null) {
            return self.handleNotification(method);
        }

        return try self.handleRequest(stdout_file, id.?, method, params);
    }

    fn handleNotification(self: *Server, method: []const u8) bool {
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            self.initialized = true;
            return false;
        }
        if (std.mem.eql(u8, method, "notifications/cancelled")) {
            return false;
        }
        if (std.mem.eql(u8, method, "exit")) {
            return true;
        }
        return false;
    }

    fn handleRequest(
        self: *Server,
        stdout_file: *std.fs.File,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    ) !bool {
        if (std.mem.eql(u8, method, "initialize")) {
            const ServerCapabilities = struct {
                resources: EmptyObject = .{},
                tools: EmptyObject = .{},
            };
            const requested_protocol = if (params) |value|
                stringField(value, "protocolVersion") orelse protocol.default_protocol_version
            else
                protocol.default_protocol_version;
            self.negotiated_protocol_version = requested_protocol;

            try writeResult(stdout_file, id, .{
                .protocolVersion = requested_protocol,
                .capabilities = ServerCapabilities{},
                .serverInfo = .{
                    .name = "guava-engine",
                    .title = "Guava Engine MCP",
                    .version = "0.1.0",
                },
                .instructions =
                "Guava Engine MCP bridge with scene snapshots, editor context injection, and staged ghost-preview transactions. Resources: scene://hierarchy, selection://current, entity://{id}, editor://context, editor://intent-log, preview://staged. Tools: create_entity, delete_entity, rename_entity, set_parent, set_local_transform, set_world_transform, set_visible, stage_transaction, apply_staged_transaction, discard_staged_transaction.",
            });
            return false;
        }

        if (std.mem.eql(u8, method, "ping")) {
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_received = true;
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "logging/setLevel")) {
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            try writeToolList(stdout_file, id);
            return false;
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const tool_name = if (params) |value| stringField(value, "name") else null;
            if (tool_name == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "tools/call requires params.name.", null);
                return false;
            }

            const arguments = if (params) |value|
                objectField(value, "arguments")
            else
                null;
            const arguments_value = if (arguments) |value| std.json.Value{ .object = value } else null;

            if (collaboration_mod.isToolName(tool_name.?)) {
                var response = self.collaboration_bridge.submitJson(tool_name.?, arguments_value) catch |err| switch (err) {
                    error.ToolNotFound => {
                        try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "Unknown tool.", .{
                            .name = tool_name.?,
                        });
                        return false;
                    },
                    error.InvalidArguments => {
                        try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "Invalid collaboration tool arguments.", .{
                            .name = tool_name.?,
                        });
                        return false;
                    },
                    error.ShuttingDown => {
                        try writeErrorResponse(stdout_file, id, protocol.ErrorCode.internal_error, "Collaboration bridge is shutting down.", null);
                        return false;
                    },
                    else => return err,
                };
                defer response.deinit(std.heap.page_allocator);

                const summary = try collaboration_mod.buildSummaryAlloc(std.heap.page_allocator, response);
                defer std.heap.page_allocator.free(summary);

                try writeCollaborationToolResult(stdout_file, id, response, summary);
                return false;
            }

            var response = self.tool_bridge.submitJson(tool_name.?, arguments_value) catch |err| switch (err) {
                error.ToolNotFound => {
                    try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "Unknown tool.", .{
                        .name = tool_name.?,
                    });
                    return false;
                },
                error.InvalidArguments => {
                    try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "Invalid tool arguments.", .{
                        .name = tool_name.?,
                    });
                    return false;
                },
                error.ShuttingDown => {
                    try writeErrorResponse(stdout_file, id, protocol.ErrorCode.internal_error, "Tool bridge is shutting down.", null);
                    return false;
                },
                else => return err,
            };
            defer response.deinit(std.heap.page_allocator);

            const summary = try tools_mod.buildSummaryAlloc(std.heap.page_allocator, response);
            defer std.heap.page_allocator.free(summary);

            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .changed = response.result.changed,
                    .entity_id = response.result.entity_id,
                    .command_error = if (response.result.err) |err| @tagName(err) else null,
                },
                .isError = response.result.err != null,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "prompts/list")) {
            try writeResult(stdout_file, id, .{
                .prompts = &.{},
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/templates/list")) {
            try writeResult(stdout_file, id, .{
                .resourceTemplates = resources_mod.resource_templates[0..],
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/list")) {
            try self.waitUntilReady();
            const listed = try self.store.listAlloc(std.heap.page_allocator);
            defer resources_mod.freeResourceDescriptors(std.heap.page_allocator, listed);
            try writeResult(stdout_file, id, .{
                .resources = listed,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = if (params) |value| stringField(value, "uri") else null;
            if (uri == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "resources/read requires params.uri.", null);
                return false;
            }

            try self.waitUntilReady();
            const content = try self.store.readAlloc(std.heap.page_allocator, uri.?);
            if (content == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.resource_not_found, "Resource not found.", .{
                    .uri = uri.?,
                });
                return false;
            }
            defer resources_mod.freeTextResourceContents(std.heap.page_allocator, content.?);

            try writeResult(stdout_file, id, .{
                .contents = &.{content.?},
            });
            return false;
        }

        try writeErrorResponse(stdout_file, id, protocol.ErrorCode.method_not_found, "Method not found.", .{
            .method = method,
        });
        return false;
    }

    fn waitUntilReady(self: *Server) !void {
        while (!self.store.isReady()) {
            if (self.exit_requested.load(.acquire)) {
                return error.ShuttingDown;
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
};

fn serverMain(server: *Server) void {
    defer std.heap.page_allocator.destroy(server);
    server.run() catch |err| {
        std.log.err("mcp server failed: {s}", .{@errorName(err)});
        server.requestExit();
    };
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.ObjectMap {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .object => |object| object,
        .null => null,
        else => null,
    };
}

fn appendResourceDescriptorsAlloc(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.ResourceDescriptor),
    descriptors: []const protocol.ResourceDescriptor,
) !void {
    try list.ensureTotalCapacity(allocator, list.items.len + descriptors.len);
    for (descriptors) |descriptor| {
        const copy = try copyResourceDescriptorAlloc(allocator, descriptor);
        list.append(allocator, copy) catch |err| {
            freeResourceDescriptorOwned(allocator, copy);
            return err;
        };
    }
}

fn copyResourceDescriptorAlloc(
    allocator: std.mem.Allocator,
    descriptor: protocol.ResourceDescriptor,
) !protocol.ResourceDescriptor {
    var copy: protocol.ResourceDescriptor = .{
        .uri = "",
        .name = "",
        .title = null,
        .description = null,
        .mimeType = null,
        .size = descriptor.size,
    };

    copy.uri = try allocator.dupe(u8, descriptor.uri);
    errdefer allocator.free(copy.uri);
    copy.name = try allocator.dupe(u8, descriptor.name);
    errdefer allocator.free(copy.name);
    if (descriptor.title) |title| {
        copy.title = try allocator.dupe(u8, title);
        errdefer allocator.free(copy.title.?);
    }
    if (descriptor.description) |description| {
        copy.description = try allocator.dupe(u8, description);
        errdefer allocator.free(copy.description.?);
    }
    if (descriptor.mimeType) |mime_type| {
        copy.mimeType = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(copy.mimeType.?);
    }

    return copy;
}

fn freeResourceDescriptorOwned(allocator: std.mem.Allocator, descriptor: protocol.ResourceDescriptor) void {
    allocator.free(descriptor.uri);
    allocator.free(descriptor.name);
    if (descriptor.title) |title| allocator.free(title);
    if (descriptor.description) |description| allocator.free(description);
    if (descriptor.mimeType) |mime_type| allocator.free(mime_type);
}

fn writeToolList(stdout_file: *std.fs.File, id: std.json.Value) !void {
    try writeResult(stdout_file, id, .{
        .tools = &.{
            .{
                .name = "create_entity",
                .description = "Create an entity with optional parent, transform, visibility, and common scene components.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .name = .{ .@"type" = "string" },
                        .parent = .{ .@"type" = "integer" },
                        .local_transform = .{ .@"type" = "object" },
                        .camera = .{ .@"type" = "object" },
                        .mesh = .{ .@"type" = "object" },
                        .material = .{ .@"type" = "object" },
                        .light = .{ .@"type" = "object" },
                        .vfx = .{ .@"type" = "object" },
                        .visible = .{ .@"type" = "boolean" },
                        .editor_only = .{ .@"type" = "boolean" },
                        .is_folder = .{ .@"type" = "boolean" },
                    },
                    .required = &.{"name"},
                },
            },
            .{
                .name = "delete_entity",
                .description = "Delete an entity by id.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                    },
                    .required = &.{"entity_id"},
                },
            },
            .{
                .name = "rename_entity",
                .description = "Rename an entity by id.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                        .name = .{ .@"type" = "string" },
                    },
                    .required = &.{ "entity_id", "name" },
                },
            },
            .{
                .name = "set_parent",
                .description = "Set or clear an entity parent.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                        .parent_id = .{ .@"type" = "integer" },
                    },
                    .required = &.{"entity_id"},
                },
            },
            .{
                .name = "set_local_transform",
                .description = "Set the local transform of an entity.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                        .transform = .{ .@"type" = "object" },
                    },
                    .required = &.{ "entity_id", "transform" },
                },
            },
            .{
                .name = "set_world_transform",
                .description = "Set the world transform of an entity.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                        .transform = .{ .@"type" = "object" },
                    },
                    .required = &.{ "entity_id", "transform" },
                },
            },
            .{
                .name = "set_visible",
                .description = "Set entity visibility.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .entity_id = .{ .@"type" = "integer" },
                        .visible = .{ .@"type" = "boolean" },
                    },
                    .required = &.{ "entity_id", "visible" },
                },
            },
            .{
                .name = "stage_transaction",
                .description = "Stage a batch of entity tools into an isolated preview world and publish a ghost preview.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{
                        .label = .{ .@"type" = "string" },
                        .note = .{ .@"type" = "string" },
                        .source = .{ .@"type" = "string" },
                        .commands = .{ .@"type" = "array" },
                        .operations = .{ .@"type" = "array" },
                    },
                    .required = &.{"commands"},
                },
            },
            .{
                .name = "apply_staged_transaction",
                .description = "Commit the active staged transaction into the main world.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{},
                    .required = &.{},
                },
            },
            .{
                .name = "discard_staged_transaction",
                .description = "Discard the active staged transaction and clear the ghost preview.",
                .inputSchema = .{
                    .@"type" = "object",
                    .properties = .{},
                    .required = &.{},
                },
            },
        },
    });
}

fn writeCollaborationToolResult(
    stdout_file: *std.fs.File,
    id: std.json.Value,
    response: collaboration_mod.CallResponse,
    summary: []const u8,
) !void {
    switch (response.outcome) {
        .staged => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                    .preview_count = result.preview_count,
                    .error_count = result.error_count,
                },
                .isError = false,
            });
        },
        .applied => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .had_transaction = result.had_transaction,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                    .changed_count = result.changed_count,
                    .error_count = result.error_count,
                },
                .isError = false,
            });
        },
        .discarded => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .had_transaction = result.had_transaction,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                },
                .isError = false,
            });
        },
    }
}

fn writeResult(stdout_file: *std.fs.File, id: std.json.Value, result: anytype) !void {
    const framed = try protocol.encodeMessageAlloc(std.heap.page_allocator, .{
        .jsonrpc = protocol.jsonrpc_version,
        .id = id,
        .result = result,
    });
    defer std.heap.page_allocator.free(framed);
    try stdout_file.writeAll(framed);
}

fn writeErrorResponse(
    stdout_file: *std.fs.File,
    id: ?std.json.Value,
    code: i64,
    message: []const u8,
    data: anytype,
) !void {
    const framed = try protocol.encodeMessageAlloc(std.heap.page_allocator, .{
        .jsonrpc = protocol.jsonrpc_version,
        .id = if (id) |request_id| request_id else std.json.Value{ .null = {} },
        .@"error" = .{
            .code = code,
            .message = message,
            .data = data,
        },
    });
    defer std.heap.page_allocator.free(framed);
    try stdout_file.writeAll(framed);
}

test "stringField reads string params from JSON objects" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"params\":{\"uri\":\"scene://hierarchy\"}}", .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?;
    try std.testing.expectEqualStrings("scene://hierarchy", stringField(params, "uri").?);
}
