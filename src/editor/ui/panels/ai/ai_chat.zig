const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const ui_icons = @import("../../icons.zig");
const state_mod = @import("../../../core/state.zig");
const preferences = @import("../../../core/preferences.zig");
const i18n = @import("../../../i18n/mod.zig");
const EditorState = state_mod.EditorState;
const AiProviderType = state_mod.AiProviderType;

const ai_chat_log = std.log.scoped(.ai_chat);

const max_messages = 128;
const max_message_len = 2048;
const max_input_len = 1024;

pub const Role = enum {
    user,
    assistant,
    system,
};

pub const Message = struct {
    role: Role,
    text_len: usize = 0,
    text: [max_message_len]u8 = [_]u8{0} ** max_message_len,
    timestamp: i64 = 0,

    pub fn content(self: *const Message) []const u8 {
        return self.text[0..self.text_len];
    }
};

var g_messages: [max_messages]Message = undefined;
var g_message_count: usize = 0;
var g_input_buffer: [max_input_len]u8 = [_]u8{0} ** max_input_len;
var g_scroll_to_bottom: bool = false;
var g_connection_error: ?[]const u8 = null;
var g_meta_request_counter: u64 = 0;
var g_meta_session_id_len: usize = 0;
var g_meta_session_id_buffer: [64]u8 = [_]u8{0} ** 64;

const ProviderDefaults = struct {
    endpoint: []const u8,
    model: []const u8,
};

const provider_defaults: [4]ProviderDefaults = .{
    .{ .endpoint = "https://api.openai.com/v1/chat/completions", .model = "gpt-4o" },
    .{ .endpoint = "https://api.anthropic.com/v1/messages", .model = "claude-sonnet-4-20250514" },
    .{ .endpoint = "http://localhost:11434/api/chat", .model = "llama3.2" },
    .{ .endpoint = "", .model = "" },
};

const provider_types = [_]AiProviderType{
    .openai,
    .anthropic,
    .ollama,
    .custom,
};

const AsyncMessageRole = enum {
    assistant,
    system,
};

const AsyncResult = struct {
    role: AsyncMessageRole = .assistant,
    text: []u8,
    snapshot_dirty: bool = false,

    fn deinit(self: *AsyncResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

const AsyncTaskKind = enum {
    tool_command,
    prompt_intent,
};

const AsyncTaskContext = struct {
    kind: AsyncTaskKind,
    tool_name: ?[]u8 = null,
    raw_arguments: ?[]u8 = null,
    prompt: ?[]u8 = null,
    provider_type: AiProviderType = .openai,
    provider_endpoint: ?[]u8 = null,
    provider_model: ?[]u8 = null,
    provider_api_key: ?[]u8 = null,
    tool_bridge: ?*engine.mcp.tools.Bridge = null,
    collaboration_bridge: ?*engine.mcp.collaboration.Bridge = null,
    snapshot_store: ?*engine.mcp.resources.SnapshotStore = null,
    command_meta: engine.core.CommandMeta = .{},

    fn deinit(self: *AsyncTaskContext, allocator: std.mem.Allocator) void {
        if (self.tool_name) |value| allocator.free(value);
        if (self.raw_arguments) |value| allocator.free(value);
        if (self.prompt) |value| allocator.free(value);
        if (self.provider_endpoint) |value| allocator.free(value);
        if (self.provider_model) |value| allocator.free(value);
        if (self.provider_api_key) |value| allocator.free(value);
        self.command_meta.deinit(allocator);
        self.* = undefined;
    }
};

const AsyncState = struct {
    mutex: std.Thread.Mutex = .{},
    running: bool = false,
    result: ?AsyncResult = null,
};

var g_async_state: AsyncState = .{};

pub fn appendMessage(role: Role, text: []const u8) void {
    if (g_message_count >= max_messages) {
        for (0..max_messages - 1) |i| {
            g_messages[i] = g_messages[i + 1];
        }
        g_message_count = max_messages - 1;
    }
    var msg = &g_messages[g_message_count];
    msg.role = role;
    msg.text_len = @min(text.len, max_message_len);
    if (msg.text_len > 0) {
        @memcpy(msg.text[0..msg.text_len], text[0..msg.text_len]);
    }
    msg.timestamp = std.time.timestamp();
    g_message_count += 1;
    g_scroll_to_bottom = true;
}

pub fn clearHistory() void {
    g_message_count = 0;
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.result) |*result| {
        result.deinit(std.heap.page_allocator);
        g_async_state.result = null;
    }
    ai_chat_log.info("Chat history cleared", .{});
}

pub fn clearConnectionError() void {
    g_connection_error = null;
}

fn commandApprovalForTool(tool_name: []const u8) engine.core.CommandApprovalState {
    if (std.mem.eql(u8, tool_name, "stage_transaction")) return .previewed;
    if (std.mem.eql(u8, tool_name, "apply_staged_transaction")) return .user_approved;
    if (std.mem.eql(u8, tool_name, "discard_staged_transaction")) return .rejected;
    return .auto;
}

fn ensureMetaSessionId() []const u8 {
    if (g_meta_session_id_len != 0) {
        return g_meta_session_id_buffer[0..g_meta_session_id_len];
    }

    const timestamp = std.time.milliTimestamp();
    const generated = std.fmt.bufPrint(&g_meta_session_id_buffer, "ai-chat-{d}", .{timestamp}) catch {
        const fallback = "ai-chat";
        @memcpy(g_meta_session_id_buffer[0..fallback.len], fallback);
        g_meta_session_id_len = fallback.len;
        return g_meta_session_id_buffer[0..g_meta_session_id_len];
    };
    g_meta_session_id_len = generated.len;
    return g_meta_session_id_buffer[0..g_meta_session_id_len];
}

fn buildAiCommandMetaAlloc(
    allocator: std.mem.Allocator,
    tool_name: ?[]const u8,
    base_revision: ?u64,
) !engine.core.CommandMeta {
    g_meta_request_counter += 1;
    const request_id = g_meta_request_counter;
    const session_id = ensureMetaSessionId();

    var meta: engine.core.CommandMeta = .{};
    errdefer meta.deinit(allocator);

    meta.actor = try allocator.dupe(u8, "ai_chat");
    meta.client = try allocator.dupe(u8, "editor");
    meta.session = try allocator.dupe(u8, session_id);
    meta.request = try std.fmt.allocPrint(allocator, "req-{d}", .{request_id});
    meta.trace = if (tool_name) |resolved_tool_name|
        try std.fmt.allocPrint(allocator, "trace-{d}:{s}", .{ request_id, resolved_tool_name })
    else
        try std.fmt.allocPrint(allocator, "trace-{d}:intent", .{request_id});
    meta.approval = if (tool_name) |resolved_tool_name| commandApprovalForTool(resolved_tool_name) else .auto;
    meta.base_revision = base_revision;
    return meta;
}

fn deriveToolCommandMetaAlloc(
    allocator: std.mem.Allocator,
    base_meta: ?*const engine.core.CommandMeta,
    tool_name: []const u8,
) !engine.core.CommandMeta {
    if (base_meta) |resolved_base| {
        var meta = try resolved_base.cloneAlloc(allocator);
        errdefer meta.deinit(allocator);
        meta.approval = commandApprovalForTool(tool_name);
        if (meta.trace) |existing_trace| {
            allocator.free(existing_trace);
        }
        const request_text = meta.request orelse "req-0";
        meta.trace = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ request_text, tool_name });
        return meta;
    }
    return buildAiCommandMetaAlloc(allocator, tool_name, null);
}

fn providerTypeText(state: *const EditorState, provider_type: AiProviderType) []const u8 {
    return switch (provider_type) {
        .openai => state.text(.ai_chat_provider_type_openai),
        .anthropic => state.text(.ai_chat_provider_type_anthropic),
        .ollama => state.text(.ai_chat_provider_type_ollama),
        .custom => state.text(.ai_chat_provider_type_custom),
    };
}

fn providerDisplayNameForUi(state: *const EditorState, provider: *const state_mod.AiProviderConfig) []const u8 {
    const name = fixedBufferSlice(provider.name[0..]);
    if (name.len > 0) return name;
    return state.text(.ai_chat_provider_default_name);
}

fn applyProviderDefaults(state: *EditorState) void {
    const p = &state.ai_providers[state.ai_active_provider];
    const defaults = provider_defaults[@intFromEnum(state.ai_provider_type)];

    if (p.endpoint[0] == 0 and defaults.endpoint.len > 0) {
        @memcpy(p.endpoint[0..defaults.endpoint.len], defaults.endpoint);
        ai_chat_log.info("Applied default endpoint for {s}: {s}", .{ @tagName(state.ai_provider_type), defaults.endpoint });
    }
    if (p.model[0] == 0 and defaults.model.len > 0) {
        @memcpy(p.model[0..defaults.model.len], defaults.model);
        ai_chat_log.info("Applied default model for {s}: {s}", .{ @tagName(state.ai_provider_type), defaults.model });
    }
}

