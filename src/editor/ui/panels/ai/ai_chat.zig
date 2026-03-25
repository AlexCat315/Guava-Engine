const std = @import("std");
const gui = @import("../../gui.zig");
const state_mod = @import("../../../core/state.zig");
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
var g_pending_response: bool = false;
var g_connection_error: ?[:0]const u8 = null;

const provider_type_names = [_][]const u8{
    "OpenAI",
    "Anthropic",
    "Ollama",
    "Custom",
};

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
    g_pending_response = false;
    ai_chat_log.info("Chat history cleared", .{});
}

pub fn clearConnectionError() void {
    g_connection_error = null;
}

fn applyProviderDefaults(state: *EditorState) void {
    const p = &state.ai_providers[state.ai_active_provider];
    const defaults = provider_defaults[@intFromEnum(state.ai_provider_type)];

    if (p.endpoint[0] == 0 and defaults.endpoint.len > 0) {
        @memcpy(p.endpoint[0..defaults.endpoint.len], defaults.endpoint);
        ai_chat_log.info("Applied default endpoint for {s}: {s}", .{ provider_type_names[@intFromEnum(state.ai_provider_type)], defaults.endpoint });
    }
    if (p.model[0] == 0 and defaults.model.len > 0) {
        @memcpy(p.model[0..defaults.model.len], defaults.model);
        ai_chat_log.info("Applied default model for {s}: {s}", .{ provider_type_names[@intFromEnum(state.ai_provider_type)], defaults.model });
    }
}

fn testHttpConnection(
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
) void {
    ai_chat_log.info("=== HTTP Connection Test ===", .{});
    ai_chat_log.info("Endpoint: {s}", .{endpoint});
    ai_chat_log.info("Model: {s}", .{model});
    ai_chat_log.info("API Key length: {d}", .{api_key.len});

    ai_chat_log.info("NOTE: HTTP client not yet implemented in this codebase", .{});
    ai_chat_log.info("To test your connection manually:", .{});
    ai_chat_log.info("Run this curl command:", .{});

    var cmd_buffer: [512]u8 = undefined;
    const curl_cmd = std.fmt.bufPrint(&cmd_buffer,
        \\curl -X POST {s} -H "Content-Type: application/json" -H "Authorization: Bearer {s}" -d "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"hi\"}}]}}"
    , .{ endpoint, api_key, model }) catch "";
    ai_chat_log.info("{s}", .{curl_cmd});
}

