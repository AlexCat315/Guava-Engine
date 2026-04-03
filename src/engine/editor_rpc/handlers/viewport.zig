///! handlers/viewport.zig — viewport & gizmo control + native window embedding.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const sdl = @import("../../platform/sdl.zig").c;

pub fn setGizmoMode(ctx: *Ctx) !void {
    // TODO: wire to EditorState.manipulation_mode when bridge is available
    _ = try ctx.param([]const u8, "mode");
    try ctx.reply(.{});
}

/// Reposition and resize the engine's SDL window to the given screen rect.
/// Called by Electron when the viewport area changes position or size.
pub fn setRect(ctx: *Ctx) !void {
    const x = try ctx.param(i64, "x");
    const y = try ctx.param(i64, "y");
    const width = try ctx.param(i64, "width");
    const height = try ctx.param(i64, "height");

    const win = ctx.layer.window;

    // Make window borderless for clean embedding (idempotent)
    _ = sdl.SDL_SetWindowBordered(win.handle, false);

    // Reposition
    try win.setPosition(@intCast(x), @intCast(y));

    // Resize
    if (!sdl.SDL_SetWindowSize(win.handle, @intCast(width), @intCast(height))) {
        std.log.err("viewport.setRect: SDL_SetWindowSize failed", .{});
        return error.SdlWindowOperationFailed;
    }
    try win.refreshSizes();

    try ctx.reply(.{});
}

/// Return information about the engine's native window for embedding.
pub fn getWindowInfo(ctx: *Ctx) !void {
    const win = ctx.layer.window;
    const pos = try win.position();

    // Get platform-specific native window handle
    const native_handle: u64 = blk: {
        if (win.nativeCocoaWindow()) |ptr| break :blk @intFromPtr(ptr);
        if (win.nativeWin32Hwnd()) |ptr| break :blk @intFromPtr(ptr);
        break :blk 0;
    };

    const platform: []const u8 = blk: {
        if (win.nativeCocoaWindow() != null) break :blk "macos";
        if (win.nativeWin32Hwnd() != null) break :blk "windows";
        break :blk "unknown";
    };

    try ctx.reply(.{
        .x = pos[0],
        .y = pos[1],
        .width = win.logical_width,
        .height = win.logical_height,
        .drawableWidth = win.drawable_width,
        .drawableHeight = win.drawable_height,
        .nativeHandle = native_handle,
        .platform = platform,
    });
}

/// Attach the engine's SDL window as a child of an external native window.
/// On macOS, parentHandle should be the integer value of an NSView* pointer.
pub fn attachToParent(ctx: *Ctx) !void {
    const handle_value = try ctx.param(u64, "parentHandle");
    if (handle_value == 0) return error.InvalidArguments;

    const parent_ptr: *anyopaque = @ptrFromInt(handle_value);
    const win = ctx.layer.window;

    if (!win.attachToParent(parent_ptr)) {
        std.log.err("viewport.attachToParent: native attach failed", .{});
        return error.NativeWindowOperationFailed;
    }

    try ctx.reply(.{});
}

/// Detach the engine's SDL window from its parent.
pub fn detachFromParent(ctx: *Ctx) !void {
    const win = ctx.layer.window;
    _ = win.detachFromParent();
    try ctx.reply(.{});
}