fn endpointPathSlice(endpoint: []const u8) []const u8 {
    if (std.mem.indexOf(u8, endpoint, "://")) |scheme_index| {
        const host_start = scheme_index + 3;
        if (std.mem.indexOfScalarPos(u8, endpoint, host_start, '/')) |path_start| {
            return endpoint[path_start..];
        }
        return "";
    }
    if (std.mem.indexOfScalar(u8, endpoint, '/')) |path_start| {
        return endpoint[path_start..];
    }
    return "";
}

fn normalizeProviderEndpointAlloc(provider_type: AiProviderType, endpoint_raw: []const u8) ![]u8 {
    const endpoint = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    if (endpoint.len == 0) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }

    const path = endpointPathSlice(endpoint);
    const already_targeted = switch (provider_type) {
        .openai, .custom => std.mem.indexOf(u8, path, "/chat/completions") != null,
        .anthropic => std.mem.indexOf(u8, path, "/messages") != null,
        .ollama => std.mem.indexOf(u8, path, "/api/chat") != null,
    };
    if (already_targeted) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }

    const should_append = switch (provider_type) {
        .openai, .custom => path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/v1") or std.mem.eql(u8, path, "/v1/"),
        .anthropic => path.len == 0 or std.mem.eql(u8, path, "/"),
        .ollama => path.len == 0 or std.mem.eql(u8, path, "/"),
    };
    if (!should_append) {
        return std.heap.page_allocator.dupe(u8, endpoint);
    }

    const base = std.mem.trimRight(u8, endpoint, "/");
    const suffix = switch (provider_type) {
        .openai, .custom => if (std.mem.endsWith(u8, base, "/v1")) "/chat/completions" else "/v1/chat/completions",
        .anthropic => "/v1/messages",
        .ollama => "/api/chat",
    };
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ base, suffix });
}

fn testHttpConnectionAlloc(
    provider_type: AiProviderType,
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
) ![]u8 {
    const endpoint_copy = try std.heap.page_allocator.dupe(u8, endpoint);
    defer std.heap.page_allocator.free(endpoint_copy);
    const model_copy = try std.heap.page_allocator.dupe(u8, model);
    defer std.heap.page_allocator.free(model_copy);
    const api_key_copy = try std.heap.page_allocator.dupe(u8, api_key);
    defer std.heap.page_allocator.free(api_key_copy);

    var task: AsyncTaskContext = .{
        .kind = .prompt_intent,
        .provider_type = provider_type,
        .provider_endpoint = endpoint_copy,
        .provider_model = model_copy,
        .provider_api_key = api_key_copy,
    };
    const probe = "Connection probe. Return {\"type\":\"message\",\"message\":\"pong\"}.";
    const completion = try requestProviderCompletionAlloc(&task, probe);
    defer std.heap.page_allocator.free(completion);

    const trimmed = std.mem.trim(u8, completion, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "Provider request failed")) {
        return std.heap.page_allocator.dupe(u8, trimmed);
    }
    return allocMessage(
        "Connection test succeeded. Provider replied: {s}",
        .{clipped(trimmed, 220)},
        "Connection test succeeded.",
    );
}

fn logProviderConfig(state: *EditorState) void {
    const p = &state.ai_providers[state.ai_active_provider];
    ai_chat_log.info("=== Provider Configuration ===", .{});
    ai_chat_log.info("Type: {s}", .{@tagName(state.ai_provider_type)});
    ai_chat_log.info("Name: {s}", .{providerDisplayNameForUi(state, p)});

    const endpoint_len = std.mem.indexOfScalar(u8, &p.endpoint, 0) orelse p.endpoint.len;
    const endpoint_slice = p.endpoint[0..endpoint_len];
    ai_chat_log.info("Endpoint: {s}", .{endpoint_slice});

    const model_len = std.mem.indexOfScalar(u8, &p.model, 0) orelse p.model.len;
    const model_slice = p.model[0..model_len];
    ai_chat_log.info("Model: {s}", .{model_slice});

    const apikey_len = std.mem.indexOfScalar(u8, &p.api_key, 0) orelse p.api_key.len;
    ai_chat_log.info("API Key length: {d} chars", .{apikey_len});
    ai_chat_log.info("============================", .{});
}

fn asyncTryBegin() bool {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.running) {
        return false;
    }
    g_async_state.running = true;
    return true;
}

fn asyncIsRunning() bool {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    return g_async_state.running;
}

fn asyncFinishWithoutResult() void {
    g_async_state.mutex.lock();
    g_async_state.running = false;
    g_async_state.mutex.unlock();
}

fn asyncPublishResult(result: AsyncResult) void {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    if (g_async_state.result) |*existing| {
        existing.deinit(std.heap.page_allocator);
    }
    g_async_state.result = result;
    g_async_state.running = false;
}

fn asyncTakeResult() ?AsyncResult {
    g_async_state.mutex.lock();
    defer g_async_state.mutex.unlock();
    const result = g_async_state.result;
    g_async_state.result = null;
    return result;
}

fn allocMessage(comptime fmt: []const u8, args: anytype, fallback: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch try std.heap.page_allocator.dupe(u8, fallback);
}

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..len];
}

fn isMcpBridgeReady(state: *const EditorState) bool {
    return state.ai_collaboration != null and state.ai_tool_bridge != null and state.ai_collaboration_bridge != null;
}

const ProviderValidationError = enum {
    endpoint_empty,
    model_empty,
    api_key_empty,
};

fn activeProviderValidationError(state: *const EditorState) ?ProviderValidationError {
    const provider = &state.ai_providers[state.ai_active_provider];
    const endpoint = fixedBufferSlice(provider.endpoint[0..]);
    const model = fixedBufferSlice(provider.model[0..]);
    const api_key = fixedBufferSlice(provider.api_key[0..]);

    if (endpoint.len == 0) return .endpoint_empty;
    if (model.len == 0) return .model_empty;
    if (state.ai_provider_type != .ollama and api_key.len == 0) return .api_key_empty;
    return null;
}

fn providerValidationErrorText(state: *const EditorState, validation_error: ProviderValidationError) []const u8 {
    return switch (validation_error) {
        .endpoint_empty => state.text(.ai_chat_validation_endpoint_empty),
        .model_empty => state.text(.ai_chat_validation_model_empty),
        .api_key_empty => state.text(.ai_chat_validation_api_key_empty),
    };
}

fn clipped(slice: []const u8, max_len: usize) []const u8 {
    return if (slice.len <= max_len) slice else slice[0..max_len];
}

const HttpJsonResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *HttpJsonResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

const LlmDecision = union(enum) {
    tool_call: struct {
        tool_name: []u8,
        arguments_json: ?[]u8 = null,
    },
    message: []u8,

    fn deinit(self: *LlmDecision, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_call => |*value| {
                allocator.free(value.tool_name);
                if (value.arguments_json) |arguments_json| {
                    allocator.free(arguments_json);
                }
            },
            .message => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

const llm_tool_system_prompt =
    \\You are Guava Engine's MCP tool planner.
    \\Return exactly one JSON object and nothing else (no markdown).
    \\Use one of:
    \\{"type":"mcp_tool_call","tool":"<tool_name>","arguments":{...}}
    \\{"type":"message","message":"<plain text reply>"}
    \\Prefer tool calls for actionable requests.
    \\Available tools:
    \\create_entity, delete_entity, rename_entity, set_parent, set_local_transform, set_world_transform, set_visible,
    \\query_entities, compile_script, compile_editor_utility, screenshot_png,
    \\stage_transaction, apply_staged_transaction, discard_staged_transaction.
    \\If arguments are not needed, omit "arguments".
;

fn stringifyJsonValueAlloc(value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try std.heap.page_allocator.dupe(u8, out.written());
}

fn readResourceTextAlloc(store: ?*engine.mcp.resources.SnapshotStore, uri: []const u8, max_len: usize) ![]u8 {
    const snapshot_store = store orelse return std.heap.page_allocator.dupe(u8, "{}");
    const content = snapshot_store.readAlloc(std.heap.page_allocator, uri) catch return std.heap.page_allocator.dupe(u8, "{}");
    if (content == null) {
        return std.heap.page_allocator.dupe(u8, "{}");
    }
    defer engine.mcp.resources.freeTextResourceContents(std.heap.page_allocator, content.?);
    return std.heap.page_allocator.dupe(u8, clipped(content.?.text, max_len));
}

fn buildImplicitContextAlloc(store: ?*engine.mcp.resources.SnapshotStore) ![]u8 {
    const selection = try readResourceTextAlloc(store, "selection://current", 2 * 1024);
    defer std.heap.page_allocator.free(selection);
    const context = try readResourceTextAlloc(store, "editor://context", 6 * 1024);
    defer std.heap.page_allocator.free(context);

    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "selection://current\n{s}\n\neditor://context\n{s}",
        .{ selection, context },
    );
}

fn httpPostJsonAlloc(
    endpoint: []const u8,
    payload: []const u8,
    extra_headers: []const std.http.Header,
) !HttpJsonResponse {
    var client = std.http.Client{ .allocator = std.heap.page_allocator };
    defer client.deinit();

    var response_out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer response_out.deinit();

    const fetch_result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = extra_headers,
        .response_writer = &response_out.writer,
    });

    return .{
        .status = fetch_result.status,
        .body = try std.heap.page_allocator.dupe(u8, response_out.written()),
    };
}

