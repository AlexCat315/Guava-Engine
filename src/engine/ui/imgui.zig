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

pub fn sameLine() void {
    c.guava_imgui_same_line();
}

pub fn separator() void {
    c.guava_imgui_separator();
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

fn textureFormatToSdl(format: rhi_types.TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
        .bgra8_unorm_srgb => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB)),
        else => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
    };
}
