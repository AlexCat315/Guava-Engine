const std = @import("std");
const builtin = @import("builtin");
const input_mod = @import("../core/input.zig");
const sdl = @import("sdl.zig").c;

extern fn guava_window_apply_macos_native_titlebar_style(window: *sdl.SDL_Window) bool;
extern fn guava_window_macos_titlebar_leading_inset(window: *sdl.SDL_Window) f32;
extern fn guava_window_apply_windows_native_titlebar_style(window: *sdl.SDL_Window) bool;
extern fn guava_window_windows_titlebar_trailing_inset(window: *sdl.SDL_Window) f32;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const WindowConfig = struct {
    title: []const u8 = "Guava Engine",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
    borderless: bool = false,
    native_titlebar_controls: bool = false,
    high_pixel_density: bool = true,
    hidden: bool = false,
};

pub const EventKind = enum {
    quit_requested,
    close_requested,
    resized,
    pixel_size_changed,
    metal_view_resized,
    exposed,
    mouse_button_down,
    mouse_button_up,
    mouse_moved,
    mouse_wheel,
    key_down,
    key_up,
};

pub const Event = struct {
    kind: EventKind,
    raw: sdl.SDL_Event = undefined,
    width: u32 = 0,
    height: u32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    delta_x: f32 = 0.0,
    delta_y: f32 = 0.0,
    clicks: u8 = 0,
    button: ?input_mod.MouseButton = null,
    key: ?input_mod.Key = null,
    repeat: bool = false,
    modifiers: input_mod.Modifiers = .{},
};