fn parseOpenAiContentAlloc(body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const choices_value = parsed.value.object.get("choices") orelse return error.InvalidProviderResponse;
    if (choices_value != .array or choices_value.array.items.len == 0) return error.InvalidProviderResponse;

    const choice = choices_value.array.items[0];
    if (choice != .object) return error.InvalidProviderResponse;

    const message_value = choice.object.get("message") orelse return error.InvalidProviderResponse;
    if (message_value != .object) return error.InvalidProviderResponse;

    const content_value = message_value.object.get("content") orelse return error.InvalidProviderResponse;
    switch (content_value) {
        .string => |content| return std.heap.page_allocator.dupe(u8, content),
        .array => |parts| {
            var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
            defer out.deinit();
            for (parts.items) |part| {
                switch (part) {
                    .string => |text| try out.writer.writeAll(text),
                    .object => |obj| {
                        if (obj.get("text")) |text_value| {
                            if (text_value == .string) {
                                try out.writer.writeAll(text_value.string);
                            }
                        }
                    },
                    else => {},
                }
            }
            if (out.written().len == 0) return error.InvalidProviderResponse;
            return std.heap.page_allocator.dupe(u8, out.written());
        },
        else => return error.InvalidProviderResponse,
    }
}

fn parseAnthropicContentAlloc(body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const content_value = parsed.value.object.get("content") orelse return error.InvalidProviderResponse;
    if (content_value != .array) return error.InvalidProviderResponse;

    var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    for (content_value.array.items) |item| {
        if (item != .object) continue;
        const type_value = item.object.get("type") orelse continue;
        if (type_value != .string) continue;
        if (!std.mem.eql(u8, type_value.string, "text")) continue;
        const text_value = item.object.get("text") orelse continue;
        if (text_value != .string) continue;
        try out.writer.writeAll(text_value.string);
    }
    if (out.written().len == 0) return error.InvalidProviderResponse;
    return std.heap.page_allocator.dupe(u8, out.written());
}

fn parseOllamaContentAlloc(body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidProviderResponse;
    const message_value = parsed.value.object.get("message") orelse return error.InvalidProviderResponse;
    if (message_value != .object) return error.InvalidProviderResponse;
    const content_value = message_value.object.get("content") orelse return error.InvalidProviderResponse;
    if (content_value != .string) return error.InvalidProviderResponse;
    return std.heap.page_allocator.dupe(u8, content_value.string);
}

fn parseProviderCompletionTextAlloc(provider_type: AiProviderType, body: []const u8) ![]u8 {
    return switch (provider_type) {
        .openai, .custom => parseOpenAiContentAlloc(body),
        .anthropic => parseAnthropicContentAlloc(body),
        .ollama => parseOllamaContentAlloc(body),
    };
}

fn requestProviderCompletionAlloc(task: *const AsyncTaskContext, prompt: []const u8) ![]u8 {
    const endpoint_raw = task.provider_endpoint orelse return error.MissingProviderEndpoint;
    const model = task.provider_model orelse return error.MissingProviderModel;
    const api_key = task.provider_api_key orelse "";
    const endpoint = try normalizeProviderEndpointAlloc(task.provider_type, endpoint_raw);
    defer std.heap.page_allocator.free(endpoint);

    const implicit_context = try buildImplicitContextAlloc(task.snapshot_store);
    defer std.heap.page_allocator.free(implicit_context);
    const user_prompt = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "User request:\n{s}\n\nEditor context:\n{s}\n\nReturn JSON only.",
        .{ prompt, implicit_context },
    );
    defer std.heap.page_allocator.free(user_prompt);

    const OpenAiMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    var response: HttpJsonResponse = switch (task.provider_type) {
        .openai, .custom => blk: {
            const RequestBody = struct {
                model: []const u8,
                temperature: f32 = 0.0,
                messages: []const OpenAiMessage,
            };
            const messages = [_]OpenAiMessage{
                .{ .role = "system", .content = llm_tool_system_prompt },
                .{ .role = "user", .content = user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = model,
                .messages = &messages,
            });
            defer std.heap.page_allocator.free(payload);

            if (api_key.len > 0) {
                const auth_value = try std.fmt.allocPrint(std.heap.page_allocator, "Bearer {s}", .{api_key});
                defer std.heap.page_allocator.free(auth_value);
                const headers = [_]std.http.Header{
                    .{ .name = "Authorization", .value = auth_value },
                };
                break :blk try httpPostJsonAlloc(endpoint, payload, &headers);
            }
            break :blk try httpPostJsonAlloc(endpoint, payload, &.{});
        },
        .anthropic => blk: {
            const AnthropicMessage = struct {
                role: []const u8,
                content: []const u8,
            };
            const RequestBody = struct {
                model: []const u8,
                max_tokens: u32 = 800,
                temperature: f32 = 0.0,
                system: []const u8,
                messages: []const AnthropicMessage,
            };
            const messages = [_]AnthropicMessage{
                .{ .role = "user", .content = user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = model,
                .system = llm_tool_system_prompt,
                .messages = &messages,
            });
            defer std.heap.page_allocator.free(payload);

            const headers = [_]std.http.Header{
                .{ .name = "x-api-key", .value = api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            };
            break :blk try httpPostJsonAlloc(endpoint, payload, &headers);
        },
        .ollama => blk: {
            const RequestBody = struct {
                model: []const u8,
                stream: bool = false,
                messages: []const OpenAiMessage,
            };
            const messages = [_]OpenAiMessage{
                .{ .role = "system", .content = llm_tool_system_prompt },
                .{ .role = "user", .content = user_prompt },
            };
            const payload = try stringifyJsonValueAlloc(RequestBody{
                .model = model,
                .messages = &messages,
            });
            defer std.heap.page_allocator.free(payload);
            break :blk try httpPostJsonAlloc(endpoint, payload, &.{});
        },
    };
    defer response.deinit(std.heap.page_allocator);

    if (response.status.class() != .success) {
        const phrase = response.status.phrase() orelse "HTTP Error";
        return allocMessage(
            "Provider request failed: HTTP {d} ({s})\n{s}",
            .{ @intFromEnum(response.status), phrase, clipped(response.body, 512) },
            "Provider request failed.",
        );
    }

    return parseProviderCompletionTextAlloc(task.provider_type, response.body);
}

fn stripCodeFence(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) {
        return trimmed;
    }

    const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    trimmed = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
    if (std.mem.endsWith(u8, trimmed, "```")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
    }
    return trimmed;
}

fn extractJsonCandidate(text: []const u8) []const u8 {
    const cleaned = stripCodeFence(text);
    if (cleaned.len == 0) return cleaned;
    if (cleaned[0] == '{') return cleaned;

    const start = std.mem.indexOfScalar(u8, cleaned, '{') orelse return cleaned;
    const end = std.mem.lastIndexOfScalar(u8, cleaned, '}') orelse return cleaned;
    if (end <= start) return cleaned;
    return cleaned[start .. end + 1];
}

fn parseLlmDecisionAlloc(raw_text: []const u8) !LlmDecision {
    const candidate = extractJsonCandidate(raw_text);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, candidate, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        return .{
            .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
        };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{
            .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
        };
    }

    const root = parsed.value.object;
    const type_value = root.get("type");
    const is_message = if (type_value) |value|
        value == .string and std.ascii.eqlIgnoreCase(value.string, "message")
    else
        false;

    if (!is_message) {
        const tool_field = root.get("tool") orelse root.get("name");
        if (tool_field != null and tool_field.? == .string and tool_field.?.string.len != 0) {
            const arguments_value = root.get("arguments");
            const arguments_json = if (arguments_value) |value|
                if (value == .null) null else try stringifyJsonValueAlloc(value)
            else
                null;
            return .{
                .tool_call = .{
                    .tool_name = try std.heap.page_allocator.dupe(u8, tool_field.?.string),
                    .arguments_json = arguments_json,
                },
            };
        }
    }

    if (root.get("message")) |value| {
        if (value == .string) {
            return .{
                .message = try std.heap.page_allocator.dupe(u8, value.string),
            };
        }
    }
    if (root.get("text")) |value| {
        if (value == .string) {
            return .{
                .message = try std.heap.page_allocator.dupe(u8, value.string),
            };
        }
    }

    return .{
        .message = try std.heap.page_allocator.dupe(u8, std.mem.trim(u8, raw_text, " \t\r\n")),
    };
}

