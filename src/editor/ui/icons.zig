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
        pub const play = "assets/ui/icons/heroicons/24/solid/play.svg";
        pub const pause = "assets/ui/icons/heroicons/24/solid/pause.svg";
        pub const step = "assets/ui/icons/heroicons/24/solid/forward.svg";
        pub const settings = "assets/ui/icons/heroicons/24/solid/cog-6-tooth.svg";
    };

    pub const hierarchy = struct {
        pub const camera = "assets/ui/icons/heroicons/24/solid/camera.svg";
        pub const light = "assets/ui/icons/heroicons/24/solid/light-bulb.svg";
        pub const mesh = "assets/ui/icons/heroicons/24/solid/cube.svg";
        pub const object = "assets/ui/icons/heroicons/24/solid/squares-2x2.svg";
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
        .button = .{ 0.24, 0.26, 0.30, 1.0 },
        .hovered = .{ 0.31, 0.34, 0.39, 1.0 },
        .active = .{ 0.35, 0.39, 0.45, 1.0 },
    };
    pub const toolbar_active = ButtonPalette{
        .button = .{ 0.21, 0.40, 0.67, 1.0 },
        .hovered = .{ 0.26, 0.48, 0.78, 1.0 },
        .active = .{ 0.18, 0.34, 0.58, 1.0 },
    };
    pub const status_on = ButtonPalette{
        .button = .{ 0.16, 0.34, 0.24, 1.0 },
        .hovered = .{ 0.20, 0.42, 0.29, 1.0 },
        .active = .{ 0.14, 0.28, 0.20, 1.0 },
    };
    pub const status_off = ButtonPalette{
        .button = .{ 0.23, 0.24, 0.27, 1.0 },
        .hovered = .{ 0.29, 0.31, 0.35, 1.0 },
        .active = .{ 0.19, 0.20, 0.23, 1.0 },
    };
};

pub fn entityIconPath(entity: *const engine.scene.Entity) []const u8 {
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
    const pixel_size = @max(@as(u32, @intFromFloat(std.math.ceil(@max(size, 1.0)))), 1);
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
    engine.ui.ImGui.pushStyleColor(.button, palette.button);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette.hovered);
    engine.ui.ImGui.pushStyleColor(.button_active, palette.active);
    defer engine.ui.ImGui.popStyleColor(3);
    return engine.ui.ImGui.imageButton(id, texture, size, size, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}
