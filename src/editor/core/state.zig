const std = @import("std");
const engine = @import("guava");
const i18n = @import("../i18n/mod.zig");

pub const autosave_path = "assets/scenes/editor_autosave.guava_scene";
pub const entity_drag_payload = "guava.scene.entity";
pub const asset_model_drag_payload = "guava.asset.model";
pub const asset_material_drag_payload = "guava.asset.material";
pub const asset_texture_drag_payload = "guava.asset.texture";
pub const place_actor_drag_payload = "guava.editor.place_actor";

pub const AssetKind = enum {
    scene,
    model,
    material,
    texture,
    shader,
};

pub const AssetEntry = struct {
    id: []u8,
    path: []u8,
    name: []u8,
    kind: AssetKind,
};

pub const IconTextureEntry = struct {
    path: []u8,
    width: u32,
    height: u32,
    tint: [4]u8,
    has_tint: bool,
    texture: engine.rhi.Texture,
};

pub const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

pub const PlaybackState = engine.core.PlaybackState;

pub const TransformSpace = enum {
    local,
    world,
};

pub const HierarchyCategory = enum {
    all,
    cameras,
    lights,
    geometry,
    objects,
};

pub const PlaceActorCategory = enum {
    basics,
    lights,
    shapes,
    vfx,
};

pub const PlaceActorKind = enum {
    empty,
    camera,
    cube,
    sphere,
    plane,
    point_light,
    spot_light,
    directional_light,
};

pub const BottomPanelTab = enum {
    project,
    console,
};

pub const ViewportRenderMode = enum {
    textured,
    wireframe,
    unlit,
};

pub const ViewportViewPreset = enum {
    perspective,
    top,
    side,
    custom,
};

pub const AxisConstraint = engine.math.axis.Axis3;

pub const PendingViewportDropSource = enum {
    asset,
    place_actor,
};

pub const PendingViewportDrop = struct {
    source_kind: PendingViewportDropSource,
    asset_index: ?usize = null,
    actor_kind: ?PlaceActorKind = null,
    pixel: ?[2]u32 = null,
    target_entity: ?engine.scene.EntityId = null,
    world_position: ?[3]f32 = null,
};