fn touchImplicitContext(store: ?*engine.mcp.resources.SnapshotStore) void {
    const snapshot_store = store orelse return;

    const context = snapshot_store.readAlloc(std.heap.page_allocator, "editor://context") catch return;
    if (context) |resolved| {
        engine.mcp.resources.freeTextResourceContents(std.heap.page_allocator, resolved);
    }
}

fn executeToolCallAsync(
    tool_bridge: ?*engine.mcp.tools.Bridge,
    collaboration_bridge: ?*engine.mcp.collaboration.Bridge,
    tool_name: []const u8,
    raw_arguments: []const u8,
    command_meta: ?*const engine.core.CommandMeta,
) !AsyncResult {
    var parsed_args: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_args) |*parsed| parsed.deinit();

    const arguments_value: ?std.json.Value = blk: {
        if (raw_arguments.len == 0) {
            break :blk null;
        }
        parsed_args = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw_arguments, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            return .{
                .role = .system,
                .text = try std.heap.page_allocator.dupe(u8, "JSON parse failed. Example: /mcp query_entities {\"limit\":8}"),
            };
        };
        break :blk parsed_args.?.value;
    };

    var tool_meta = try deriveToolCommandMetaAlloc(std.heap.page_allocator, command_meta, tool_name);
    defer tool_meta.deinit(std.heap.page_allocator);

    if (engine.mcp.collaboration.isToolName(tool_name)) {
        const bridge = collaboration_bridge orelse {
            return .{
                .role = .system,
                .text = try std.heap.page_allocator.dupe(u8, "MCP collaboration bridge is not connected."),
            };
        };
        var response = bridge.submitJsonWithMeta(tool_name, arguments_value, &tool_meta) catch |err| {
            return .{
                .role = .system,
                .text = try allocMessage("MCP collaboration tool call failed: {s}", .{@errorName(err)}, "MCP collaboration tool call failed."),
            };
        };
        defer response.deinit(bridge.allocator);

        const summary = engine.mcp.collaboration.buildSummaryAlloc(std.heap.page_allocator, response) catch
            try std.heap.page_allocator.dupe(u8, "collaboration tool ok");
        return .{
            .role = .assistant,
            .text = summary,
            .snapshot_dirty = switch (response.outcome) {
                .applied => |result| result.had_transaction,
                else => false,
            },
        };
    }

    const bridge = tool_bridge orelse {
        return .{
            .role = .system,
            .text = try std.heap.page_allocator.dupe(u8, "MCP tool bridge is not connected."),
        };
    };
    var response = bridge.submitJsonWithMeta(tool_name, arguments_value, &tool_meta) catch |err| {
        return .{
            .role = .system,
            .text = try allocMessage("MCP tool call failed: {s}", .{@errorName(err)}, "MCP tool call failed."),
        };
    };
    defer response.deinit(bridge.allocator);

    const summary = engine.mcp.tools.buildSummaryAlloc(std.heap.page_allocator, response) catch
        try std.heap.page_allocator.dupe(u8, "tool ok");
    return .{
        .role = .assistant,
        .text = summary,
        .snapshot_dirty = switch (response.result.kind) {
            .command => response.result.changed,
            .compile_script, .compile_editor_utility => true,
            .screenshot, .query => false,
        },
    };
}

fn executePromptIntentAsync(task: *const AsyncTaskContext) !AsyncResult {
    const prompt = task.prompt orelse "";
    touchImplicitContext(task.snapshot_store);

    const completion = requestProviderCompletionAlloc(task, prompt) catch |err| {
        return .{
            .role = .system,
            .text = try allocMessage("Provider request failed: {s}", .{@errorName(err)}, "Provider request failed."),
        };
    };
    defer std.heap.page_allocator.free(completion);

    var decision = try parseLlmDecisionAlloc(completion);
    defer decision.deinit(std.heap.page_allocator);

    return switch (decision) {
        .tool_call => |tool_call| executeToolCallAsync(
            task.tool_bridge,
            task.collaboration_bridge,
            tool_call.tool_name,
            if (tool_call.arguments_json) |arguments_json| arguments_json else "",
            &task.command_meta,
        ),
        .message => |message| .{
            .role = if (std.mem.startsWith(u8, std.mem.trim(u8, message, " \t\r\n"), "Provider request failed"))
                .system
            else
                .assistant,
            .text = try std.heap.page_allocator.dupe(u8, message),
        },
    };
}

fn runAsyncTaskMain(context: ?*anyopaque) void {
    const raw = context orelse {
        asyncFinishWithoutResult();
        return;
    };
    const task: *AsyncTaskContext = @ptrCast(@alignCast(raw));
    defer {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
    }

    const result = switch (task.kind) {
        .tool_command => executeToolCallAsync(
            task.tool_bridge,
            task.collaboration_bridge,
            task.tool_name orelse "",
            task.raw_arguments orelse "",
            &task.command_meta,
        ) catch |err| blk: {
            const text = allocMessage("AI background task failed: {s}", .{@errorName(err)}, "AI background task failed.") catch {
                asyncFinishWithoutResult();
                return;
            };
            break :blk AsyncResult{ .role = .system, .text = text };
        },
        .prompt_intent => executePromptIntentAsync(task) catch |err| blk: {
            const text = allocMessage("AI intent parse failed: {s}", .{@errorName(err)}, "AI intent parse failed.") catch {
                asyncFinishWithoutResult();
                return;
            };
            break :blk AsyncResult{ .role = .system, .text = text };
        },
    };
    asyncPublishResult(result);
}

fn runAsyncTaskCleanup(context: ?*anyopaque) void {
    if (context) |raw| {
        const task: *AsyncTaskContext = @ptrCast(@alignCast(raw));
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
    }
    asyncFinishWithoutResult();
}

fn startAsyncTask(layer_context: *engine.core.LayerContext, task: *AsyncTaskContext) bool {
    const job_system = layer_context.world.job_system orelse return false;
    if (!asyncTryBegin()) {
        return false;
    }

    var handle = job_system.enqueueWithCleanup(
        runAsyncTaskMain,
        task,
        runAsyncTaskCleanup,
        .normal,
    ) catch {
        asyncFinishWithoutResult();
        return false;
    };
    handle.deinit();
    return true;
}

fn pumpAsyncResults(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var maybe_result = asyncTakeResult();
    if (maybe_result) |*result| {
        defer result.deinit(std.heap.page_allocator);
        switch (result.role) {
            .assistant => appendMessage(.assistant, result.text),
            .system => appendMessage(.system, result.text),
        }
        if (result.snapshot_dirty) {
            refreshMcpSnapshot(state, layer_context);
        }
    }
}

const ToolCommand = struct {
    name: []const u8,
    raw_arguments: []const u8,
};

fn parseToolCommand(input: []const u8) ?ToolCommand {
    if (!std.mem.startsWith(u8, input, "/mcp")) {
        return null;
    }

    var rest = std.mem.trimLeft(u8, input["/mcp".len..], " \t");
    if (rest.len == 0) {
        return null;
    }
    const tool_end = std.mem.indexOfAny(u8, rest, " \t");
    if (tool_end) |index| {
        return .{
            .name = rest[0..index],
            .raw_arguments = std.mem.trim(u8, rest[index..], " \t"),
        };
    }
    return .{
        .name = rest,
        .raw_arguments = "",
    };
}

fn refreshMcpSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const store = state.ai_snapshot_store orelse return;
    layer_context.world.updateHierarchy();
    store.replaceFromRenderer(layer_context.world, layer_context.renderer) catch |err| {
        ai_chat_log.warn("failed to refresh MCP snapshot after chat tool call: {s}", .{@errorName(err)});
    };
}

