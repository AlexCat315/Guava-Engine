const std = @import("std");
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

pub const Col = enum(u32) {
    text = 0,
    text_disabled = 1,
    window_bg = 5,
    child_bg = 6,
    popup_bg = 8,
    border = 9,
    frame_bg = 10,
    frame_bg_hovered = 11,
    frame_bg_active = 12,
    title_bg = 13,
    title_bg_active = 14,
    title_bg_collapsed = 15,
    menu_bar_bg = 16,
    scrollbar_bg = 17,
    scrollbar_grab = 18,
    scrollbar_grab_hovered = 19,
    scrollbar_grab_active = 20,
    check_mark = 21,
    slider_grab = 22,
    slider_grab_active = 23,
    button = 24,
    button_hovered = 25,
    button_active = 26,
    header = 27,
    header_hovered = 28,
    header_active = 29,
    separator = 30,
    separator_hovered = 31,
    separator_active = 32,
    resize_grip = 33,
    resize_grip_hovered = 34,
    resize_grip_active = 35,
    tab = 36,
    tab_hovered = 37,
    tab_active = 38,
    tab_unfocused = 39,
    tab_unfocused_active = 40,
    docking_preview = 41,
    docking_empty_bg = 42,
    plot_lines = 43,
    plot_lines_hovered = 44,
    plot_histogram = 45,
    plot_histogram_hovered = 46,
    table_header_bg = 47,
    table_border_strong = 48,
    table_border_light = 49,
    table_row_bg = 50,
    table_row_bg_alt = 51,
    text_selected_bg = 52,
    drag_drop_target = 53,
    nav_cursor = 54,
    nav_highlight = 55,
    nav_windowing_highlight = 56,
    nav_windowing_dim_bg = 57,
    modal_window_dim_bg = 58,
};

pub const StyleVar = enum(c_uint) {
    alpha = c.GUAVA_IMGUI_STYLE_VAR_ALPHA,
    frame_padding = c.GUAVA_IMGUI_STYLE_VAR_FRAME_PADDING,
    item_spacing = c.GUAVA_IMGUI_STYLE_VAR_ITEM_SPACING,
    frame_rounding = c.GUAVA_IMGUI_STYLE_VAR_FRAME_ROUNDING,
    window_min_size = c.GUAVA_IMGUI_STYLE_VAR_WINDOW_MIN_SIZE,
    window_padding = c.GUAVA_IMGUI_STYLE_VAR_WINDOW_PADDING,
};

pub const TreeNodeEntityResult = struct {
    open: bool = false,
    clicked: bool = false,
    rename_committed: bool = false,
    rename_finished: bool = false,
};

pub const ViewCubeFace = enum(c_uint) {
    none = c.GUAVA_IMGUI_VIEW_CUBE_NONE,
    front = c.GUAVA_IMGUI_VIEW_CUBE_FRONT,
    back = c.GUAVA_IMGUI_VIEW_CUBE_BACK,
    left = c.GUAVA_IMGUI_VIEW_CUBE_LEFT,
    right = c.GUAVA_IMGUI_VIEW_CUBE_RIGHT,
    top = c.GUAVA_IMGUI_VIEW_CUBE_TOP,
    bottom = c.GUAVA_IMGUI_VIEW_CUBE_BOTTOM,
};

pub const ViewCubeResult = struct {
    face: ViewCubeFace = .none,
    hovered: bool = false,
    active: bool = false,
    dragging: bool = false,
    drag_delta: [2]f32 = .{ 0.0, 0.0 },
};

