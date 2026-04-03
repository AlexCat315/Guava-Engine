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

// ── Render settings ──────────────────────────────────────────────

const render_types = @import("../../render/types.zig");
const ViewportState = render_types.EditorViewportState;

/// Compute high-level shading mode from render_mode + pipeline_mode.
fn shadingModeName(state: *const ViewportState) []const u8 {
    if (state.pipeline_mode == .path_trace) return "rendered";
    return switch (state.render_mode) {
        .textured => "material",
        .wireframe => "wireframe",
        .unlit => "solid",
    };
}

/// Return current viewport render settings.
pub fn getRenderSettings(ctx: *Ctx) !void {
    const state = &ctx.layer.renderer.editor_viewport_state;
    try ctx.reply(.{
        .shadingMode = shadingModeName(state),
        .showGrid = state.show_grid,
        .showBones = state.show_bones,
        .showCollision = state.show_collision,
        .bloomEnabled = state.bloom_enabled,
        .bloomThreshold = state.bloom_threshold,
        .bloomIntensity = state.bloom_intensity,
        .exposureEnabled = state.exposure_enabled,
        .exposure = state.exposure,
        .ssaoEnabled = state.ssao_enabled,
        .ssaoRadius = state.ssao_radius,
        .ssaoIntensity = state.ssao_intensity,
        .fxaaEnabled = state.fxaa_enabled,
        .taaEnabled = state.taa_enabled,
        .contactShadowsEnabled = state.contact_shadows_enabled,
        .colorGradingEnabled = state.color_grading_enabled,
        .colorGradingSaturation = state.color_grading_saturation,
        .colorGradingContrast = state.color_grading_contrast,
        .colorGradingGamma = state.color_grading_gamma,
        .dofEnabled = state.dof_enabled,
        .dofFocusDistance = state.dof_focus_distance,
        .dofFocusRange = state.dof_focus_range,
    });
}

/// Apply partial viewport render settings (only provided fields are updated).
pub fn setRenderSettings(ctx: *Ctx) !void {
    var state = ctx.layer.renderer.editor_viewport_state;

    // High-level shading mode shortcut
    if (try ctx.paramOpt([]const u8, "shadingMode")) |mode| {
        if (std.mem.eql(u8, mode, "solid")) {
            state.pipeline_mode = .raster;
            state.render_mode = .unlit;
        } else if (std.mem.eql(u8, mode, "material")) {
            state.pipeline_mode = .raster;
            state.render_mode = .textured;
        } else if (std.mem.eql(u8, mode, "rendered")) {
            state.pipeline_mode = .path_trace;
            state.render_mode = .textured;
        } else if (std.mem.eql(u8, mode, "wireframe")) {
            state.pipeline_mode = .raster;
            state.render_mode = .wireframe;
        }
    }

    // Visibility toggles
    if (try ctx.paramOpt(bool, "showGrid")) |v| state.show_grid = v;
    if (try ctx.paramOpt(bool, "showBones")) |v| state.show_bones = v;
    if (try ctx.paramOpt(bool, "showCollision")) |v| state.show_collision = v;

    // Bloom
    if (try ctx.paramOpt(bool, "bloomEnabled")) |v| state.bloom_enabled = v;
    if (try ctx.paramOpt(f64, "bloomThreshold")) |v| state.bloom_threshold = @floatCast(v);
    if (try ctx.paramOpt(f64, "bloomIntensity")) |v| state.bloom_intensity = @floatCast(v);

    // Exposure
    if (try ctx.paramOpt(bool, "exposureEnabled")) |v| state.exposure_enabled = v;
    if (try ctx.paramOpt(f64, "exposure")) |v| state.exposure = @floatCast(v);

    // SSAO
    if (try ctx.paramOpt(bool, "ssaoEnabled")) |v| state.ssao_enabled = v;
    if (try ctx.paramOpt(f64, "ssaoRadius")) |v| state.ssao_radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssaoIntensity")) |v| state.ssao_intensity = @floatCast(v);

    // Anti-aliasing
    if (try ctx.paramOpt(bool, "fxaaEnabled")) |v| state.fxaa_enabled = v;
    if (try ctx.paramOpt(bool, "taaEnabled")) |v| state.taa_enabled = v;

    // Contact Shadows
    if (try ctx.paramOpt(bool, "contactShadowsEnabled")) |v| state.contact_shadows_enabled = v;

    // Color Grading
    if (try ctx.paramOpt(bool, "colorGradingEnabled")) |v| state.color_grading_enabled = v;
    if (try ctx.paramOpt(f64, "colorGradingSaturation")) |v| state.color_grading_saturation = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorGradingContrast")) |v| state.color_grading_contrast = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorGradingGamma")) |v| state.color_grading_gamma = @floatCast(v);

    // DOF
    if (try ctx.paramOpt(bool, "dofEnabled")) |v| state.dof_enabled = v;
    if (try ctx.paramOpt(f64, "dofFocusDistance")) |v| state.dof_focus_distance = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofFocusRange")) |v| state.dof_focus_range = @floatCast(v);

    ctx.layer.renderer.setEditorViewportState(state);
    try ctx.reply(.{});
}