pub const EditorState = struct {
    allocator: ?std.mem.Allocator = null,
    editor_camera: ?engine.scene.EntityId = null,
    scene_camera: ?engine.scene.EntityId = null,
    inspector_name_entity: ?engine.scene.EntityId = null,
    inspector_name_buffer: [256]u8 = [_]u8{0} ** 256,
    inspector_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    hierarchy_rename_entity: ?engine.scene.EntityId = null,
    hierarchy_rename_buffer: [256]u8 = [_]u8{0} ** 256,
    hierarchy_rename_focus_pending: bool = false,
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
    translation_snap_enabled: bool = false,
    translation_snap_step: f32 = 10.0,
    rotation_snap_enabled: bool = false,
    rotation_snap_step_degrees: f32 = 15.0,
    scale_snap_enabled: bool = false,
    scale_snap_step: f32 = 0.1,
    manipulation_mode: ManipulationMode = .none,
    manipulation_axis: AxisConstraint = .free,
    manipulation_entity: ?engine.scene.EntityId = null,
    manipulation_origin: engine.scene.Transform = .{},
    transform_component_clipboard: ?engine.scene.Transform = null,
    mesh_component_clipboard: ?engine.scene.Mesh = null,
    material_component_clipboard: ?engine.scene.Material = null,
    camera_component_clipboard: ?engine.scene.Camera = null,
    light_component_clipboard: ?engine.scene.Light = null,
    playback_state: PlaybackState = .stopped,
    transform_space: TransformSpace = .local,
    snapshot_history: std.ArrayList([]u8) = .empty,
    snapshot_cursor: usize = 0,
    max_snapshots: usize = 64,
    saved_snapshot_cursor: ?usize = null,
    asset_registry: ?engine.assets.AssetRegistry = null,
    asset_entries: std.ArrayList(AssetEntry) = .empty,
    asset_directories: std.ArrayList([]u8) = .empty,
    selected_asset_index: ?usize = null,
    scene_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    hierarchy_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    hierarchy_category: HierarchyCategory = .all,
    place_actor_category: PlaceActorCategory = .basics,
    asset_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    asset_directory_buffer: [256]u8 = [_]u8{0} ** 256,
    asset_thumbnail_size: f32 = 104.0,
    bottom_panel_tab: BottomPanelTab = .project,
    console_show_errors: bool = true,
    console_show_warnings: bool = true,
    console_show_info: bool = true,
    console_show_debug: bool = true,
    console_auto_scroll: bool = true,
    language: i18n.Language = .zh_cn,
    dock_layout_initialized: bool = false,
    settings_open: bool = false,
    render_settings_open: bool = false,
    viewport_render_mode: ViewportRenderMode = .textured,
    viewport_view_preset: ViewportViewPreset = .perspective,
    viewport_show_grid: bool = true,
    viewport_show_bones: bool = false,
    viewport_show_collision: bool = false,
    viewport_hovered: bool = false,
    viewport_focused: bool = false,
    viewport_has_image: bool = false,
    viewport_overlay_hovered: bool = false,
    viewport_origin: [2]f32 = .{ 0.0, 0.0 },
    viewport_extent: [2]f32 = .{ 0.0, 0.0 },
    pending_viewport_drop: ?PendingViewportDrop = null,
    playback_toolbar_window_initialized: bool = false,
    playback_toolbar_offset: [2]f32 = .{ 0.0, 0.0 },
    playback_toolbar_custom_position: bool = false,
    playback_toolbar_drag_active: bool = false,
    playback_toolbar_drag_offset: [2]f32 = .{ 0.0, 0.0 },
    top_bar_drag_active: bool = false,
    top_bar_drag_offset: [2]f32 = .{ 0.0, 0.0 },
    preview_device: ?*engine.rhi.Device = null,
    icon_device: ?*engine.rhi.Device = null,
    preview_texture: ?engine.rhi.Texture = null,
    preview_texture_key: ?[]u8 = null,
    preview_texture_size: [2]u32 = .{ 0, 0 },
    icon_textures: std.ArrayList(IconTextureEntry) = .empty,
    frozen_entities: std.ArrayList(engine.scene.EntityId) = .empty,
    selection_locked_entities: std.ArrayList(engine.scene.EntityId) = .empty,
    view_cube_transition_active: bool = false,
    view_cube_transition_elapsed: f32 = 0.0,
    view_cube_transition_duration: f32 = 0.22,
    view_cube_transition_start_yaw: f32 = 0.0,
    view_cube_transition_start_pitch: f32 = 0.0,
    view_cube_transition_target_yaw: f32 = 0.0,
    view_cube_transition_target_pitch: f32 = 0.0,
    view_cube_transition_target_orthographic: bool = false,

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

test "viewport drop defaults and payload constants stay stable" {
    try std.testing.expectEqualStrings("guava.asset.model", asset_model_drag_payload);
    try std.testing.expectEqualStrings("guava.asset.material", asset_material_drag_payload);
    try std.testing.expectEqualStrings("guava.asset.texture", asset_texture_drag_payload);
    try std.testing.expectEqualStrings("guava.editor.place_actor", place_actor_drag_payload);

    const state = EditorState{};
    try std.testing.expectEqual(ViewportViewPreset.perspective, state.viewport_view_preset);
    try std.testing.expectEqual(PlaceActorCategory.basics, state.place_actor_category);
    try std.testing.expect(!state.translation_snap_enabled);
    try std.testing.expectEqual(@as(f32, 10.0), state.translation_snap_step);
    try std.testing.expect(!state.rotation_snap_enabled);
    try std.testing.expectEqual(@as(f32, 15.0), state.rotation_snap_step_degrees);
    try std.testing.expect(!state.scale_snap_enabled);
    try std.testing.expectEqual(@as(f32, 0.1), state.scale_snap_step);
    try std.testing.expect(state.pending_viewport_drop == null);

    const pending = PendingViewportDrop{
        .source_kind = .asset,
        .asset_index = 7,
    };
    try std.testing.expectEqual(PendingViewportDropSource.asset, pending.source_kind);
    try std.testing.expectEqual(@as(?usize, 7), pending.asset_index);
    try std.testing.expectEqual(@as(?PlaceActorKind, null), pending.actor_kind);
    try std.testing.expectEqual(@as(?[2]u32, null), pending.pixel);
    try std.testing.expectEqual(@as(?engine.scene.EntityId, null), pending.target_entity);
    try std.testing.expectEqual(@as(?[3]f32, null), pending.world_position);
}