pub const WindowFlags = struct {
    pub const none: u32 = c.GUAVA_IMGUI_WINDOW_NONE;
    pub const no_title_bar: u32 = c.GUAVA_IMGUI_WINDOW_NO_TITLE_BAR;
    pub const no_resize: u32 = c.GUAVA_IMGUI_WINDOW_NO_RESIZE;
    pub const no_move: u32 = c.GUAVA_IMGUI_WINDOW_NO_MOVE;
    pub const no_scrollbar: u32 = c.GUAVA_IMGUI_WINDOW_NO_SCROLLBAR;
    pub const no_scroll_with_mouse: u32 = c.GUAVA_IMGUI_WINDOW_NO_SCROLL_WITH_MOUSE;
    pub const no_saved_settings: u32 = c.GUAVA_IMGUI_WINDOW_NO_SAVED_SETTINGS;
    pub const no_docking: u32 = c.GUAVA_IMGUI_WINDOW_NO_DOCKING;
    pub const no_collapse: u32 = c.GUAVA_IMGUI_WINDOW_NO_COLLAPSE;
    pub const no_background: u32 = c.GUAVA_IMGUI_WINDOW_NO_BACKGROUND;
    pub const no_decoration: u32 = c.GUAVA_IMGUI_WINDOW_NO_DECORATION;
    pub const always_auto_resize: u32 = c.GUAVA_IMGUI_WINDOW_ALWAYS_AUTO_RESIZE;
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

pub fn loadAnimationLayout() void {
    c.guava_imgui_load_animation_layout();
}

pub fn saveLayout() void {
    c.guava_imgui_save_layout();
}

pub fn saveLayoutToPath(path: []const u8) bool {
    return c.guava_imgui_save_layout_to_path(path.ptr, path.len);
}

pub fn loadLayoutFromPath(path: []const u8) bool {
    return c.guava_imgui_load_layout_from_path(path.ptr, path.len);
}

pub fn editorPrefPathAlloc(allocator: std.mem.Allocator) (error{PreferencePathUnavailable} || std.mem.Allocator.Error)![]u8 {
    const pref_path = sdl.SDL_GetPrefPath("Guava", "Editor") orelse return error.PreferencePathUnavailable;
    defer sdl.SDL_free(pref_path);
    return allocator.dupe(u8, std.mem.span(pref_path));
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

pub fn wantsTextInput() bool {
    return c.guava_imgui_want_text_input();
}

pub fn getItemRectMin() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    c.guava_imgui_get_item_rect_min(&x, &y);
    return .{ x, y };
}

pub fn getItemRectMax() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    c.guava_imgui_get_item_rect_max(&x, &y);
    return .{ x, y };
}

pub fn getColorU32(color: [4]f32) u32 {
    return c.guava_imgui_get_color_u32(color[0], color[1], color[2], color[3]);
}

pub fn getColorU32Slot(slot: Col) u32 {
    return c.guava_imgui_get_color_u32_idx(@intFromEnum(slot));
}

pub const DrawList = struct {
    pub fn addLine(self: DrawList, p1: [2]f32, p2: [2]f32, color: u32, thickness: f32) void {
        _ = self;
        c.guava_imgui_draw_list_add_line(p1[0], p1[1], p2[0], p2[1], color, thickness);
    }
};

pub fn getWindowDrawList() DrawList {
    return .{};
}

pub fn beginWindow(name: []const u8) bool {
    return c.guava_imgui_begin_window(name.ptr, name.len);
}

pub fn beginWindowFlags(name: []const u8, flags: u32) bool {
    return c.guava_imgui_begin_window_flags(name.ptr, name.len, flags);
}

pub fn beginWindowOpen(name: []const u8, open: *bool) bool {
    return c.guava_imgui_begin_window_open(name.ptr, name.len, open);
}

