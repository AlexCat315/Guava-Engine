const std = @import("std");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

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

pub fn appendMessage(role: Role, text: []const u8) void {
    if (g_message_count >= max_messages) {
        // Shift messages up (drop oldest)
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
}

fn submitInput(state: *EditorState) void {
    const input_len = std.mem.indexOfScalar(u8, &g_input_buffer, 0) orelse max_input_len;
    if (input_len == 0) return;

    const input_text = g_input_buffer[0..input_len];
    appendMessage(.user, input_text);

    if (state.ai_collaboration) |store| {
        _ = store;
        // MCP tool calls are handled by the external AI agent via stdio.
        // The chat panel shows the conversation log; actual tool execution
        // flows through the MCP server → tools bridge → command queue.
        appendMessage(.system, state.text(.ai_chat_thinking));
    } else {
        appendMessage(.system, state.text(.ai_chat_disconnected));
    }

    @memset(&g_input_buffer, 0);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Header bar: connection status + AI stage + action buttons
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fn drawHeaderBar(state: *EditorState) void {
    // Capture the FULL row width BEFORE any item is rendered.
    // contentRegionAvail() after gui.text() would return the full width again
    // (cursor is at the start of the next line), making offset_from_start_x
    // wrong.  We need it now, at the true left edge of this row.
    const full_width = gui.contentRegionAvail()[0];

    const is_connected = state.ai_collaboration != null;

    // Status dot
    if (is_connected) {
        gui.pushStyleColor(.text, .{ 0.22, 0.82, 0.46, 1.0 });
        gui.text("●");
    } else {
        gui.pushStyleColor(.text, .{ 0.80, 0.28, 0.28, 1.0 });
        gui.text("●");
    }
    gui.popStyleColor(1);
    gui.sameLine();

    // Stage label
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
        gui.text("未连接  (MCP stdio)");
        gui.popStyleColor(1);
    }

    // Right-aligned: [清空] [配置]
    // Use offset_from_start_x (non-zero first arg) so ImGui positions the
    // cursor at (content_left + offset), giving true right-alignment.
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
        }
        gui.popStyleColor(3);
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Staged transaction banner (waiting_approval stage)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// AI stage detail strip (below header, only when working)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fn drawStageDetail(state: *EditorState) void {
    const store = state.ai_collaboration orelse return;
    const ai_status = store.aiStatusSnapshot();
    if (ai_status.stage == .ready) return;

    const detail = if (ai_status.detail.len > 0)
        ai_status.detail.slice()
    else
        return;

    gui.pushStyleColor(.text, .{ 0.58, 0.65, 0.75, 1.0 });
    gui.textWrapped(detail);
    gui.popStyleColor(1);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Message area
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
                // User: right-aligned, soft blue
                gui.pushStyleColor(.text, .{ 0.60, 0.68, 0.80, 0.72 });
                gui.text("你");
                gui.popStyleColor(1);
                gui.pushStyleColor(.text, .{ 0.88, 0.92, 0.98, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
            .assistant => {
                // Assistant: green role tag + brighter text
                gui.pushStyleColor(.text, .{ 0.22, 0.82, 0.52, 0.80 });
                gui.text("Jarvis");
                gui.popStyleColor(1);
                gui.pushStyleColor(.text, .{ 0.78, 0.94, 0.82, 1.0 });
                gui.textWrapped(content_text);
                gui.popStyleColor(1);
            },
            .system => {
                // System: muted gray, no role label
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Provider settings panel (collapsible child)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fn drawProviderSettings(state: *EditorState) void {
    if (!state.ai_provider_settings_open) return;

    gui.separator();
    _ = gui.beginChild("ai_provider_settings##jt", 0.0, 240.0, true);
    defer gui.endChild();

    gui.pushStyleColor(.text, .{ 0.78, 0.83, 0.92, 1.0 });
    gui.text("Provider 配置");
    gui.popStyleColor(1);
    gui.dummy(0.0, 2.0);

    // ── Provider selector: [combo ▼] [+] [×] ─────────────
    const avail_w = gui.contentRegionAvail()[0];
    const btn_w: f32 = 26.0;
    const btn_gap: f32 = 4.0;
    const combo_w = avail_w - (btn_w + btn_gap) * 2.0;

    const active_idx = state.ai_active_provider;
    const active_name = state.ai_providers[active_idx].displayName();
    gui.setNextItemWidth(combo_w);
    if (gui.beginCombo("##ai_prov_select", active_name)) {
        defer gui.endCombo();
        for (0..state.ai_provider_count) |i| {
            gui.pushIdU64(@intCast(i));
            defer gui.popId();
            const name = state.ai_providers[i].displayName();
            if (gui.selectable(name, i == active_idx, false, 0.0, 0.0)) {
                state.ai_active_provider = i;
            }
            if (i == active_idx) gui.setItemDefaultFocus();
        }
    }

    // 统一 + 和 × 按钮样式，与 combo 保持一致的低调风格
    const action_btn: [4]f32 = .{ 0.22, 0.24, 0.27, 1.0 };
    const action_btn_hover: [4]f32 = .{ 0.30, 0.33, 0.37, 1.0 };
    const action_btn_active: [4]f32 = .{ 0.13, 0.80, 0.39, 1.0 };
    gui.pushStyleColor(.button, action_btn);
    gui.pushStyleColor(.button_hovered, action_btn_hover);
    gui.pushStyleColor(.button_active, action_btn_active);

    gui.sameLine();
    if (gui.buttonEx("+", btn_w, 0.0)) {
        if (state.ai_provider_count < state.ai_providers.len) {
            state.ai_providers[state.ai_provider_count] = .{};
            state.ai_active_provider = state.ai_provider_count;
            state.ai_provider_count += 1;
        }
    }

    gui.popStyleColor(3);

    gui.sameLine();
    const can_delete = state.ai_provider_count > 1;
    if (can_delete) {
        gui.pushStyleColor(.button, action_btn);
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
        var i = active_idx;
        while (i + 1 < state.ai_provider_count) : (i += 1) {
            state.ai_providers[i] = state.ai_providers[i + 1];
        }
        state.ai_provider_count -= 1;
        if (state.ai_active_provider >= state.ai_provider_count) {
            state.ai_active_provider = state.ai_provider_count - 1;
        }
    }

    // ── Fields for the active provider ───────────────────
    // Push a unique ID scope so ImGui's InputText cached state is
    // invalidated when the user switches to a different provider.
    gui.pushIdU64(@intCast(state.ai_active_provider));
    defer gui.popId();

    const p = &state.ai_providers[state.ai_active_provider];

    gui.dummy(0.0, 2.0);
    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("Name");
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##name", "OpenAI / Anthropic / ...", p.name[0..]);

    gui.dummy(0.0, 2.0);
    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("Endpoint");
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##endpoint", "https://api.openai.com/v1", p.endpoint[0..]);

    gui.dummy(0.0, 2.0);
    gui.pushStyleColor(.text, .{ 0.65, 0.70, 0.78, 1.0 });
    gui.text("Model");
    gui.popStyleColor(1);
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##model", "gpt-4o / claude-opus-4-5", p.model[0..]);

    gui.dummy(0.0, 2.0);
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
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Main entry point
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
pub fn drawAiChatPanel(state: *EditorState) !void {
    const title = "Jarvis Terminal##ai_chat_panel";
    var open = state.ai_chat_open;
    _ = gui.beginWindowOpen(title, &open);
    defer gui.endWindow();
    state.ai_chat_open = open;
    if (!open) return;

    // 1. Compact header bar
    drawHeaderBar(state);

    // 2. Provider settings (collapsible, right below header)
    drawProviderSettings(state);

    // 3. Staged transaction banner (warning bar when AI is waiting)
    drawStagedTransactionBanner(state);

    // 4. Stage detail strip (only visible while working)
    drawStageDetail(state);

    gui.separator();

    // 5. Message scroll area — fills available space minus input row
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

    // 6. Input bar
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
