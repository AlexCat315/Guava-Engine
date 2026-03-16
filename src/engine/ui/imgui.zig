const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const sdl = @import("../platform/sdl.zig").c;
const window_mod = @import("../platform/window.zig");

pub const c = @cImport({
    @cInclude("imgui_bridge.h");
});

pub const Error = error{
    ImGuiInitFailed,
};

pub const WindowControlButton = enum(c_uint) {
    minimize = c.GUAVA_IMGUI_WINDOW_CONTROL_MINIMIZE,
    maximize = c.GUAVA_IMGUI_WINDOW_CONTROL_MAXIMIZE,
    close = c.GUAVA_IMGUI_WINDOW_CONTROL_CLOSE,
};

pub const StyleColor = enum(c_uint) {
    text = c.GUAVA_IMGUI_STYLE_COLOR_TEXT,
    button = c.GUAVA_IMGUI_STYLE_COLOR_BUTTON,
    button_hovered = c.GUAVA_IMGUI_STYLE_COLOR_BUTTON_HOVERED,
    button_active = c.GUAVA_IMGUI_STYLE_COLOR_BUTTON_ACTIVE,
};

pub const WindowFlags = struct {
    pub const none: u32 = c.GUAVA_IMGUI_WINDOW_NONE;
    pub const no_title_bar: u32 = c.GUAVA_IMGUI_WINDOW_NO_TITLE_BAR;
    pub const no_resize: u32 = c.GUAVA_IMGUI_WINDOW_NO_RESIZE;
    pub const no_move: u32 = c.GUAVA_IMGUI_WINDOW_NO_MOVE;
    pub const no_scrollbar: u32 = c.GUAVA_IMGUI_WINDOW_NO_SCROLLBAR;
    pub const no_saved_settings: u32 = c.GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS;
    pub const no_docking: u32 = c.GUAVA_IMGUI_WINDOW_NO_DOCKING;
    pub const no_collapse: u32 = c.GUAVA_IMGUI_WINDOW_NO_COLLAPSE;
    pub const no_background: u32 = c.GUAVA_IMGUI_WINDOW_NO_BACKGROUND;
    pub const no_decoration: u32 = c.GUAVA_IMGUI_WINDOW_NO_DECORATION;
};

pub fn init(window: *window_mod.Window, device: *rhi_mod.RhiDevice) Error!void {
    if (!c.guava_imgui_init(
        @ptrCast(window.handle),
        @ptrCast(device.raw),
        textureFormatToSdl(device.runtimeInfo().swapchain_format),
    )) {
        return error.ImGuiInitFailed;
    }
}

pub fn shutdown() void {
    c.guava_imgui_shutdown();
}

pub fn processEvent(raw_event: *const sdl.SDL_Event) void {
    c.guava_imgui_process_event(@ptrCast(raw_event));
}

pub fn newFrame() void {
    c.guava_imgui_new_frame();
}

pub fn beginDockspace() void {
    c.guava_imgui_begin_dockspace();
}

pub fn resetDefaultLayout() void {
    c.guava_imgui_reset_default_layout();
}

pub fn render(command_buffer: *sdl.SDL_GPUCommandBuffer, render_pass: *sdl.SDL_GPURenderPass) void {
    c.guava_imgui_render(@ptrCast(command_buffer), @ptrCast(render_pass));
}

pub fn prepare(command_buffer: *sdl.SDL_GPUCommandBuffer) void {
    c.guava_imgui_prepare(@ptrCast(command_buffer));
}

pub fn wantsCaptureMouse() bool {
    return c.guava_imgui_want_capture_mouse();
}

pub fn wantsCaptureKeyboard() bool {
    return c.guava_imgui_want_capture_keyboard();
}

pub fn beginWindow(name: []const u8) bool {
    return c.guava_imgui_begin_window(name.ptr, name.len);
}

pub fn beginWindowFlags(name: []const u8, flags: u32) bool {
    return c.guava_imgui_begin_window_flags(name.ptr, name.len, flags);
}

pub fn endWindow() void {
    c.guava_imgui_end_window();
}

pub fn beginMainMenuBar() bool {
    return c.guava_imgui_begin_main_menu_bar();
}

pub fn endMainMenuBar() void {
    c.guava_imgui_end_main_menu_bar();
}

pub fn beginMenu(label: []const u8) bool {
    return c.guava_imgui_begin_menu(label.ptr, label.len);
}

pub fn endMenu() void {
    c.guava_imgui_end_menu();
}

pub fn menuItem(label: []const u8, shortcut: ?[]const u8, selected: bool, enabled: bool) bool {
    const shortcut_ptr = if (shortcut) |value| value.ptr else null;
    const shortcut_len = if (shortcut) |value| value.len else 0;
    return c.guava_imgui_menu_item(label.ptr, label.len, shortcut_ptr, shortcut_len, selected, enabled);
}

pub fn button(label: []const u8) bool {
    return c.guava_imgui_button(label.ptr, label.len);
}

pub fn buttonEx(label: []const u8, width: f32, height: f32) bool {
    return c.guava_imgui_button_ex(label.ptr, label.len, width, height);
}

pub fn invisibleButton(id: []const u8, width: f32, height: f32) bool {
    return c.guava_imgui_invisible_button(id.ptr, id.len, width, height);
}

pub fn windowControlButton(kind: WindowControlButton, toggled: bool) bool {
    return c.guava_imgui_window_control_button(@intFromEnum(kind), toggled);
}