pub const Window = struct {
    handle: *sdl.SDL_Window,
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    drawable_width: u32 = 0,
    drawable_height: u32 = 0,
    native_titlebar_controls: bool = false,
    native_titlebar_leading_inset: f32 = 0.0,
    native_titlebar_trailing_inset: f32 = 0.0,
    should_close: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init failed: {s}", .{lastError()});
            return error.SdlInitFailed;
        }
        errdefer sdl.SDL_Quit();

        const title_z = try allocator.dupeZ(u8, config.title);
        defer allocator.free(title_z);

        const use_native_titlebar_controls = config.native_titlebar_controls and switch (builtin.os.tag) {
            .macos, .windows => true,
            else => false,
        };

        var flags: sdl.SDL_WindowFlags = 0;
        if (config.resizable) {
            flags |= sdl.SDL_WINDOW_RESIZABLE;
        }
        if (config.borderless and !use_native_titlebar_controls) {
            flags |= sdl.SDL_WINDOW_BORDERLESS;
        }
        if (config.high_pixel_density) {
            flags |= sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        }
        if (config.hidden) {
            flags |= sdl.SDL_WINDOW_HIDDEN;
        }

        const handle = sdl.SDL_CreateWindow(
            title_z.ptr,
            @intCast(config.width),
            @intCast(config.height),
            flags,
        );
        if (handle == null) {
            std.log.err("SDL_CreateWindow failed: {s}", .{lastError()});
            return error.SdlWindowCreateFailed;
        }
        errdefer sdl.SDL_DestroyWindow(handle.?);

        var window = Window{
            .handle = handle.?,
            .native_titlebar_controls = use_native_titlebar_controls,
        };
        if (use_native_titlebar_controls) {
            switch (builtin.os.tag) {
                .macos => {
                    if (!guava_window_apply_macos_native_titlebar_style(window.handle)) {
                        return error.SdlWindowOperationFailed;
                    }
                },
                .windows => {
                    if (!guava_window_apply_windows_native_titlebar_style(window.handle)) {
                        return error.SdlWindowOperationFailed;
                    }
                },
                else => unreachable,
            }
            window.refreshNativeTitlebarInsets();
        }
        try window.positionInUsableBounds(config.width, config.height);
        try window.refreshSizes();
        return window;
    }

    pub fn deinit(self: *Window) void {
        sdl.SDL_DestroyWindow(self.handle);
        sdl.SDL_Quit();
    }

    pub fn refreshSizes(self: *Window) !void {
        var logical_w: c_int = 0;
        var logical_h: c_int = 0;
        if (!sdl.SDL_GetWindowSize(self.handle, &logical_w, &logical_h)) {
            std.log.err("SDL_GetWindowSize failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }

        var drawable_w: c_int = 0;
        var drawable_h: c_int = 0;
        if (!sdl.SDL_GetWindowSizeInPixels(self.handle, &drawable_w, &drawable_h)) {
            std.log.err("SDL_GetWindowSizeInPixels failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }

        self.logical_width = @intCast(@max(logical_w, 0));
        self.logical_height = @intCast(@max(logical_h, 0));
        self.drawable_width = @intCast(@max(drawable_w, 0));
        self.drawable_height = @intCast(@max(drawable_h, 0));
        self.refreshNativeTitlebarInsets();
    }

    pub fn pollEvent(self: *Window) !?Event {
        var raw_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&raw_event)) {
            switch (raw_event.type) {
                sdl.SDL_EVENT_QUIT => {
                    self.should_close = true;
                    return .{ .kind = .quit_requested, .raw = raw_event };
                },
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    self.should_close = true;
                    return .{ .kind = .close_requested, .raw = raw_event };
                },
                sdl.SDL_EVENT_WINDOW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .resized,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .pixel_size_changed,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_METAL_VIEW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .metal_view_resized,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_EXPOSED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .exposed,
                        .raw = raw_event,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (raw_event.button.down) {
                        const button = mouseButtonFromSdl(raw_event.button.button) orelse continue;
                        return .{
                            .kind = .mouse_button_down,
                            .raw = raw_event,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                            .clicks = raw_event.button.clicks,
                            .button = button,
                            .modifiers = currentModifiers(),
                        };
                    }
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (!raw_event.button.down) {
                        const button = mouseButtonFromSdl(raw_event.button.button) orelse continue;
                        return .{
                            .kind = .mouse_button_up,
                            .raw = raw_event,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                            .clicks = raw_event.button.clicks,
                            .button = button,
                            .modifiers = currentModifiers(),
                        };
                    }
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    return .{
                        .kind = .mouse_moved,
                        .raw = raw_event,
                        .x = raw_event.motion.x,
                        .y = raw_event.motion.y,
                        .delta_x = raw_event.motion.xrel,
                        .delta_y = raw_event.motion.yrel,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    const direction_sign: f32 = if (raw_event.wheel.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) -1.0 else 1.0;
                    const wheel_x = if (@abs(raw_event.wheel.x) > 0.0001)
                        raw_event.wheel.x
                    else
                        @as(f32, @floatFromInt(raw_event.wheel.integer_x));
                    const wheel_y = if (@abs(raw_event.wheel.y) > 0.0001)
                        raw_event.wheel.y
                    else
                        @as(f32, @floatFromInt(raw_event.wheel.integer_y));
                    return .{
                        .kind = .mouse_wheel,
                        .raw = raw_event,
                        .x = raw_event.wheel.mouse_x,
                        .y = raw_event.wheel.mouse_y,
                        .delta_x = wheel_x * direction_sign,
                        .delta_y = wheel_y * direction_sign,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_DOWN => {
                    return .{
                        .kind = .key_down,
                        .raw = raw_event,
                        .key = keyFromScancode(raw_event.key.scancode),
                        .repeat = raw_event.key.repeat,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_UP => {
                    return .{
                        .kind = .key_up,
                        .raw = raw_event,
                        .key = keyFromScancode(raw_event.key.scancode),
                        .repeat = false,
                        .modifiers = currentModifiers(),
                    };
                },
                else => {},
            }
        }

        return null;
    }

    pub fn delay(_: *Window, milliseconds: u32) void {
        sdl.SDL_Delay(milliseconds);
    }

    pub fn setTitle(self: *Window, allocator: std.mem.Allocator, title: []const u8) !void {
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);
        _ = sdl.SDL_SetWindowTitle(self.handle, title_z.ptr);
    }

    pub fn position(self: *const Window) ![2]i32 {
        var x: c_int = 0;
        var y: c_int = 0;
        if (!sdl.SDL_GetWindowPosition(self.handle, &x, &y)) {
            std.log.err("SDL_GetWindowPosition failed: {s}", .{lastError()});
            return error.SdlQueryFailed;
        }
        return .{ @intCast(x), @intCast(y) };
    }

    pub fn setPosition(self: *Window, x: i32, y: i32) !void {
        if (!sdl.SDL_SetWindowPosition(self.handle, x, y)) {
            std.log.err("SDL_SetWindowPosition failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn globalMousePosition(_: *const Window) [2]f32 {
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        _ = sdl.SDL_GetGlobalMouseState(&x, &y);
        return .{ x, y };
    }

    /// 启用/禁用相对鼠标模式。
    /// 相对模式下光标隐藏并锁定，鼠标增量不受屏幕边缘限制。
    /// 用于摄像机拖拽（轨道/自由视角），防止移动到屏幕边缘后卡住。
    pub fn setRelativeMouseMode(self: *Window, enabled: bool) void {
        _ = sdl.SDL_SetWindowRelativeMouseMode(self.handle, enabled);
    }

    pub fn minimize(self: *Window) !void {
        if (!sdl.SDL_MinimizeWindow(self.handle)) {
            std.log.err("SDL_MinimizeWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn maximize(self: *Window) !void {
        if (!sdl.SDL_MaximizeWindow(self.handle)) {
            std.log.err("SDL_MaximizeWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn restore(self: *Window) !void {
        if (!sdl.SDL_RestoreWindow(self.handle)) {
            std.log.err("SDL_RestoreWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn sync(self: *Window) !void {
        if (!sdl.SDL_SyncWindow(self.handle)) {
            std.log.err("SDL_SyncWindow failed: {s}", .{lastError()});
            return error.SdlWindowOperationFailed;
        }
    }

    pub fn isMaximized(self: *const Window) bool {
        return (sdl.SDL_GetWindowFlags(self.handle) & sdl.SDL_WINDOW_MAXIMIZED) != 0;
    }

    pub fn usableBounds(_: *const Window) !Rect {
        return primaryDisplayUsableBounds();
    }

    pub fn hasNativeTitlebarControls(self: *const Window) bool {
        return self.native_titlebar_controls;
    }

    pub fn titlebarLeadingInset(self: *const Window) f32 {
        return self.native_titlebar_leading_inset;
    }

    pub fn titlebarTrailingInset(self: *const Window) f32 {
        return self.native_titlebar_trailing_inset;
    }

    pub fn requestClose(self: *Window) void {
        self.should_close = true;
    }

    fn positionInUsableBounds(self: *Window, width: u32, height: u32) !void {
        const usable_bounds = primaryDisplayUsableBounds() catch return;

        const window_width: i32 = @intCast(width);
        const window_height: i32 = @intCast(height);
        const usable_width = @max(usable_bounds.w, window_width);
        const usable_height = @max(usable_bounds.h, window_height);
        const target_x = usable_bounds.x + @divTrunc(usable_width - window_width, 2);
        const target_y = usable_bounds.y + @divTrunc(usable_height - window_height, 2);
        try self.setPosition(target_x, target_y);
    }

    fn refreshNativeTitlebarInsets(self: *Window) void {
        if (!self.native_titlebar_controls) {
            self.native_titlebar_leading_inset = 0.0;
            self.native_titlebar_trailing_inset = 0.0;
            return;
        }

        switch (builtin.os.tag) {
            .macos => {
                self.native_titlebar_leading_inset = guava_window_macos_titlebar_leading_inset(self.handle);
                self.native_titlebar_trailing_inset = 0.0;
            },
            .windows => {
                self.native_titlebar_leading_inset = 0.0;
                self.native_titlebar_trailing_inset = guava_window_windows_titlebar_trailing_inset(self.handle);
            },
            else => {
                self.native_titlebar_leading_inset = 0.0;
                self.native_titlebar_trailing_inset = 0.0;
            },
        }
    }
};

fn primaryDisplayUsableBounds() !Rect {
    const display = sdl.SDL_GetPrimaryDisplay();
    if (display == 0) {
        return error.SdlQueryFailed;
    }

    var usable_bounds: sdl.SDL_Rect = undefined;
    if (!sdl.SDL_GetDisplayUsableBounds(display, &usable_bounds)) {
        std.log.warn("SDL_GetDisplayUsableBounds failed: {s}", .{lastError()});
        return error.SdlQueryFailed;
    }

    return .{
        .x = usable_bounds.x,
        .y = usable_bounds.y,
        .w = usable_bounds.w,
        .h = usable_bounds.h,
    };
}

pub fn lastError() []const u8 {
    return std.mem.sliceTo(sdl.SDL_GetError(), 0);
}

fn currentModifiers() input_mod.Modifiers {
    const mods = sdl.SDL_GetModState();
    return .{
        .shift = (mods & sdl.SDL_KMOD_SHIFT) != 0,
        .ctrl = (mods & sdl.SDL_KMOD_CTRL) != 0,
        .alt = (mods & sdl.SDL_KMOD_ALT) != 0,
        .super = (mods & sdl.SDL_KMOD_GUI) != 0,
    };
}

fn mouseButtonFromSdl(button: u8) ?input_mod.MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_RIGHT => .right,
        sdl.SDL_BUTTON_MIDDLE => .middle,
        else => null,
    };
}

fn keyFromScancode(scancode: c_uint) ?input_mod.Key {
    return switch (scancode) {
        sdl.SDL_SCANCODE_W => .w,
        sdl.SDL_SCANCODE_A => .a,
        sdl.SDL_SCANCODE_S => .s,
        sdl.SDL_SCANCODE_D => .d,
        sdl.SDL_SCANCODE_Q => .q,
        sdl.SDL_SCANCODE_E => .e,
        sdl.SDL_SCANCODE_F => .f,
        sdl.SDL_SCANCODE_G => .g,
        sdl.SDL_SCANCODE_R => .r,
        sdl.SDL_SCANCODE_TAB => .tab,
        sdl.SDL_SCANCODE_DELETE => .delete,
        sdl.SDL_SCANCODE_BACKSPACE => .backspace,
        sdl.SDL_SCANCODE_1 => .one,
        sdl.SDL_SCANCODE_2 => .two,
        sdl.SDL_SCANCODE_3 => .three,
        sdl.SDL_SCANCODE_L => .l,
        sdl.SDL_SCANCODE_O => .o,
        sdl.SDL_SCANCODE_P => .p,
        sdl.SDL_SCANCODE_X => .x,
        sdl.SDL_SCANCODE_Y => .y,
        sdl.SDL_SCANCODE_Z => .z,
        sdl.SDL_SCANCODE_LSHIFT, sdl.SDL_SCANCODE_RSHIFT => .shift,
        sdl.SDL_SCANCODE_LCTRL, sdl.SDL_SCANCODE_RCTRL => .ctrl,
        sdl.SDL_SCANCODE_LALT, sdl.SDL_SCANCODE_RALT => .alt,
        sdl.SDL_SCANCODE_SPACE => .space,
        sdl.SDL_SCANCODE_ESCAPE => .escape,
        else => null,
    };
}
