const std = @import("std");
const engine = @import("guava");

const EditorState = @import("../core/state.zig").EditorState;
const icon_cache = @import("icon_cache.zig");

pub const paths = struct {
    pub const toolbar = struct {
        pub const select = "assets/ui/icons/heroicons/24/solid/cursor-arrow-rays.svg";
        pub const move = "assets/ui/icons/heroicons/24/solid/arrows-up-down.svg";
        pub const rotate = "assets/ui/icons/heroicons/24/solid/arrow-path.svg";
        pub const scale = "assets/ui/icons/heroicons/24/solid/arrows-pointing-out.svg";
        pub const camera = "assets/ui/icons/heroicons/24/solid/camera.svg";
        pub const material = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const overlay = "assets/ui/icons/heroicons/24/solid/eye.svg";
        pub const snap_translate = "assets/ui/icons/heroicons/24/solid/arrows-up-down.svg";
        pub const snap_rotate = "assets/ui/icons/heroicons/24/solid/arrow-path.svg";
        pub const snap_scale = "assets/ui/icons/heroicons/24/solid/arrows-pointing-out.svg";
        pub const folder = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const play = "assets/ui/icons/heroicons/24/solid/play.svg";
        pub const pause = "assets/ui/icons/heroicons/24/solid/pause.svg";
        pub const step = "assets/ui/icons/heroicons/24/solid/forward.svg";
        pub const settings = "assets/ui/icons/heroicons/24/solid/cog-6-tooth.svg";
    };

    pub const viewport = struct {
        pub const perspective = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const top = "assets/ui/icons/heroicons/24/solid/arrows-up-down.svg";
        pub const side = "assets/ui/icons/heroicons/24/solid/cursor-arrow-rays.svg";
        pub const textured = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const wireframe = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const unlit = "assets/ui/icons/heroicons/24/solid/eye.svg";
        pub const grid = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
    };

    pub const place_actors = struct {
        pub const empty = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const camera = "assets/ui/icons/heroicons/24/solid/camera.svg";
        pub const cube = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const sphere = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const plane = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const point_light = "assets/ui/icons/heroicons/24/solid/light-bulb.svg";
        pub const spot_light = "assets/ui/icons/heroicons/24/solid/light-bulb.svg";
        pub const directional_light = "assets/ui/icons/heroicons/24/solid/light-bulb.svg";
    };

    pub const hierarchy = struct {
        pub const camera = "assets/ui/icons/heroicons/24/solid/camera.svg";
        pub const light = "assets/ui/icons/heroicons/24/solid/light-bulb.svg";
        pub const mesh = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const object = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const folder = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
        pub const eye = "assets/ui/icons/heroicons/24/solid/eye.svg";
        pub const eye_off = "assets/ui/icons/heroicons/24/solid/eye-slash.svg";
        pub const lock = "assets/ui/icons/heroicons/24/solid/lock-closed.svg";
        pub const unlock = "assets/ui/icons/heroicons/24/solid/lock-open.svg";
    };
};

pub const ButtonPalette = struct {
    button: [4]f32,
    hovered: [4]f32,
    active: [4]f32,
};

pub const palettes = struct {
    pub const toolbar_idle = ButtonPalette{
        .button = .{ 0.18, 0.20, 0.23, 0.66 },
        .hovered = .{ 0.24, 0.27, 0.31, 0.82 },
        .active = .{ 0.22, 0.25, 0.29, 0.92 },
    };
    pub const toolbar_active = ButtonPalette{
        .button = .{ 0.24, 0.41, 0.60, 0.84 },
        .hovered = .{ 0.28, 0.48, 0.69, 0.92 },
        .active = .{ 0.21, 0.35, 0.52, 0.96 },
    };
    pub const status_on = ButtonPalette{
        .button = .{ 0.20, 0.28, 0.31, 0.64 },
        .hovered = .{ 0.24, 0.34, 0.39, 0.82 },
        .active = .{ 0.18, 0.26, 0.30, 0.92 },
    };
    pub const status_off = ButtonPalette{
        .button = .{ 0.17, 0.18, 0.20, 0.52 },
        .hovered = .{ 0.22, 0.24, 0.28, 0.72 },
        .active = .{ 0.18, 0.20, 0.23, 0.84 },
    };
};

pub fn entityIconPath(entity: *const engine.scene.Entity) []const u8 {
    if (entity.is_folder) {
        return paths.hierarchy.folder;
    }
    if (entity.camera != null) {
        return paths.hierarchy.camera;
    }
    if (entity.light != null) {
        return paths.hierarchy.light;
    }
    if (entity.mesh != null) {
        return paths.hierarchy.mesh;
    }
    return paths.hierarchy.object;
}

pub fn ensureTintedIconTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    path: []const u8,
    size: f32,
    tint: [4]u8,
) !*engine.rhi.Texture {
    const window = layer_context.window;
    const drawable_scale = blk: {
        if (window.logical_width == 0 or window.logical_height == 0 or window.drawable_width == 0 or window.drawable_height == 0) {
            break :blk 1.0;
        }
        const scale_x = @as(f32, @floatFromInt(window.drawable_width)) / @as(f32, @floatFromInt(window.logical_width));
        const scale_y = @as(f32, @floatFromInt(window.drawable_height)) / @as(f32, @floatFromInt(window.logical_height));
        break :blk std.math.clamp(@max(scale_x, scale_y), 1.0, 4.0);
    };
    const oversample: f32 = if (size <= 20.0) 1.8 else 1.5;
    const pixel_size = @max(@as(u32, @intFromFloat(std.math.ceil(@max(size, @as(f32, 1.0)) * drawable_scale * oversample))), 1);
    return icon_cache.ensureIconTexture(state, layer_context, path, pixel_size, pixel_size, tint);
}

pub fn drawIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    size: f32,
    tint: [4]u8,
    palette: ButtonPalette,
) !bool {
    const texture = try ensureTintedIconTexture(state, layer_context, path, size, tint);
    const padding = if (size >= 28.0) [2]f32{ 6.0, 6.0 } else [2]f32{ 3.0, 3.0 };
    engine.ui.ImGui.pushStyleColor(.button, palette.button);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette.hovered);
    engine.ui.ImGui.pushStyleColor(.button_active, palette.active);
    engine.ui.ImGui.pushStyleVarVec2(.frame_padding, padding);
    engine.ui.ImGui.pushStyleVarFloat(.frame_rounding, if (size >= 28.0) 10.0 else 7.0);
    defer {
        engine.ui.ImGui.popStyleVar(2);
        engine.ui.ImGui.popStyleColor(3);
    }
    return engine.ui.ImGui.imageButton(id, texture, size, size, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}