pub fn dummy(width: f32, height: f32) void {
    c.guava_imgui_dummy(width, height);
}

pub fn sameLine() void {
    c.guava_imgui_same_line();
}

pub fn separator() void {
    c.guava_imgui_separator();
}

pub fn setNextItemWidth(width: f32) void {
    c.guava_imgui_set_next_item_width(width);
}

pub fn pushStyleColor(slot: StyleColor, color: [4]f32) void {
    c.guava_imgui_push_style_color(@intFromEnum(slot), color[0], color[1], color[2], color[3]);
}

pub fn popStyleColor(count: i32) void {
    c.guava_imgui_pop_style_color(count);
}

pub fn beginChild(id: []const u8, width: f32, height: f32, border: bool) bool {
    return c.guava_imgui_begin_child(id.ptr, id.len, width, height, border);
}

pub fn endChild() void {
    c.guava_imgui_end_child();
}

pub fn beginTable(id: []const u8, columns: i32) bool {
    return c.guava_imgui_begin_table(id.ptr, id.len, columns);
}

pub fn endTable() void {
    c.guava_imgui_end_table();
}

pub fn tableSetupColumn(label: []const u8, stretch: bool, init_width_or_weight: f32) void {
    c.guava_imgui_table_setup_column(label.ptr, label.len, stretch, init_width_or_weight);
}

pub fn tableHeadersRow() void {
    c.guava_imgui_table_headers_row();
}

pub fn tableNextRow() void {
    c.guava_imgui_table_next_row();
}

pub fn tableNextColumn() void {
    c.guava_imgui_table_next_column();
}

pub fn selectable(label: []const u8, selected: bool, span_all_columns: bool, width: f32, height: f32) bool {
    return c.guava_imgui_selectable(label.ptr, label.len, selected, span_all_columns, width, height);
}

pub fn text(value: []const u8) void {
    c.guava_imgui_text(value.ptr, value.len);
}

pub fn labelText(label: []const u8, value: []const u8) void {
    c.guava_imgui_label_text(label.ptr, label.len, value.ptr, value.len);
}

pub fn pushIdU64(value: u64) void {
    c.guava_imgui_push_id_u64(value);
}

pub fn popId() void {
    c.guava_imgui_pop_id();
}

pub fn treeNodeEntity(id: u64, label: []const u8, selected: bool, leaf: bool, default_open: bool) bool {
    return c.guava_imgui_tree_node_entity(id, label.ptr, label.len, selected, leaf, default_open);
}

pub fn treePop() void {
    c.guava_imgui_tree_pop();
}

pub fn isItemClicked() bool {
    return c.guava_imgui_is_item_clicked();
}

pub fn isItemActive() bool {
    return c.guava_imgui_is_item_active();
}

pub fn isItemHovered() bool {
    return c.guava_imgui_is_item_hovered();
}

pub fn isItemDeactivatedAfterEdit() bool {
    return c.guava_imgui_is_item_deactivated_after_edit();
}

pub fn inputText(label: []const u8, buffer: []u8) bool {
    return c.guava_imgui_input_text(label.ptr, label.len, buffer.ptr, buffer.len);
}

pub fn dragFloat(label: []const u8, value: *f32, speed: f32, min_value: f32, max_value: f32) bool {
    return c.guava_imgui_drag_float(label.ptr, label.len, value, speed, min_value, max_value);
}

pub fn dragFloat3(label: []const u8, value: *[3]f32, speed: f32, min_value: f32, max_value: f32) bool {
    return c.guava_imgui_drag_float3(label.ptr, label.len, value, speed, min_value, max_value);
}

pub fn checkbox(label: []const u8, value: *bool) bool {
    return c.guava_imgui_checkbox(label.ptr, label.len, value);
}

pub fn collapsingHeader(label: []const u8, default_open: bool) bool {
    return c.guava_imgui_collapsing_header(label.ptr, label.len, default_open);
}

pub fn dragDropSourceU64(payload_type: []const u8, value: u64, preview_text: []const u8) bool {
    return c.guava_imgui_drag_drop_source_u64(payload_type.ptr, payload_type.len, value, preview_text.ptr, preview_text.len);
}

pub fn acceptDragDropPayloadU64(payload_type: []const u8, out_value: *u64) bool {
    return c.guava_imgui_accept_drag_drop_payload_u64(payload_type.ptr, payload_type.len, out_value);
}

pub fn isWindowHovered() bool {
    return c.guava_imgui_is_window_hovered();
}

pub fn isWindowFocused() bool {
    return c.guava_imgui_is_window_focused();
}

pub fn contentRegionAvail() [2]f32 {
    var value = [2]f32{ 0.0, 0.0 };
    c.guava_imgui_get_content_region_avail(@ptrCast(&value[0]));
    return value;
}

pub fn cursorScreenPos() [2]f32 {
    var value = [2]f32{ 0.0, 0.0 };
    c.guava_imgui_get_cursor_screen_pos(@ptrCast(&value[0]));
    return value;
}

pub fn image(texture: *const rhi_mod.Texture, width: f32, height: f32) void {
    c.guava_imgui_image(@ptrCast(texture.raw), width, height);
}

fn textureFormatToSdl(format: rhi_types.TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
        .bgra8_unorm_srgb => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB)),
        else => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
    };
}