fn handleMcpToolCommandImmediate(state: *EditorState, layer_context: *engine.core.LayerContext, command: ToolCommand) bool {
    if (command.name.len == 0) {
        appendMessage(.system, state.text(.ai_chat_missing_tool_name_example));
        return true;
    }

    var parsed_args: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_args) |*parsed| parsed.deinit();

    const args_value: ?std.json.Value = blk: {
        if (command.raw_arguments.len == 0) {
            break :blk null;
        }
        parsed_args = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, command.raw_arguments, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            appendMessage(.system, state.text(.ai_chat_json_parse_failed_example));
            return true;
        };
        break :blk parsed_args.?.value;
    };

    var command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        command.name,
        layer_context.world.sceneRevision(),
    ) catch {
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return true;
    };
    defer command_meta.deinit(std.heap.page_allocator);

    if (engine.mcp.collaboration.isToolName(command.name)) {
        const bridge = state.ai_collaboration_bridge orelse {
            appendMessage(.system, state.text(.ai_chat_disconnected));
            return true;
        };
        var outcome = bridge.executeJsonImmediateWithMeta(layer_context, command.name, args_value, &command_meta) catch |err| {
            var message_buffer: [160]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s}: {s}",
                .{ state.text(.ai_chat_collaboration_tool_call_failed_fallback), @errorName(err) },
            ) catch state.text(.ai_chat_collaboration_tool_call_failed_fallback);
            appendMessage(.system, message);
            return true;
        };
        defer outcome.response.deinit(bridge.allocator);

        const summary = engine.mcp.collaboration.buildSummaryAlloc(std.heap.page_allocator, outcome.response) catch null;
        if (summary) |resolved_summary| {
            defer std.heap.page_allocator.free(resolved_summary);
            appendMessage(.assistant, resolved_summary);
        } else {
            appendMessage(.assistant, state.text(.ai_chat_collaboration_tool_ok));
        }

        if (outcome.world_changed) {
            refreshMcpSnapshot(state, layer_context);
        }
        return true;
    }

    const bridge = state.ai_tool_bridge orelse {
        appendMessage(.system, state.text(.ai_chat_disconnected));
        return true;
    };
    var outcome = bridge.executeJsonImmediateWithMeta(layer_context, command.name, args_value, &command_meta) catch |err| {
        var message_buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "{s}: {s}",
            .{ state.text(.ai_chat_tool_call_failed_fallback), @errorName(err) },
        ) catch state.text(.ai_chat_tool_call_failed_fallback);
        appendMessage(.system, message);
        return true;
    };
    defer outcome.response.deinit(bridge.allocator);

    const summary = engine.mcp.tools.buildSummaryAlloc(std.heap.page_allocator, outcome.response) catch null;
    if (summary) |resolved_summary| {
        defer std.heap.page_allocator.free(resolved_summary);
        appendMessage(.assistant, resolved_summary);
    } else {
        appendMessage(.assistant, state.text(.ai_chat_tool_ok));
    }

    if (outcome.snapshot_dirty) {
        refreshMcpSnapshot(state, layer_context);
    }
    return true;
}

fn enqueueToolCommand(state: *EditorState, layer_context: *engine.core.LayerContext, command: ToolCommand) bool {
    if (command.name.len == 0) {
        appendMessage(.system, state.text(.ai_chat_missing_tool_name_example));
        return true;
    }

    const task = std.heap.page_allocator.create(AsyncTaskContext) catch {
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    };
    task.* = .{
        .kind = .tool_command,
        .tool_bridge = state.ai_tool_bridge,
        .collaboration_bridge = state.ai_collaboration_bridge,
        .snapshot_store = state.ai_snapshot_store,
    };
    task.tool_name = std.heap.page_allocator.dupe(u8, command.name) catch {
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_tool_name));
        return false;
    };
    task.raw_arguments = std.heap.page_allocator.dupe(u8, command.raw_arguments) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_arguments));
        return false;
    };
    task.command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        command.name,
        layer_context.world.sceneRevision(),
    ) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return false;
    };

    if (!startAsyncTask(layer_context, task)) {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        return false;
    }
    return true;
}

fn enqueuePromptIntent(state: *EditorState, layer_context: *engine.core.LayerContext, input_text: []const u8) bool {
    applyProviderDefaults(state);
    if (activeProviderValidationError(state)) |validation_error| {
        const validation_error_text = providerValidationErrorText(state, validation_error);
        var message_buffer: [384]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "{s} {s} ({s})",
            .{
                state.text(.ai_chat_provider_setup_incomplete_prefix),
                state.text(.ai_chat_provider_setup_open_config_hint),
                validation_error_text,
            },
        ) catch state.text(.ai_chat_provider_setup_incomplete_prefix);
        appendMessage(.system, message);
        state.ai_provider_settings_open = true;
        return false;
    }
    const provider = &state.ai_providers[state.ai_active_provider];
    const endpoint = fixedBufferSlice(provider.endpoint[0..]);
    const model = fixedBufferSlice(provider.model[0..]);
    const api_key = fixedBufferSlice(provider.api_key[0..]);

    const task = std.heap.page_allocator.create(AsyncTaskContext) catch {
        appendMessage(.system, state.text(.ai_chat_failed_create_background_task));
        return false;
    };
    task.* = .{
        .kind = .prompt_intent,
        .provider_type = state.ai_provider_type,
        .tool_bridge = state.ai_tool_bridge,
        .collaboration_bridge = state.ai_collaboration_bridge,
        .snapshot_store = state.ai_snapshot_store,
    };

    task.prompt = std.heap.page_allocator.dupe(u8, input_text) catch {
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_input));
        return false;
    };
    task.provider_endpoint = std.heap.page_allocator.dupe(u8, endpoint) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_endpoint));
        return false;
    };
    task.provider_model = std.heap.page_allocator.dupe(u8, model) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_model));
        return false;
    };
    task.provider_api_key = std.heap.page_allocator.dupe(u8, api_key) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_failed_allocate_api_key));
        return false;
    };
    task.command_meta = buildAiCommandMetaAlloc(
        std.heap.page_allocator,
        null,
        layer_context.world.sceneRevision(),
    ) catch {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        appendMessage(.system, state.text(.ai_chat_meta_alloc_failed));
        return false;
    };

    if (!startAsyncTask(layer_context, task)) {
        task.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(task);
        return false;
    }
    return true;
}

fn submitInput(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    pumpAsyncResults(state, layer_context);

    if (asyncIsRunning()) {
        appendMessage(.system, state.text(.ai_chat_previous_request_running));
        return;
    }

    const input_len = std.mem.indexOfScalar(u8, &g_input_buffer, 0) orelse max_input_len;
    if (input_len == 0) return;

    const input_text = std.mem.trim(u8, g_input_buffer[0..input_len], " \t\r\n");
    if (input_text.len == 0) {
        @memset(&g_input_buffer, 0);
        return;
    }
    ai_chat_log.info("User input: {s}", .{input_text});
    appendMessage(.user, input_text);

    if (parseToolCommand(input_text)) |command| {
        refreshMcpSnapshot(state, layer_context);
        if (!enqueueToolCommand(state, layer_context, command)) {
            _ = handleMcpToolCommandImmediate(state, layer_context, command);
        }
    } else if (isMcpBridgeReady(state)) {
        const store = state.ai_collaboration.?;
        store.recordIntent(.human, "chat_prompt", input_text) catch {};
        refreshMcpSnapshot(state, layer_context);
        _ = enqueuePromptIntent(state, layer_context, input_text);
    } else {
        appendMessage(.system, state.text(.ai_chat_mcp_local_bridge_not_ready));
    }

    @memset(&g_input_buffer, 0);
}

