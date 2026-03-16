const std = @import("std");

pub const Key = enum(u8) {
    w,
    a,
    s,
    d,
    q,
    e,
    f,
    tab,
    delete,
    backspace,
    one,
    two,
    three,
    l,
    shift,
    ctrl,
    alt,
    space,
    escape,
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

const key_count = std.meta.fields(Key).len;
const mouse_button_count = std.meta.fields(MouseButton).len;

pub const InputState = struct {
    modifiers: Modifiers = .{},
    mouse_position: [2]f32 = .{ 0.0, 0.0 },
    mouse_delta: [2]f32 = .{ 0.0, 0.0 },
    mouse_wheel: [2]f32 = .{ 0.0, 0.0 },
    key_down: [key_count]bool = [_]bool{false} ** key_count,
    key_pressed: [key_count]bool = [_]bool{false} ** key_count,
    key_released: [key_count]bool = [_]bool{false} ** key_count,
    mouse_down: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    mouse_pressed: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
    mouse_released: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,

    pub fn beginFrame(self: *InputState) void {
        @memset(self.key_pressed[0..], false);
        @memset(self.key_released[0..], false);
        @memset(self.mouse_pressed[0..], false);
        @memset(self.mouse_released[0..], false);
        self.mouse_delta = .{ 0.0, 0.0 };
        self.mouse_wheel = .{ 0.0, 0.0 };
    }

    pub fn setModifiers(self: *InputState, modifiers: Modifiers) void {
        self.modifiers = modifiers;
    }

    pub fn setKey(self: *InputState, key: Key, is_down: bool) void {
        const index = @intFromEnum(key);
        const was_down = self.key_down[index];
        if (is_down) {
            if (!was_down) {
                self.key_pressed[index] = true;
            }
        } else if (was_down) {
            self.key_released[index] = true;
        }
        self.key_down[index] = is_down;
    }

    pub fn setMouseButton(self: *InputState, button: MouseButton, is_down: bool) void {
        const index = @intFromEnum(button);
        const was_down = self.mouse_down[index];
        if (is_down) {
            if (!was_down) {
                self.mouse_pressed[index] = true;
            }
        } else if (was_down) {
            self.mouse_released[index] = true;
        }
        self.mouse_down[index] = is_down;
    }

    pub fn updateMousePosition(self: *InputState, x: f32, y: f32) void {
        self.mouse_position = .{ x, y };
    }

    pub fn addMouseDelta(self: *InputState, x: f32, y: f32, delta_x: f32, delta_y: f32) void {
        self.mouse_position = .{ x, y };
        self.mouse_delta[0] += delta_x;
        self.mouse_delta[1] += delta_y;
    }

    pub fn addMouseWheel(self: *InputState, wheel_x: f32, wheel_y: f32) void {
        self.mouse_wheel[0] += wheel_x;
        self.mouse_wheel[1] += wheel_y;
    }

    pub fn isKeyDown(self: *const InputState, key: Key) bool {
        return self.key_down[@intFromEnum(key)];
    }

    pub fn wasKeyPressed(self: *const InputState, key: Key) bool {
        return self.key_pressed[@intFromEnum(key)];
    }

    pub fn wasKeyReleased(self: *const InputState, key: Key) bool {
        return self.key_released[@intFromEnum(key)];
    }

    pub fn isMouseDown(self: *const InputState, button: MouseButton) bool {
        return self.mouse_down[@intFromEnum(button)];
    }

    pub fn wasMousePressed(self: *const InputState, button: MouseButton) bool {
        return self.mouse_pressed[@intFromEnum(button)];
    }

    pub fn wasMouseReleased(self: *const InputState, button: MouseButton) bool {
        return self.mouse_released[@intFromEnum(button)];
    }
};