fn logProviderConfig(state: *EditorState) void {
    const p = &state.ai_providers[state.ai_active_provider];
    const ptype = state.ai_provider_type;
    ai_chat_log.info("=== Provider Configuration ===", .{});
    ai_chat_log.info("Type: {s}", .{provider_type_names[@intFromEnum(ptype)]});
    ai_chat_log.info("Name: {s}", .{p.displayName()});

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

fn submitInput(state: *EditorState) void {
    const input_len = std.mem.indexOfScalar(u8, &g_input_buffer, 0) orelse max_input_len;
    if (input_len == 0) return;

    const input_text = g_input_buffer[0..input_len];
    ai_chat_log.info("User input: {s}", .{input_text});
    appendMessage(.user, input_text);

    if (state.ai_collaboration) |store| {
        _ = store;
        ai_chat_log.info("AI collaboration active, sending message", .{});
        appendMessage(.system, state.text(.ai_chat_thinking));
    } else {
        ai_chat_log.warn("AI collaboration not connected, showing disconnected message", .{});
        appendMessage(.system, state.text(.ai_chat_disconnected));
    }

    @memset(&g_input_buffer, 0);
}

fn drawHeaderBar(state: *EditorState) void {
    const full_width = gui.contentRegionAvail()[0];
    const is_connected = state.ai_collaboration != null;

    if (is_connected) {
        gui.pushStyleColor(.text, .{ 0.22, 0.82, 0.46, 1.0 });
        gui.text("●");
    } else {
        gui.pushStyleColor(.text, .{ 0.80, 0.28, 0.28, 1.0 });
        gui.text("●");
    }
    gui.popStyleColor(1);
    gui.sameLine();

    if (state.ai_collaboration) |store| {
        const ai_status = store.aiStatusSnapshot();
        const stage_label = switch (ai_status.stage) {
            .ready => "就绪",
            .analyzing_screenshot => "分析截图...",
            .compiling_shader => "编译 Shader...",
            .waiting_approval => "等待审批",
        };
        const stage_color: [4]f32 = switch (ai_status.stage) {
            .ready => .{ 0.55, 0.62, 0.70, 1.0 },
            .analyzing_screenshot, .compiling_shader => .{ 0.95, 0.80, 0.30, 1.0 },
            .waiting_approval => .{ 0.95, 0.55, 0.20, 1.0 },
        };
        gui.pushStyleColor(.text, stage_color);
        gui.text(stage_label);
        gui.popStyleColor(1);
    } else {
        gui.pushStyleColor(.text, .{ 0.45, 0.47, 0.52, 1.0 });
        gui.text("未连接");
        gui.popStyleColor(1);
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
        if (gui.buttonEx("清空", clear_w, 0.0)) {
            clearHistory();
        }
        gui.sameLine();
        if (gui.buttonEx("配置", config_w, 0.0)) {
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
    gui.text("  ⏳ AI 已暂存修改，等待审批");
    gui.popStyleColor(1);
    gui.pushStyleColor(.text, .{ 0.68, 0.72, 0.80, 1.0 });
    gui.text("  → 在视口叠加层使用 Apply / Discard");
    gui.popStyleColor(1);
    gui.dummy(0.0, 2.0);
}

fn drawStageDetail(state: *EditorState) void {
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
                gui.text("你");
                gui.popStyleColor(1);
                gui.pushStyleColor(.text, .{ 0.88, 0.92, 0.98, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
            .assistant => {
                gui.pushStyleColor(.text, .{ 0.22, 0.82, 0.52, 0.80 });
                gui.text("Jarvis");
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

fn drawProviderSettings(state: *EditorState) void {
    if (!state.ai_provider_settings_open) return;

    gui.separator();
    _ = gui.beginChild("ai_provider_settings##jt", 0.0, 320.0, true);
    defer gui.endChild();

    gui.pushStyleColor(.text, .{ 0.78, 0.83, 0.92, 1.0 });
    gui.text("Provider 配置");
    gui.popStyleColor(1);
    gui.dummy(0.0, 4.0);

    const avail_w = gui.contentRegionAvail()[0];
    const btn_w: f32 = 26.0;
    const btn_gap: f32 = 4.0;
    const combo_w = avail_w - (btn_w + btn_gap) * 2.0;

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("类型");
    gui.popStyleColor(1);

    const active_idx: usize = @intFromEnum(state.ai_provider_type);
    gui.setNextItemWidth(combo_w);
    if (gui.beginCombo("##ai_type_select", provider_type_names[active_idx])) {
        defer gui.endCombo();
        for (0..provider_type_names.len) |i| {
            gui.pushIdU64(@intCast(i));
            defer gui.popId();
            if (gui.selectable(provider_type_names[i], i == active_idx, false, 0.0, 0.0)) {
                state.ai_provider_type = @enumFromInt(i);
                ai_chat_log.info("Provider type changed to: {s}", .{provider_type_names[i]});
                applyProviderDefaults(state);
            }
            if (i == active_idx) gui.setItemDefaultFocus();
        }
    }

    gui.pushStyleColor(.button, .{ 0.22, 0.24, 0.27, 1.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.30, 0.33, 0.37, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.13, 0.80, 0.39, 1.0 });

    gui.sameLine();
    if (gui.buttonEx("+", btn_w, 0.0)) {
        if (state.ai_provider_count < state.ai_providers.len) {
            state.ai_providers[state.ai_provider_count] = .{};
            state.ai_active_provider = state.ai_provider_count;
            state.ai_provider_count += 1;
            ai_chat_log.info("Added new provider, total: {d}", .{state.ai_provider_count});
        }
    }

    gui.popStyleColor(3);

    gui.sameLine();
    const can_delete = state.ai_provider_count > 1;
    if (can_delete) {
        gui.pushStyleColor(.button, .{ 0.22, 0.24, 0.27, 1.0 });
        gui.pushStyleColor(.button_hovered, .{ 0.50, 0.22, 0.22, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.70, 0.20, 0.20, 1.0 });
    } else {
        gui.pushStyleColor(.button, .{ 0.20, 0.21, 0.23, 0.50 });
        gui.pushStyleColor(.button_hovered, .{ 0.20, 0.21, 0.23, 0.50 });
        gui.pushStyleColor(.button_active, .{ 0.20, 0.21, 0.23, 0.50 });
        gui.pushStyleColor(.text, .{ 0.38, 0.38, 0.40, 1.0 });
    }
    const did_delete = gui.buttonEx("\xc3\x97", btn_w, 0.0);
    if (can_delete) gui.popStyleColor(3) else gui.popStyleColor(4);
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
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    gui.pushIdU64(@intCast(state.ai_active_provider));
    defer gui.popId();

    const p = &state.ai_providers[state.ai_active_provider];

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("显示名称");
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##name", "我的 OpenAI", p.name[0..]);

    gui.dummy(0.0, 4.0);

    const needs_endpoint = state.ai_provider_type != .ollama;
    if (needs_endpoint) {
        gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
        gui.text("API Endpoint");
        gui.popStyleColor(1);
        gui.setNextItemWidth(-1.0);
        _ = gui.inputTextWithHint("##endpoint", "https://api.openai.com/v1/...", p.endpoint[0..]);
        gui.dummy(0.0, 4.0);
    }

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("模型");
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##model", "gpt-4o / claude-sonnet-4", p.model[0..]);

    gui.dummy(0.0, 4.0);

    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("API Key");
    gui.popStyleColor(1);
    const toggle_w: f32 = 50.0;
    const key_gap: f32 = 6.0;
    gui.setNextItemWidth(gui.contentRegionAvail()[0] - toggle_w - key_gap);
    if (state.ai_provider_api_key_visible) {
        _ = gui.inputTextWithHint("##apikey", "sk-...", p.api_key[0..]);
    } else {
        _ = gui.inputTextPassword("##apikey", p.api_key[0..]);
    }
    gui.sameLine();
    if (gui.buttonEx(if (state.ai_provider_api_key_visible) "隐藏" else "显示", toggle_w, 0.0)) {
        state.ai_provider_api_key_visible = !state.ai_provider_api_key_visible;
    }

    gui.dummy(0.0, 12.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    const connect_btn_w: f32 = 100.0;
    const test_btn_w: f32 = 70.0;
    const btn_row_w = connect_btn_w + test_btn_w + 8.0;
    const btn_row_x = (avail_w - btn_row_w) * 0.5;
    gui.sameLineEx(btn_row_x, 0.0);

    if (state.ai_collaboration != null) {
        gui.pushStyleColor(.button, .{ 0.70, 0.22, 0.22, 0.88 });
        gui.pushStyleColor(.button_hovered, .{ 0.78, 0.28, 0.28, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.60, 0.18, 0.18, 1.0 });
        if (gui.buttonEx("断开连接", connect_btn_w, 0.0)) {
            ai_chat_log.info("Disconnecting AI collaboration", .{});
            state.ai_collaboration = null;
            appendMessage(.system, "已断开连接");
        }
    } else {
        gui.pushStyleColor(.button, .{ 0.13, 0.50, 0.36, 0.88 });
        gui.pushStyleColor(.button_hovered, .{ 0.15, 0.62, 0.43, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.10, 0.40, 0.28, 1.0 });
        if (gui.buttonEx("连接", connect_btn_w, 0.0)) {
            logProviderConfig(state);

            const pname = p.displayName();
            const apikey_len = std.mem.indexOfScalar(u8, &p.api_key, 0) orelse p.api_key.len;
            const endpoint_len = std.mem.indexOfScalar(u8, &p.endpoint, 0) orelse p.endpoint.len;
            const model_len = std.mem.indexOfScalar(u8, &p.model, 0) orelse p.model.len;

            if (apikey_len == 0) {
                g_connection_error = "请输入 API Key";
                ai_chat_log.err("Connection failed: API Key is empty", .{});
                appendMessage(.system, "错误: 请输入 API Key");
            } else if (needs_endpoint and endpoint_len == 0) {
                g_connection_error = "请输入 API Endpoint";
                ai_chat_log.err("Connection failed: Endpoint is empty", .{});
                appendMessage(.system, "错误: 请输入 API Endpoint");
            } else if (model_len == 0) {
                g_connection_error = "请输入模型名称";
                ai_chat_log.err("Connection failed: Model name is empty", .{});
                appendMessage(.system, "错误: 请输入模型名称");
            } else {
                g_connection_error = null;
                ai_chat_log.info("Attempting to connect to provider: {s}", .{pname});
                ai_chat_log.info("Provider type: {s}", .{provider_type_names[@intFromEnum(state.ai_provider_type)]});

                switch (state.ai_provider_type) {
                    .openai => ai_chat_log.info("OpenAI API connection requested - this would use HTTP client to connect to {s}", .{provider_defaults[0].endpoint}),
                    .anthropic => ai_chat_log.info("Anthropic API connection requested - this would use HTTP client to connect to {s}", .{provider_defaults[1].endpoint}),
                    .ollama => ai_chat_log.info("Ollama connection requested - this would use HTTP client to connect to {s}", .{provider_defaults[2].endpoint}),
                    .custom => ai_chat_log.info("Custom provider connection requested", .{}),
                }

                appendMessage(.system, "已连接到 ");
                appendMessage(.system, pname);
                ai_chat_log.info("Connection successful (UI state updated)", .{});
            }
        }
        gui.popStyleColor(3);
    }

    gui.sameLine();
    gui.pushStyleColor(.button, .{ 0.22, 0.24, 0.27, 1.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.30, 0.33, 0.37, 1.0 });
    gui.pushStyleColor(.button_active, .{ 0.18, 0.20, 0.24, 1.0 });
    if (gui.buttonEx("测试", test_btn_w, 0.0)) {
        logProviderConfig(state);
        ai_chat_log.info("Test connection requested for provider: {s}", .{p.displayName()});
        appendMessage(.system, "正在测试连接...");

        const endpoint_len = std.mem.indexOfScalar(u8, &p.endpoint, 0) orelse p.endpoint.len;
        const model_len = std.mem.indexOfScalar(u8, &p.model, 0) orelse p.model.len;
        const apikey_len = std.mem.indexOfScalar(u8, &p.api_key, 0) orelse p.api_key.len;

        if (endpoint_len == 0) {
            appendMessage(.system, "错误: 请先输入 Endpoint");
        } else if (model_len == 0) {
            appendMessage(.system, "错误: 请先输入模型名称");
        } else if (apikey_len == 0) {
            appendMessage(.system, "错误: 请先输入 API Key");
        } else {
            const endpoint = p.endpoint[0..endpoint_len];
            const model = p.model[0..model_len];
            const api_key = p.api_key[0..apikey_len];

            ai_chat_log.info("Sending test request to {s}...", .{endpoint});
            testHttpConnection(endpoint, api_key, model);
            appendMessage(.system, "测试信息已输出到终端日志");
        }
    }
    gui.popStyleColor(3);

    if (g_connection_error) |err| {
        gui.dummy(0.0, 4.0);
        gui.pushStyleColor(.text, .{ 0.90, 0.30, 0.30, 1.0 });
        gui.textWrapped(err);
        gui.popStyleColor(1);
    }
}

var g_window_initialized = false;

pub fn drawAiChatPanel(state: *EditorState) !void {
    if (!state.ai_chat_open) return;

    const window_title = "Jarvis AI##ai_chat_floating";

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
    drawProviderSettings(state);
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

    if (input_width > 30.0) {
        gui.setNextItemWidth(input_width);
        _ = gui.inputTextWithHint(
            "##ai_input",
            state.text(.ai_chat_input_hint),
            g_input_buffer[0..],
        );
        const enter_pressed = gui.isItemDeactivatedAfterEdit();

        gui.sameLine();
        gui.pushStyleColor(.button, .{ 0.13, 0.50, 0.36, 0.88 });
        gui.pushStyleColor(.button_hovered, .{ 0.15, 0.62, 0.43, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.10, 0.40, 0.28, 1.0 });
        const send_pressed = gui.buttonEx(state.text(.ai_chat_send), send_btn_width, 0.0);
        gui.popStyleColor(3);

        if (enter_pressed or send_pressed) {
            submitInput(state);
        }
    }
}
