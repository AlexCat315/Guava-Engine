const std = @import("std");
const input_mod = @import("../core/input.zig");
const sdl = @import("sdl.zig").c;

pub const WindowConfig = struct {
    title: []const u8 = "Guava Engine",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
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
    width: u32 = 0,
    height: u32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    delta_x: f32 = 0.0,
    delta_y: f32 = 0.0,
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
    should_close: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: WindowConfig) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            std.log.err("SDL_Init failed: {s}", .{lastError()});
            return error.SdlInitFailed;
        }
        errdefer sdl.SDL_Quit();

        const title_z = try allocator.dupeZ(u8, config.title);
        defer allocator.free(title_z);

        var flags: sdl.SDL_WindowFlags = 0;
        if (config.resizable) {
            flags |= sdl.SDL_WINDOW_RESIZABLE;
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

        var window = Window{
            .handle = handle.?,
        };
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
    }

    pub fn pollEvent(self: *Window) !?Event {
        var raw_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&raw_event)) {
            switch (raw_event.type) {
                sdl.SDL_EVENT_QUIT => {
                    self.should_close = true;
                    return .{ .kind = .quit_requested };
                },
                sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    self.should_close = true;
                    return .{ .kind = .close_requested };
                },
                sdl.SDL_EVENT_WINDOW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .resized,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .pixel_size_changed,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_METAL_VIEW_RESIZED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .metal_view_resized,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_WINDOW_EXPOSED => {
                    try self.refreshSizes();
                    return .{
                        .kind = .exposed,
                        .width = self.drawable_width,
                        .height = self.drawable_height,
                    };
                },
                sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (raw_event.button.down) {
                        const button = mouseButtonFromSdl(raw_event.button.button) orelse continue;
                        return .{
                            .kind = .mouse_button_down,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
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
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                            .button = button,
                            .modifiers = currentModifiers(),
                        };
                    }
                },
                sdl.SDL_EVENT_MOUSE_MOTION => {
                    return .{
                        .kind = .mouse_moved,
                        .x = raw_event.motion.x,
                        .y = raw_event.motion.y,
                        .delta_x = raw_event.motion.xrel,
                        .delta_y = raw_event.motion.yrel,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    return .{
                        .kind = .mouse_wheel,
                        .delta_x = raw_event.wheel.x,
                        .delta_y = raw_event.wheel.y,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_DOWN => {
                    return .{
                        .kind = .key_down,
                        .key = keyFromScancode(raw_event.key.scancode),
                        .repeat = raw_event.key.repeat,
                        .modifiers = currentModifiers(),
                    };
                },
                sdl.SDL_EVENT_KEY_UP => {
                    return .{
                        .kind = .key_up,
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
};

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
