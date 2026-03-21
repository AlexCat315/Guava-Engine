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
        // Shift messages up (ring buffer style: drop oldest)
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

    // If AI collaboration store is available, we could route through MCP
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

fn drawMessageBubble(msg: *const Message, state: *const EditorState) void {
    _ = state;
    const content_text = msg.content();
    if (content_text.len == 0) return;

    switch (msg.role) {
        .user => {
            gui.pushStyleColor(.text, .{ 0.85, 0.90, 0.95, 1.0 });
            gui.textWrapped(content_text);
            gui.popStyleColor(1);
        },
        .assistant => {
            gui.pushStyleColor(.text, .{ 0.60, 0.90, 0.65, 1.0 });
            gui.textWrapped(content_text);
            gui.popStyleColor(1);
        },
        .system => {
            gui.pushStyleColor(.text, .{ 0.55, 0.55, 0.55, 1.0 });
            gui.textWrapped(content_text);
            gui.popStyleColor(1);
        },
    }
    gui.dummy(0, 4);
}

fn roleLabel(role: Role) []const u8 {
    return switch (role) {
        .user => "You",
        .assistant => "AI",
        .system => "System",
    };
}

pub fn drawAiChatPanel(state: *EditorState) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .ai_chat, "ai_chat_panel");
    var open = state.ai_chat_open;
    _ = gui.beginWindowOpen(title, &open);
    defer gui.endWindow();
    state.ai_chat_open = open;
    if (!open) return;

    // Connection status indicator
    const is_connected = state.ai_collaboration != null;
    if (is_connected) {
        gui.pushStyleColor(.text, .{ 0.3, 0.8, 0.4, 1.0 });
        gui.text(state.text(.ai_chat_connected));
    } else {
        gui.pushStyleColor(.text, .{ 0.8, 0.3, 0.3, 1.0 });
        gui.text(state.text(.ai_chat_disconnected));
    }
    gui.popStyleColor(1);
    gui.separator();

    // Message area
    const avail = gui.contentRegionAvail();
    const input_height: f32 = 60.0;
    const messages_height = avail[1] - input_height;

    if (messages_height > 0) {
        _ = gui.beginChild("ai_messages", 0.0, messages_height, true);
        defer gui.endChild();

        if (g_message_count == 0) {
            gui.pushStyleColor(.text, .{ 0.5, 0.5, 0.5, 1.0 });
            gui.textWrapped(state.text(.ai_chat_empty));
            gui.popStyleColor(1);
        } else {
            for (0..g_message_count) |i| {
                const msg = &g_messages[i];
                const label = roleLabel(msg.role);

                gui.pushStyleColor(.text, .{ 0.45, 0.45, 0.45, 1.0 });
                gui.text(label);
                gui.popStyleColor(1);

                drawMessageBubble(msg, state);
                if (i + 1 < g_message_count) {
                    gui.separator();
                }
            }
        }

        if (g_scroll_to_bottom) {
            gui.setScrollHereY(1.0);
            g_scroll_to_bottom = false;
        }
    }

    // Input area
    gui.separator();
    const input_width = avail[0] - 70.0;
    if (input_width > 50.0) {
        gui.setNextItemWidth(input_width);
        _ = gui.inputTextWithHint(
            "##ai_input",
            state.text(.ai_chat_input_hint),
            &g_input_buffer,
        );
        const enter_pressed = gui.isItemDeactivatedAfterEdit();

        gui.sameLine();
        const send_pressed = gui.buttonEx(state.text(.ai_chat_send), 60.0, 0.0);

        if (enter_pressed or send_pressed) {
            submitInput(state);
        }
    }
}