pub fn beginWindowFlagsOpen(name: []const u8, open: *bool, flags: u32) bool {
    return c.guava_imgui_begin_window_flags_open(name.ptr, name.len, open, flags);
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

pub fn openPopup(id: []const u8) void {
    c.guava_imgui_open_popup(id.ptr, id.len);
}

pub fn beginPopup(id: []const u8) bool {
    return c.guava_imgui_begin_popup(id.ptr, id.len);
}

pub fn isPopupOpen(id: []const u8) bool {
    return c.guava_imgui_is_popup_open(id.ptr, id.len);
}

pub fn beginPopupContextItem(id: ?[]const u8) bool {
    return c.guava_imgui_begin_popup_context_item(
        if (id) |value| value.ptr else null,
        if (id) |value| value.len else 0,
    );
}

pub fn beginPopupContextWindow(id: ?[]const u8, open_over_items: bool) bool {
    return c.guava_imgui_begin_popup_context_window(
        if (id) |value| value.ptr else null,
        if (id) |value| value.len else 0,
        open_over_items,
    );
}

pub fn endPopup() void {
    c.guava_imgui_end_popup();
}

pub fn beginCombo(label: []const u8, preview: ?[]const u8) bool {
    return c.guava_imgui_begin_combo(
        label.ptr,
        label.len,
        if (preview) |value| value.ptr else null,
        if (preview) |value| value.len else 0,
    );
}

pub fn endCombo() void {
    c.guava_imgui_end_combo();
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

pub fn imageButton(id: []const u8, texture: *const rhi_mod.Texture, width: f32, height: f32, bg_tint: [4]f32, icon_tint: [4]f32) bool {
    return c.guava_imgui_image_button(
        id.ptr,
        id.len,
        @ptrCast(texture.raw),
        width,
        height,
        bg_tint[0],
        bg_tint[1],
        bg_tint[2],
        bg_tint[3],
        icon_tint[0],
        icon_tint[1],
        icon_tint[2],
        icon_tint[3],
    );
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

pub fn sameLineEx(offset_from_start_x: f32, spacing: f32) void {
    c.guava_imgui_same_line_ex(offset_from_start_x, spacing);
}

pub fn separator() void {
    c.guava_imgui_separator();
}

pub fn setNextItemWidth(width: f32) void {
    c.guava_imgui_set_next_item_width(width);
}

pub fn setNextWindowPos(position: [2]f32) void {
    c.guava_imgui_set_next_window_pos(position[0], position[1]);
}

pub fn setNextWindowSize(size: [2]f32) void {
    c.guava_imgui_set_next_window_size(size[0], size[1]);
}

pub fn setNextWindowBgAlpha(alpha: f32) void {
    c.guava_imgui_set_next_window_bg_alpha(alpha);
}

pub fn pushStyleColor(slot: StyleColor, color: [4]f32) void {
    c.guava_imgui_push_style_color(@intFromEnum(slot), color[0], color[1], color[2], color[3]);
}

pub fn popStyleColor(count: i32) void {
    c.guava_imgui_pop_style_color(count);
}

pub fn setStyleColor(color_idx: u32, color: [4]f32) void {
    c.guava_imgui_set_style_color(color_idx, color[0], color[1], color[2], color[3]);
}

pub fn setStyleVarFloat(var_idx: u32, value: f32) void {
    c.guava_imgui_set_style_var_float(var_idx, value);
}

pub fn pushStyleVarFloat(slot: StyleVar, value: f32) void {
    c.guava_imgui_push_style_var_float(@intFromEnum(slot), value);
}

pub fn pushStyleVarVec2(slot: StyleVar, value: [2]f32) void {
    c.guava_imgui_push_style_var_vec2(@intFromEnum(slot), value[0], value[1]);
}

pub fn popStyleVar(count: i32) void {
    c.guava_imgui_pop_style_var(count);
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

pub fn setTooltip(value: []const u8) void {
    c.guava_imgui_set_tooltip(value.ptr, value.len);
}

pub fn textWrapped(value: []const u8) void {
    c.guava_imgui_text_wrapped(value.ptr, value.len);
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

pub fn treeNodeEntity(
    id: u64,
    label: []const u8,
    icon_texture: ?*const rhi_mod.Texture,
    icon_size: f32,
    selected: bool,
    leaf: bool,
    default_open: bool,
    rename_buffer: ?[]u8,
    request_rename_focus: bool,
) TreeNodeEntityResult {
    const raw_state = c.guava_imgui_tree_node_entity(
        id,
        label.ptr,
        label.len,
        if (icon_texture) |value| @ptrCast(value.raw) else null,
        icon_size,
        selected,
        leaf,
        default_open,
        if (rename_buffer) |value| value.ptr else null,
        if (rename_buffer) |value| value.len else 0,
        request_rename_focus,
    );
    return .{
        .open = (raw_state & c.GUAVA_IMGUI_TREE_NODE_OPEN) != 0,
        .clicked = (raw_state & c.GUAVA_IMGUI_TREE_NODE_CLICKED) != 0,
        .rename_committed = (raw_state & c.GUAVA_IMGUI_TREE_NODE_RENAME_COMMITTED) != 0,
        .rename_finished = (raw_state & c.GUAVA_IMGUI_TREE_NODE_RENAME_FINISHED) != 0,
    };
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

pub fn inputTextWithHint(label: []const u8, hint: []const u8, buffer: []u8) bool {
    return c.guava_imgui_input_text_with_hint(label.ptr, label.len, hint.ptr, hint.len, buffer.ptr, buffer.len);
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

pub fn beginDragDropSourceU64(payload_type: []const u8, value: u64) bool {
    return c.guava_imgui_begin_drag_drop_source_u64(payload_type.ptr, payload_type.len, value);
}

pub fn endDragDropSource() void {
    c.guava_imgui_end_drag_drop_source();
}

pub fn dragDropSourceU64(payload_type: []const u8, value: u64, preview_text: []const u8) bool {
    if (!beginDragDropSourceU64(payload_type, value)) {
        return false;
    }
    defer endDragDropSource();
    if (preview_text.len > 0) {
        text(preview_text);
    }
    return true;
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

pub fn setCursorPos(position: [2]f32) void {
    c.guava_imgui_set_cursor_pos(position[0], position[1]);
}

pub fn setCursorPosY(y: f32) void {
    c.guava_imgui_set_cursor_pos_y(y);
}

pub fn alignTextToFramePadding() void {
    c.guava_imgui_align_text_to_frame_padding();
}

pub fn indent(width: f32) void {
    c.guava_imgui_indent(width);
}

pub fn unindent(width: f32) void {
    c.guava_imgui_unindent(width);
}

pub fn windowSize() [2]f32 {
    var value = [2]f32{ 0.0, 0.0 };
    c.guava_imgui_get_window_size(@ptrCast(&value[0]));
    return value;
}

pub fn frameHeight() f32 {
    return c.guava_imgui_get_frame_height();
}

pub fn time() f32 {
    return c.guava_imgui_get_time();
}

pub fn setScrollHereY(center_y_ratio: f32) void {
    c.guava_imgui_set_scroll_here_y(center_y_ratio);
}

pub fn image(texture: *const rhi_mod.Texture, width: f32, height: f32) void {
    c.guava_imgui_image(@ptrCast(texture.raw), width, height);
}

pub fn drawViewCube(view: *const [16]f32, position: [2]f32, size: f32) ViewCubeResult {
    var drag_delta = [2]f32{ 0.0, 0.0 };
    const raw = c.guava_imgui_draw_view_cube(@ptrCast(view), position[0], position[1], size, @ptrCast(&drag_delta[0]));
    return .{
        .face = @enumFromInt(raw & 0xff),
        .hovered = (raw & c.GUAVA_IMGUI_VIEW_CUBE_HOVERED) != 0,
        .active = (raw & c.GUAVA_IMGUI_VIEW_CUBE_ACTIVE) != 0,
        .dragging = (raw & c.GUAVA_IMGUI_VIEW_CUBE_DRAGGING) != 0,
        .drag_delta = drag_delta,
    };
}

fn textureFormatToSdl(format: rhi_types.TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
        .bgra8_unorm_srgb => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB)),
        else => @as(c.SDL_GPUTextureFormat, @intCast(c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM)),
    };
}
