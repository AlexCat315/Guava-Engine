const std = @import("std");
const core = @import("../core/layer.zig");
const protocol = @import("protocol.zig");
const resources_mod = @import("resources/mod.zig");

const EmptyObject = struct {};

pub const SyncLayer = struct {
    store: *resources_mod.SnapshotStore,
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

        try self.publish(layer_context);
    }

    fn publish(self: *SyncLayer, layer_context: *core.LayerContext) !void {
        layer_context.world.updateHierarchy();
        try self.store.replaceFromRenderer(layer_context.world, layer_context.renderer);
    }
};

pub fn spawn(store: *resources_mod.SnapshotStore, exit_requested: *std.atomic.Value(bool)) !std.Thread {
    const server = try std.heap.page_allocator.create(Server);
    errdefer std.heap.page_allocator.destroy(server);
    server.* = .{
        .store = store,
        .exit_requested = exit_requested,
    };

    return try std.Thread.spawn(.{}, serverMain, .{server});
}

const Server = struct {
    store: *resources_mod.SnapshotStore,
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
                "Read-only Week 1 MCP bridge for Guava Engine. Available resources: scene://hierarchy, selection://current, entity://{id}. Tools are intentionally empty in this phase.",
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
            try writeResult(stdout_file, id, .{
                .tools = &.{} ,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "prompts/list")) {
            try writeResult(stdout_file, id, .{
                .prompts = &.{} ,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/templates/list")) {
            try writeResult(stdout_file, id, .{
                .resourceTemplates = &.{} ,
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
