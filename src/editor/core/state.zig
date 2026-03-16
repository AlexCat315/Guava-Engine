const std = @import("std");
const engine = @import("guava");
const i18n = @import("../i18n/mod.zig");

pub const autosave_path = "assets/scenes/editor_autosave.guava_scene";
pub const entity_drag_payload = "guava.scene.entity";

pub const AssetKind = enum {
    scene,
    model,
    texture,
    shader,
};

pub const AssetEntry = struct {
    path: []u8,
    name: []u8,
    kind: AssetKind,
};

pub const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

pub const AxisConstraint = engine.math.axis.Axis3;

pub const EditorState = struct {
    allocator: ?std.mem.Allocator = null,
    editor_camera: ?engine.scene.EntityId = null,
    scene_camera: ?engine.scene.EntityId = null,
    inspector_name_entity: ?engine.scene.EntityId = null,
    inspector_name_buffer: [256]u8 = [_]u8{0} ** 256,
    editor_camera_active: bool = true,
    focus_pivot: [3]f32 = .{ 0.0, 1.0, 0.0 },
    yaw: f32 = 0.0,
    pitch: f32 = -0.18,
    orbit_distance: f32 = 8.0,
    look_sensitivity: f32 = 0.008,
    orbit_sensitivity: f32 = 0.01,
    pan_sensitivity: f32 = 0.01,
    wheel_speed: f32 = 1.2,
    move_speed: f32 = 6.0,
    manipulation_mode: ManipulationMode = .none,
    manipulation_axis: AxisConstraint = .free,
    manipulation_entity: ?engine.scene.EntityId = null,
    manipulation_origin: engine.scene.Transform = .{},
    snapshot_history: std.ArrayList([]u8) = .empty,
    snapshot_cursor: usize = 0,
    max_snapshots: usize = 64,
    asset_entries: std.ArrayList(AssetEntry) = .empty,
    selected_asset_index: ?usize = null,
    scene_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    asset_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    language: i18n.Language = .zh_cn,
    dock_layout_initialized: bool = false,
    settings_open: bool = false,
    viewport_hovered: bool = false,
    viewport_focused: bool = false,
    viewport_has_image: bool = false,
    viewport_origin: [2]f32 = .{ 0.0, 0.0 },
    viewport_extent: [2]f32 = .{ 0.0, 0.0 },
    top_bar_drag_active: bool = false,
    top_bar_drag_offset: [2]f32 = .{ 0.0, 0.0 },
    preview_device: ?*engine.rhi.Device = null,
    preview_texture: ?engine.rhi.Texture = null,
    preview_texture_key: ?[]u8 = null,
    preview_texture_size: [2]u32 = .{ 0, 0 },

    pub fn text(self: *const EditorState, id: i18n.MessageId) []const u8 {
        return i18n.text(self.language, id);
    }

    pub fn windowLabel(self: *const EditorState, buffer: []u8, id: i18n.MessageId, stable_id: []const u8) ![]const u8 {
        return i18n.panelLabel(self.language, buffer, id, stable_id);
    }

    pub fn languageInfo(self: *const EditorState) *const i18n.LocaleInfo {
        return i18n.locale(self.language);
    }
};