fn drawHeaderBar(state: *EditorState) void {
    const full_width = gui.contentRegionAvail()[0];
    const mcp_ready = isMcpBridgeReady(state);
    const provider_error = activeProviderValidationError(state);
    const provider_ready = provider_error == null;
    const dot_color: [4]f32 = if (!mcp_ready)
        .{ 0.80, 0.28, 0.28, 1.0 }
    else if (!provider_ready)
        .{ 0.95, 0.80, 0.30, 1.0 }
    else
        .{ 0.22, 0.82, 0.46, 1.0 };

    gui.pushStyleColor(.text, dot_color);
    gui.text("●");
    gui.popStyleColor(1);
    gui.sameLine();

    if (!mcp_ready) {
        gui.pushStyleColor(.text, .{ 0.85, 0.35, 0.35, 1.0 });
        gui.text(state.text(.ai_chat_mcp_not_ready));
        gui.popStyleColor(1);
    } else {
        gui.pushStyleColor(.text, .{ 0.60, 0.68, 0.80, 1.0 });
        gui.text(state.text(.ai_chat_mcp_ready_builtin));
        gui.popStyleColor(1);

        gui.sameLine();
        gui.pushStyleColor(.text, .{ 0.42, 0.46, 0.52, 1.0 });
        gui.text("|");
        gui.popStyleColor(1);
        gui.sameLine();

        if (provider_ready) {
            gui.pushStyleColor(.text, .{ 0.48, 0.82, 0.60, 1.0 });
            gui.text(state.text(.ai_chat_provider_configured));
            gui.popStyleColor(1);
        } else {
            gui.pushStyleColor(.text, .{ 0.95, 0.80, 0.30, 1.0 });
            gui.text(state.text(.ai_chat_provider_not_configured));
            gui.popStyleColor(1);
            if (provider_error) |validation_error| {
                gui.sameLine();
                gui.pushStyleColor(.text, .{ 0.58, 0.62, 0.70, 1.0 });
                gui.text(providerValidationErrorText(state, validation_error));
                gui.popStyleColor(1);
            }
        }

        if (provider_ready) {
            if (state.ai_collaboration) |store| {
                gui.sameLine();
                gui.pushStyleColor(.text, .{ 0.42, 0.46, 0.52, 1.0 });
                gui.text("|");
                gui.popStyleColor(1);
                gui.sameLine();

                if (asyncIsRunning()) {
                    gui.pushStyleColor(.text, .{ 0.95, 0.80, 0.30, 1.0 });
                    gui.text(state.text(.ai_chat_running));
                    gui.popStyleColor(1);
                } else {
                    const ai_status = store.aiStatusSnapshot();
                    const stage_label = switch (ai_status.stage) {
                        .ready => state.text(.ai_chat_stage_ready),
                        .analyzing_screenshot => state.text(.ai_chat_stage_analyzing_screenshot),
                        .compiling_shader => state.text(.ai_chat_stage_compiling_shader),
                        .waiting_approval => state.text(.ai_chat_stage_waiting_approval),
                    };
                    const stage_color: [4]f32 = switch (ai_status.stage) {
                        .ready => .{ 0.55, 0.62, 0.70, 1.0 },
                        .analyzing_screenshot, .compiling_shader => .{ 0.95, 0.80, 0.30, 1.0 },
                        .waiting_approval => .{ 0.95, 0.55, 0.20, 1.0 },
                    };
                    gui.pushStyleColor(.text, stage_color);
                    gui.text(stage_label);
                    gui.popStyleColor(1);
                }
            }
        }
    }

    const clear_w: f32 = 44.0;
    const config_w: f32 = 58.0;
    const btn_gap: f32 = 6.0;
    const total_btns = clear_w + config_w + btn_gap;
    if (full_width > total_btns + 80.0) {
        gui.sameLineEx(full_width - total_btns, 0.0);
        gui.pushStyleColor(.button, .{ 0.18, 0.20, 0.24, 0.0 });
        gui.pushStyleColor(.button_hovered, .{ 0.26, 0.29, 0.34, 0.90 });
        gui.pushStyleColor(.button_active, .{ 0.20, 0.22, 0.27, 1.0 });
        if (gui.buttonEx(state.text(.ai_chat_clear), clear_w, 0.0)) {
            clearHistory();
        }
        gui.sameLine();
        if (gui.buttonEx(state.text(.ai_chat_configure), config_w, 0.0)) {
            state.ai_provider_settings_open = !state.ai_provider_settings_open;
            ai_chat_log.info("Provider settings panel toggled: {s}", .{if (state.ai_provider_settings_open) "open" else "closed"});
        }
        gui.popStyleColor(3);
    }
}

fn drawStagedTransactionBanner(state: *EditorState) void {
    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();
    if (ai_status.stage != .waiting_approval) return;

    gui.dummy(0.0, 2.0);
    gui.pushStyleColor(.text, .{ 0.98, 0.85, 0.40, 1.0 });
    gui.text(state.text(.ai_chat_staged_banner));
    gui.popStyleColor(1);
    gui.pushStyleColor(.text, .{ 0.68, 0.72, 0.80, 1.0 });
    gui.text(state.text(.ai_chat_staged_hint));
    gui.popStyleColor(1);
    gui.dummy(0.0, 2.0);
}

fn drawStageDetail(state: *EditorState) void {
    if (asyncIsRunning()) {
        gui.pushStyleColor(.text, .{ 0.58, 0.65, 0.75, 1.0 });
        gui.textWrapped(state.text(.ai_chat_background_job_running));
        gui.popStyleColor(1);
        return;
    }

    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();
    if (ai_status.stage == .ready) return;

    const detail = if (ai_status.detail.len > 0)
        ai_status.detail.slice()
    else
        return;

    ai_chat_log.debug("AI stage detail: {s}", .{detail});
    gui.pushStyleColor(.text, .{ 0.58, 0.65, 0.75, 1.0 });
    gui.textWrapped(detail);
    gui.popStyleColor(1);
}

