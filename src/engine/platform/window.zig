const std = @import("std");
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
    mouse_primary_down,
};

pub const Event = struct {
    kind: EventKind,
    width: u32 = 0,
    height: u32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
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
                    if (raw_event.button.button == sdl.SDL_BUTTON_LEFT and raw_event.button.down) {
                        return .{
                            .kind = .mouse_primary_down,
                            .x = raw_event.button.x,
                            .y = raw_event.button.y,
                        };
                    }
                },
                else => {},
            }
        }

        return null;
    }

    pub fn delay(_: *Window, milliseconds: u32) void {
        sdl.SDL_Delay(milliseconds);
    }
};

pub fn lastError() []const u8 {
    return std.mem.sliceTo(sdl.SDL_GetError(), 0);
}