fn drawMessages(state: *EditorState) void {
    if (g_message_count == 0) {
        gui.dummy(0.0, 8.0);
        gui.pushStyleColor(.text, .{ 0.38, 0.40, 0.44, 1.0 });
        gui.textWrapped(state.text(.ai_chat_empty));
        gui.popStyleColor(1);
        return;
    }

    for (0..g_message_count) |i| {
        const msg = &g_messages[i];
        const content_text = msg.content();
        if (content_text.len == 0) continue;

        switch (msg.role) {
            .user => {
                gui.pushStyleColor(.text, .{ 0.60, 0.68, 0.80, 0.72 });
                gui.text(state.text(.ai_chat_role_you));
                gui.popStyleColor(1);
                gui.pushStyleColor(.text, .{ 0.88, 0.92, 0.98, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
            .assistant => {
                gui.pushStyleColor(.text, .{ 0.22, 0.82, 0.52, 0.80 });
                gui.text(state.text(.ai_chat_role_assistant));
                gui.popStyleColor(1);
                gui.pushStyleColor(.text, .{ 0.78, 0.94, 0.82, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
            .system => {
                gui.pushStyleColor(.text, .{ 0.46, 0.48, 0.52, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
        }

        if (i + 1 < g_message_count) {
            gui.dummy(0.0, 2.0);
            gui.separator();
            gui.dummy(0.0, 2.0);
        }
    }
}

const provider_action_icon_size: f32 = 16.0;

fn providerActionPalette(enabled: bool) ui_icons.ButtonPalette {
    if (!enabled) {
        return .{
            .button = .{ 0.16, 0.18, 0.21, 0.38 },
            .hovered = .{ 0.16, 0.18, 0.21, 0.38 },
            .active = .{ 0.16, 0.18, 0.21, 0.38 },
        };
    }
    return .{
        .button = .{ 0.22, 0.24, 0.27, 1.0 },
        .hovered = .{ 0.30, 0.33, 0.37, 1.0 },
        .active = .{ 0.30, 0.33, 0.37, 1.0 },
    };
}

fn providerActionTint(enabled: bool) [4]u8 {
    if (!enabled) return .{ 110, 115, 124, 255 };
    return .{ 220, 228, 236, 255 };
}

fn drawProviderActionIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    enabled: bool,
) !bool {
    const clicked = try ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        provider_action_icon_size,
        providerActionTint(enabled),
        providerActionPalette(enabled),
    );
    return clicked and enabled;
}

fn pushAiInputWidgetStyle() void {
    gui.pushStyleColor(.frame_bg, .{ 0.07, 0.09, 0.13, 1.0 });
    gui.pushStyleColor(.frame_bg_hovered, .{ 0.10, 0.13, 0.18, 1.0 });
    gui.pushStyleColor(.frame_bg_active, .{ 0.13, 0.17, 0.24, 1.0 });
    gui.pushStyleColor(.border, .{ 0.22, 0.44, 0.38, 0.90 });
    gui.pushStyleColor(.text, .{ 0.94, 0.96, 0.99, 1.0 });
    gui.pushStyleColor(.input_text_cursor, .{ 0.24, 0.92, 0.56, 1.0 });
    gui.pushStyleColor(.nav_cursor, .{ 0.30, 0.88, 0.67, 1.0 });
    gui.pushStyleColor(.text_selected_bg, .{ 0.22, 0.72, 0.56, 0.45 });
    gui.pushStyleVarFloat(.frame_rounding, 7.0);
}

fn popAiInputWidgetStyle() void {
    gui.popStyleVar(1);
    gui.popStyleColor(8);
}

fn inputTextWithHintStyledFlags(label: []const u8, hint: []const u8, buffer: []u8, flags: u32) bool {
    pushAiInputWidgetStyle();
    defer popAiInputWidgetStyle();
    return gui.inputTextWithHintFlags(label, hint, buffer, flags);
}

fn inputTextWithHintStyled(label: []const u8, hint: []const u8, buffer: []u8) bool {
    return inputTextWithHintStyledFlags(label, hint, buffer, gui.InputTextFlags.none);
}

fn inputTextPasswordStyled(label: []const u8, buffer: []u8) bool {
    pushAiInputWidgetStyle();
    defer popAiInputWidgetStyle();
    return gui.inputTextPassword(label, buffer);
}

fn drawProviderSettings(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.ai_provider_settings_open) return;
    var provider_prefs_dirty = false;

    gui.separator();
    _ = gui.beginChild("ai_provider_settings##jt", 0.0, 320.0, true);
    defer gui.endChild();

    gui.pushStyleColor(.text, .{ 0.78, 0.83, 0.92, 1.0 });
    gui.text(state.text(.ai_chat_provider_settings_title));
    gui.popStyleColor(1);
    gui.pushStyleColor(.text, .{ 0.52, 0.57, 0.66, 1.0 });
    gui.textWrapped(state.text(.ai_chat_provider_settings_desc));
    gui.popStyleColor(1);
    gui.dummy(0.0, 2.0);

    const mcp_ready = isMcpBridgeReady(state);
    if (mcp_ready) {
        gui.pushStyleColor(.text, .{ 0.48, 0.82, 0.60, 1.0 });
        gui.text(state.text(.ai_chat_provider_status_ready_builtin));
        gui.popStyleColor(1);
    } else {
        gui.pushStyleColor(.text, .{ 0.85, 0.35, 0.35, 1.0 });
        gui.text(state.text(.ai_chat_provider_status_not_ready));
        gui.popStyleColor(1);
    }

    if (activeProviderValidationError(state)) |validation_error| {
        const validation_error_text = providerValidationErrorText(state, validation_error);
        gui.pushStyleColor(.text, .{ 0.95, 0.80, 0.30, 1.0 });
        gui.text(state.text(.ai_chat_provider_not_configured));
        var provider_status_reason_buffer: [192]u8 = undefined;
        const provider_status_reason = std.fmt.bufPrint(
            &provider_status_reason_buffer,
            " ({s})",
            .{validation_error_text},
        ) catch "";
        if (provider_status_reason.len > 0) {
            gui.sameLine();
            gui.text(provider_status_reason);
        }
        gui.popStyleColor(1);
    } else {
        gui.pushStyleColor(.text, .{ 0.48, 0.82, 0.60, 1.0 });
        gui.text(state.text(.ai_chat_provider_status_configured));
        gui.popStyleColor(1);
    }
    gui.dummy(0.0, 4.0);

    const avail_w = gui.contentRegionAvail()[0];
    const action_gap: f32 = 4.0;
    const action_btn_span = provider_action_icon_size + ui_icons.compact_icon_button_padding[0] * 2.0;
    const type_preview_w = @max(120.0, avail_w - action_btn_span * 3.0 - action_gap * 3.0);
    const type_popup_id = "ai_provider_type_popup##jt";

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_type));
    gui.popStyleColor(1);

    const active_type = state.ai_provider_type;
    var type_preview_label_buffer: [96]u8 = undefined;
    const type_preview_label = std.fmt.bufPrint(
        &type_preview_label_buffer,
        "{s}##ai_provider_type_preview",
        .{providerTypeText(state, active_type)},
    ) catch "Type##ai_provider_type_preview";
    gui.pushStyleColor(.button, .{ 0.10, 0.12, 0.17, 1.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.13, 0.16, 0.22, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.15, 0.19, 0.26, 1.0 });
    if (gui.buttonEx(type_preview_label, type_preview_w, 0.0)) {
        gui.openPopup(type_popup_id);
    }
    gui.popStyleColor(3);

    gui.sameLine();
    if (try drawProviderActionIconButton(
        state,
        layer_context,
        "ai_provider_type_open##jt",
        ui_icons.paths.toolbar.chevron_down,
        true,
    )) {
        gui.openPopup(type_popup_id);
    }

    gui.sameLine();
    if (try drawProviderActionIconButton(
        state,
        layer_context,
        "ai_provider_type_add##jt",
        ui_icons.paths.toolbar.plus,
        true,
    )) {
        if (state.ai_provider_count < state.ai_providers.len) {
            const new_provider_index = state.ai_provider_count;
            state.ai_providers[new_provider_index] = .{};
            var allocated_default_name: ?[]u8 = null;
            const default_name = blk: {
                const resolved = i18n.allocPrintMessage(
                    .ai_chat_provider_default_name_fmt,
                    std.heap.page_allocator,
                    state.language,
                    .{new_provider_index + 1},
                ) catch break :blk state.text(.ai_chat_provider_default_name);
                allocated_default_name = resolved;
                break :blk resolved;
            };
            defer if (allocated_default_name) |value| {
                std.heap.page_allocator.free(value);
            };
            const name_buffer = state.ai_providers[new_provider_index].name[0..];
            const copy_len = @min(name_buffer.len - 1, default_name.len);
            @memcpy(name_buffer[0..copy_len], default_name[0..copy_len]);

            state.ai_active_provider = new_provider_index;
            state.ai_provider_count += 1;
            applyProviderDefaults(state);
            ai_chat_log.info("Added new provider, total: {d}", .{state.ai_provider_count});
            provider_prefs_dirty = true;
        }
    }

    gui.sameLine();
    const can_delete = state.ai_provider_count > 1;
    const did_delete = try drawProviderActionIconButton(
        state,
        layer_context,
        "ai_provider_type_delete##jt",
        ui_icons.paths.toolbar.x_mark,
        can_delete,
    );
    if (did_delete and can_delete) {
        var i = state.ai_active_provider;
        while (i + 1 < state.ai_provider_count) : (i += 1) {
            state.ai_providers[i] = state.ai_providers[i + 1];
        }
        state.ai_provider_count -= 1;
        if (state.ai_active_provider >= state.ai_provider_count) {
            state.ai_active_provider = state.ai_provider_count - 1;
        }
        ai_chat_log.info("Deleted provider, remaining: {d}", .{state.ai_provider_count});
        provider_prefs_dirty = true;
    }

    if (gui.beginPopup(type_popup_id)) {
        defer gui.endPopup();
        for (provider_types, 0..) |provider_type, i| {
            gui.pushIdU64(@intCast(i));
            defer gui.popId();
            const is_selected = provider_type == active_type;
            if (gui.selectable(providerTypeText(state, provider_type), is_selected, false, 0.0, 0.0)) {
                state.ai_provider_type = provider_type;
                ai_chat_log.info("Provider type changed to: {s}", .{@tagName(provider_type)});
                applyProviderDefaults(state);
                provider_prefs_dirty = true;
            }
            if (is_selected) gui.setItemDefaultFocus();
        }
    }

    gui.dummy(0.0, 6.0);
    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_provider_list));
    gui.popStyleColor(1);

    const active_provider = &state.ai_providers[state.ai_active_provider];
    const provider_popup_id = "ai_provider_select_popup##jt";
    const provider_preview_w = @max(120.0, avail_w - action_btn_span - action_gap);
    var provider_preview_label_buffer: [160]u8 = undefined;
    const provider_preview_label = std.fmt.bufPrint(
        &provider_preview_label_buffer,
        "{s}##ai_provider_select_preview",
        .{providerDisplayNameForUi(state, active_provider)},
    ) catch "Provider##ai_provider_select_preview";
    gui.pushStyleColor(.button, .{ 0.10, 0.12, 0.17, 1.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.13, 0.16, 0.22, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.15, 0.19, 0.26, 1.0 });
    if (gui.buttonEx(provider_preview_label, provider_preview_w, 0.0)) {
        gui.openPopup(provider_popup_id);
    }
    gui.popStyleColor(3);

    gui.sameLine();
    if (try drawProviderActionIconButton(
        state,
        layer_context,
        "ai_provider_select_open##jt",
        ui_icons.paths.toolbar.chevron_down,
        true,
    )) {
        gui.openPopup(provider_popup_id);
    }

    if (gui.beginPopup(provider_popup_id)) {
        defer gui.endPopup();
        for (0..state.ai_provider_count) |provider_index| {
            gui.pushIdU64(@intCast(provider_index));
            defer gui.popId();
            const is_selected = provider_index == state.ai_active_provider;
            const provider_item = &state.ai_providers[provider_index];
            if (gui.selectable(providerDisplayNameForUi(state, provider_item), is_selected, false, 0.0, 0.0)) {
                state.ai_active_provider = provider_index;
                provider_prefs_dirty = true;
            }
            if (is_selected) gui.setItemDefaultFocus();
        }
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    gui.pushIdU64(@intCast(state.ai_active_provider));
    defer gui.popId();

    const p = &state.ai_providers[state.ai_active_provider];

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_display_name));
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    if (inputTextWithHintStyled("##name", state.text(.ai_chat_hint_provider_name), p.name[0..])) {
        provider_prefs_dirty = true;
    }

    gui.dummy(0.0, 4.0);

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_api_endpoint));
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    if (inputTextWithHintStyled("##endpoint", state.text(.ai_chat_hint_endpoint), p.endpoint[0..])) {
        provider_prefs_dirty = true;
    }
    gui.dummy(0.0, 4.0);

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_model));
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    if (inputTextWithHintStyled("##model", state.text(.ai_chat_hint_model), p.model[0..])) {
        provider_prefs_dirty = true;
    }

    gui.dummy(0.0, 4.0);

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text(state.text(.ai_chat_api_key));
    gui.popStyleColor(1);
    const toggle_w: f32 = 50.0;
    const key_gap: f32 = 6.0;
    gui.setNextItemWidth(gui.contentRegionAvail()[0] - toggle_w - key_gap);
    if (state.ai_provider_api_key_visible) {
        if (inputTextWithHintStyled("##apikey", state.text(.ai_chat_hint_api_key), p.api_key[0..])) {
            provider_prefs_dirty = true;
        }
    } else {
        if (inputTextPasswordStyled("##apikey", p.api_key[0..])) {
            provider_prefs_dirty = true;
        }
    }
    gui.sameLine();
    if (gui.buttonEx(if (state.ai_provider_api_key_visible) state.text(.ai_chat_hide) else state.text(.ai_chat_show), toggle_w, 0.0)) {
        state.ai_provider_api_key_visible = !state.ai_provider_api_key_visible;
    }

    gui.dummy(0.0, 12.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    const apply_btn_w: f32 = 100.0;
    const test_btn_w: f32 = 70.0;
    const btn_row_w = apply_btn_w + test_btn_w + 8.0;
    const btn_row_x = (avail_w - btn_row_w) * 0.5;
    gui.sameLineEx(btn_row_x, 0.0);

    gui.pushStyleColor(.button, .{ 0.13, 0.50, 0.36, 0.88 });
    gui.pushStyleColor(.button_hovered, .{ 0.15, 0.62, 0.43, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.10, 0.40, 0.28, 1.0 });
    if (gui.buttonEx(state.text(.ai_chat_apply_config), apply_btn_w, 0.0)) {
        applyProviderDefaults(state);
        logProviderConfig(state);
        preferences.saveAiProviderSettings(state) catch |err| {
            ai_chat_log.warn("failed to persist AI provider settings: {s}", .{@errorName(err)});
        };
        if (activeProviderValidationError(state)) |validation_error| {
            const validation_error_text = providerValidationErrorText(state, validation_error);
            g_connection_error = validation_error_text;
            var message_buffer: [224]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "{s}: {s}",
                .{ state.text(.ai_chat_provider_apply_incomplete_fallback), validation_error_text },
            ) catch state.text(.ai_chat_provider_apply_incomplete_fallback);
            appendMessage(.system, message);
            ai_chat_log.warn("Provider config invalid: {s}", .{validation_error_text});
        } else {
            g_connection_error = null;
            appendMessage(.system, state.text(.ai_chat_provider_apply_success));
            ai_chat_log.info("Provider config applied: {s}", .{providerDisplayNameForUi(state, p)});
        }
    }
    gui.popStyleColor(3);

    gui.sameLine();
    gui.pushStyleColor(.button, .{ 0.22, 0.24, 0.27, 1.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.30, 0.33, 0.37, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.18, 0.20, 0.24, 1.0 });
    if (gui.buttonEx(state.text(.ai_chat_test_connection), test_btn_w, 0.0)) {
        logProviderConfig(state);
        ai_chat_log.info("Test connection requested for provider: {s}", .{providerDisplayNameForUi(state, p)});
        appendMessage(.system, state.text(.ai_chat_testing_connection));

        const endpoint_len = std.mem.indexOfScalar(u8, &p.endpoint, 0) orelse p.endpoint.len;
        const model_len = std.mem.indexOfScalar(u8, &p.model, 0) orelse p.model.len;
        const apikey_len = std.mem.indexOfScalar(u8, &p.api_key, 0) orelse p.api_key.len;
        const needs_api_key = state.ai_provider_type != .ollama;

        if (endpoint_len == 0) {
            appendMessage(.system, state.text(.ai_chat_error_input_endpoint));
        } else if (model_len == 0) {
            appendMessage(.system, state.text(.ai_chat_error_input_model));
        } else if (needs_api_key and apikey_len == 0) {
            appendMessage(.system, state.text(.ai_chat_error_input_api_key));
        } else {
            const endpoint = p.endpoint[0..endpoint_len];
            const model = p.model[0..model_len];
            const api_key = p.api_key[0..apikey_len];
            const summary = testHttpConnectionAlloc(state.ai_provider_type, endpoint, api_key, model) catch |err| blk: {
                break :blk allocMessage(
                    "{s}: {s}",
                    .{ state.text(.ai_chat_connection_test_failed_fallback), @errorName(err) },
                    state.text(.ai_chat_connection_test_failed_fallback),
                ) catch null;
            };
            if (summary) |resolved_summary| {
                defer std.heap.page_allocator.free(resolved_summary);
                appendMessage(.system, resolved_summary);
            } else {
                appendMessage(.system, state.text(.ai_chat_connection_test_failed_fallback));
            }
        }
    }
    gui.popStyleColor(3);

    if (g_connection_error) |err| {
        gui.dummy(0.0, 4.0);
        gui.pushStyleColor(.text, .{ 0.90, 0.30, 0.30, 1.0 });
        gui.textWrapped(err);
        gui.popStyleColor(1);
    }

    if (provider_prefs_dirty) {
        preferences.saveAiProviderSettings(state) catch |err| {
            ai_chat_log.warn("failed to auto-persist AI provider settings: {s}", .{@errorName(err)});
        };
    }
}

var g_window_initialized = false;
var g_prev_ai_chat_open = false;
var g_focus_ai_input_next_frame = true;

pub fn drawAiChatPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    pumpAsyncResults(state, layer_context);
    if (!state.ai_chat_open) {
        g_prev_ai_chat_open = false;
        return;
    }

    if (!g_prev_ai_chat_open) {
        g_focus_ai_input_next_frame = true;
    }
    g_prev_ai_chat_open = true;

    var window_title_buffer: [96]u8 = undefined;
    const window_title = state.windowLabel(&window_title_buffer, .ai_chat, "ai_chat_floating") catch "AI Assistant###ai_chat_floating";

    if (!g_window_initialized) {
        gui.setNextWindowPos(.{ 50.0, 100.0 });
        gui.setNextWindowSize(.{ 420.0, 500.0 });
        g_window_initialized = true;
    }
    gui.setNextWindowBgAlpha(0.96);

    const window_flags = gui.WindowFlags.no_docking;

    const open = gui.beginWindowFlags(window_title, window_flags);
    defer gui.endWindow();

    if (!open) return;

    drawHeaderBar(state);
    try drawProviderSettings(state, layer_context);
    drawStagedTransactionBanner(state);
    drawStageDetail(state);

    gui.separator();

    const avail = gui.contentRegionAvail();
    const input_row_height: f32 = 34.0;
    const messages_height = avail[1] - input_row_height - 6.0;

    if (messages_height > 10.0) {
        _ = gui.beginChild("ai_messages##jt", 0.0, messages_height, false);
        defer gui.endChild();

        drawMessages(state);

        if (g_scroll_to_bottom) {
            gui.setScrollHereY(1.0);
            g_scroll_to_bottom = false;
        }
    }

    gui.separator();
    const total_width = gui.contentRegionAvail()[0];
    const send_btn_width: f32 = 52.0;
    const input_width = total_width - send_btn_width - 6.0;
    const busy = asyncIsRunning();

    if (input_width > 30.0) {
        if (g_focus_ai_input_next_frame and !busy) {
            gui.setKeyboardFocusHere(0);
            g_focus_ai_input_next_frame = false;
        }
        gui.setNextItemWidth(input_width);
        const enter_pressed = inputTextWithHintStyledFlags(
            "##ai_input",
            if (busy) state.text(.ai_chat_background_processing) else state.text(.ai_chat_input_hint),
            g_input_buffer[0..],
            if (busy) gui.InputTextFlags.none else gui.InputTextFlags.enter_returns_true,
        );

        gui.sameLine();
        gui.pushStyleColor(.button, .{ 0.13, 0.50, 0.36, 0.88 });
        gui.pushStyleColor(.button_hovered, .{ 0.15, 0.62, 0.43, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.10, 0.40, 0.28, 1.0 });
        const send_pressed = gui.buttonEx(if (busy) state.text(.ai_chat_wait) else state.text(.ai_chat_send), send_btn_width, 0.0);
        gui.popStyleColor(3);

        if (enter_pressed or send_pressed) {
            submitInput(state, layer_context);
            g_focus_ai_input_next_frame = true;
        }
    }
}
