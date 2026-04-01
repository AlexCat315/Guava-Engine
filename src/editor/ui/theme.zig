//! Centralized theme system for UI components.
//!
//! All color palettes, spacing, and sizing constants live here so that
//! components never hard-code magic numbers.  Swap the palette to restyle
//! the entire editor without touching component code.
//!
//! ## Theme Architecture
//!
//! ```
//! Palette      - Color definitions organized by subsystem
//! Spacing      - 4px grid-based spacing system
//! Typography   - Font sizes and text hierarchy
//! Size         - Icon sizes, control dimensions, panel constraints
//! BorderRadius - Consistent corner rounding
//! ```

const std = @import("std");

// ── Color Types ──────────────────────────────────────────────────────────────

/// RGBA float color used by the UI backend.
pub const Color = [4]f32;

/// Button palette covering the three interactive states.
pub const ButtonPalette = struct {
    bg: Color,
    hovered: Color,
    active: Color,
};

/// Icon tint in 0-255 byte range (matches RHI texture tinting).
pub const IconTint = [4]u8;

// ── Palettes ─────────────────────────────────────────────────────────────────

pub const Palette = struct {
    // ── General Text ─────────────────────────────────────────────────────────
    pub const text_dimmed: Color = .{ 0.64, 0.68, 0.74, 1.0 };
    pub const text_bright: Color = .{ 0.88, 0.92, 0.98, 1.0 };
    pub const text_primary: Color = .{ 0.88, 0.89, 0.92, 1.0 };
    pub const text_secondary: Color = .{ 0.62, 0.64, 0.68, 1.0 };
    pub const text_muted: Color = .{ 0.42, 0.44, 0.48, 1.0 };
    pub const separator: Color = .{ 0.20, 0.21, 0.23, 1.0 };

    // ── Background ───────────────────────────────────────────────────────────
    pub const bg = struct {
        pub const dock_area: Color = .{ 0.12, 0.13, 0.15, 1.0 };
        pub const panel: Color = .{ 0.16, 0.17, 0.20, 1.0 };
        pub const panel_border: Color = .{ 0.08, 0.09, 0.10, 1.0 };
        pub const title_bar: Color = .{ 0.19, 0.20, 0.24, 1.0 };
        pub const menu_bar: Color = .{ 0.15, 0.16, 0.19, 1.0 };
        pub const header: Color = .{ 0.18, 0.19, 0.22, 1.0 };
        pub const child_bg: Color = .{ 0.14, 0.15, 0.17, 1.0 };
        pub const popup_bg: Color = .{ 0.17, 0.18, 0.21, 1.0 };
        pub const modal_bg: Color = .{ 0.10, 0.11, 0.13, 0.80 };
        pub const table_row_alt: Color = .{ 0.15, 0.16, 0.18, 1.0 };
    };

    // ── Interactive ──────────────────────────────────────────────────────────
    pub const interactive = struct {
        pub const button_bg: Color = .{ 0.24, 0.25, 0.29, 1.0 };
        pub const button_hovered: Color = .{ 0.30, 0.31, 0.36, 1.0 };
        pub const button_active: Color = .{ 0.35, 0.36, 0.42, 1.0 };
        pub const button_disabled: Color = .{ 0.20, 0.21, 0.24, 0.50 };
        pub const frame_bg: Color = .{ 0.20, 0.21, 0.24, 1.0 };
        pub const frame_hovered: Color = .{ 0.26, 0.27, 0.31, 1.0 };
        pub const frame_active: Color = .{ 0.30, 0.31, 0.36, 1.0 };
        pub const accent: Color = .{ 0.25, 0.55, 0.90, 1.0 };
        pub const accent_hovered: Color = .{ 0.30, 0.60, 0.95, 1.0 };
        pub const accent_active: Color = .{ 0.20, 0.50, 0.85, 1.0 };
    };

    // ── Selection ────────────────────────────────────────────────────────────
    pub const selection = struct {
        pub const bg: Color = .{ 0.20, 0.45, 0.80, 0.35 };
        pub const border: Color = .{ 0.30, 0.60, 1.00, 1.0 };
        pub const text: Color = .{ 0.90, 0.94, 1.00, 1.0 };
        pub const hovered: Color = .{ 0.25, 0.35, 0.55, 0.30 };
    };

    // ── Semantic ─────────────────────────────────────────────────────────────
    pub const semantic = struct {
        pub const success: Color = .{ 0.20, 0.65, 0.35, 1.0 };
        pub const success_bg: Color = .{ 0.20, 0.65, 0.35, 0.15 };
        pub const warning: Color = .{ 0.85, 0.65, 0.15, 1.0 };
        pub const warning_bg: Color = .{ 0.85, 0.65, 0.15, 0.15 };
        pub const err: Color = .{ 0.85, 0.25, 0.20, 1.0 };
        pub const err_bg: Color = .{ 0.85, 0.25, 0.20, 0.15 };
        pub const info: Color = .{ 0.25, 0.55, 0.90, 1.0 };
        pub const info_bg: Color = .{ 0.25, 0.55, 0.90, 0.15 };
    };

    // ── Hierarchy panel ──────────────────────────────────────────────────────
    pub const hierarchy = struct {
        pub const selected_icon: IconTint = .{ 41, 150, 112, 255 };
        pub const frozen_icon: IconTint = .{ 148, 158, 173, 255 };
        pub const active_icon: IconTint = .{ 224, 230, 235, 255 };
        pub const dimmed_icon: IconTint = .{ 100, 105, 115, 255 };

        pub const filter_text: Color = .{ 0.55, 0.58, 0.62, 1.0 };
        pub const row_hovered: Color = .{ 0.22, 0.24, 0.28, 1.0 };
        pub const row_selected: Color = .{ 0.20, 0.45, 0.80, 0.35 };
        pub const guide_line: Color = .{ 0.25, 0.26, 0.30, 1.0 };
        pub const drop_target: Color = .{ 0.25, 0.55, 0.90, 0.40 };
    };

    // ── Status buttons (eye / lock / freeze) ─────────────────────────────────
    pub const status = struct {
        pub const on = ButtonPalette{
            .bg = .{ 0.16, 0.59, 0.44, 0.30 },
            .hovered = .{ 0.16, 0.59, 0.44, 0.50 },
            .active = .{ 0.16, 0.59, 0.44, 0.70 },
        };
        pub const off = ButtonPalette{
            .bg = .{ 0.58, 0.62, 0.68, 0.10 },
            .hovered = .{ 0.58, 0.62, 0.68, 0.30 },
            .active = .{ 0.58, 0.62, 0.68, 0.50 },
        };

        pub const on_icon: IconTint = .{ 41, 150, 112, 255 };
        pub const off_icon: IconTint = .{ 148, 158, 173, 255 };
    };

    // ── Toolbar ──────────────────────────────────────────────────────────────
    pub const toolbar = struct {
        pub const idle = ButtonPalette{
            .bg = .{ 0.16, 0.17, 0.18, 0.0 },
            .hovered = .{ 0.20, 0.21, 0.22, 0.6 },
            .active = .{ 0.14, 0.15, 0.16, 0.8 },
        };
        pub const active = ButtonPalette{
            .bg = .{ 0.20, 0.60, 0.45, 0.15 },
            .hovered = .{ 0.20, 0.60, 0.45, 0.25 },
            .active = .{ 0.20, 0.60, 0.45, 0.35 },
        };
        pub const accent = ButtonPalette{
            .bg = .{ 0.20, 0.60, 0.45, 0.4 },
            .hovered = .{ 0.25, 0.70, 0.55, 0.6 },
            .active = .{ 0.15, 0.50, 0.35, 0.8 },
        };
    };

    // ── Viewport ─────────────────────────────────────────────────────────────
    pub const viewport = struct {
        pub const overlay_bg: Color = .{ 0.15, 0.16, 0.18, 0.38 };
        pub const overlay_border: Color = .{ 0.10, 0.11, 0.12, 0.60 };
        pub const grid_line: Color = .{ 0.25, 0.26, 0.28, 0.50 };
        pub const grid_line_major: Color = .{ 0.35, 0.36, 0.38, 0.60 };
        pub const gizmo_x: Color = .{ 0.82, 0.23, 0.23, 1.0 };
        pub const gizmo_y: Color = .{ 0.16, 0.59, 0.44, 1.0 };
        pub const gizmo_z: Color = .{ 0.20, 0.45, 0.85, 1.0 };
        pub const gizmo_screen: Color = .{ 0.90, 0.85, 0.30, 1.0 };
        pub const frustum_wire: Color = .{ 0.55, 0.60, 0.65, 0.70 };
        pub const frustum_selected: Color = .{ 0.30, 0.60, 1.00, 0.90 };
        pub const entity_icon_idle: IconTint = .{ 168, 174, 182, 255 };
        pub const entity_icon_accent: IconTint = .{ 230, 236, 242, 255 };
        pub const entity_icon_selected: IconTint = .{ 41, 150, 112, 255 };
        pub const cursor_3d: Color = .{ 0.90, 0.92, 0.95, 0.80 };
    };

    // ── Inspector / Details ──────────────────────────────────────────────────
    pub const inspector = struct {
        pub const ai_preview_badge: Color = .{ 0.78, 0.50, 1.0, 1.0 };
        pub const ai_preview_bg: Color = .{ 0.36, 0.18, 0.56, 0.30 };
        pub const ai_preview_name: Color = .{ 0.78, 0.50, 1.0, 0.80 };
        pub const component_header_bg: Color = .{ 0.18, 0.19, 0.22, 1.0 };
        pub const component_header_hovered: Color = .{ 0.22, 0.23, 0.27, 1.0 };
        pub const component_separator: Color = .{ 0.12, 0.13, 0.15, 1.0 };
        pub const property_label: Color = .{ 0.62, 0.64, 0.68, 1.0 };
        pub const property_value_bg: Color = .{ 0.18, 0.19, 0.22, 1.0 };
        pub const add_component_bg: Color = .{ 0.16, 0.17, 0.20, 1.0 };
        pub const add_component_hovered: Color = .{ 0.22, 0.23, 0.27, 1.0 };
    };

    // ── Axis colors (transform gizmo / inspector) ────────────────────────────
    pub const axis = struct {
        pub const x_bg: Color = .{ 0.82, 0.23, 0.23, 1.0 };
        pub const y_bg: Color = .{ 0.16, 0.59, 0.44, 1.0 };
        pub const z_bg: Color = .{ 0.20, 0.45, 0.85, 1.0 };
        pub const label: Color = .{ 1.0, 1.0, 1.0, 1.0 };
    };

    // ── Freeze toggle (legacy text-based button) ─────────────────────────────
    pub const freeze = struct {
        pub const text_active: Color = .{ 0.34, 0.90, 0.60, 1.0 };
        pub const text_inactive: Color = .{ 0.55, 0.58, 0.62, 1.0 };
        pub const bg_active = ButtonPalette{
            .bg = .{ 0.13, 0.45, 0.28, 0.82 },
            .hovered = .{ 0.18, 0.55, 0.35, 0.92 },
            .active = .{ 0.10, 0.35, 0.22, 0.96 },
        };
        pub const bg_inactive = ButtonPalette{
            .bg = .{ 0.16, 0.17, 0.19, 0.54 },
            .hovered = .{ 0.21, 0.23, 0.27, 0.74 },
            .active = .{ 0.18, 0.20, 0.24, 0.86 },
        };
    };

    // ── Console / Log ────────────────────────────────────────────────────────
    pub const console = struct {
        pub const error_text: Color = .{ 0.85, 0.25, 0.20, 1.0 };
        pub const warning_text: Color = .{ 0.85, 0.65, 0.15, 1.0 };
        pub const info_text: Color = .{ 0.25, 0.55, 0.90, 1.0 };
        pub const debug_text: Color = .{ 0.50, 0.52, 0.56, 1.0 };
        pub const row_error: Color = .{ 0.85, 0.25, 0.20, 0.08 };
        pub const row_warning: Color = .{ 0.85, 0.65, 0.15, 0.08 };
    };

    // ── Content Browser ──────────────────────────────────────────────────────
    pub const content_browser = struct {
        pub const folder_icon: IconTint = .{ 220, 180, 80, 255 };
        pub const file_icon: IconTint = .{ 168, 174, 182, 255 };
        pub const thumbnail_bg: Color = .{ 0.14, 0.15, 0.17, 1.0 };
        pub const thumbnail_border: Color = .{ 0.20, 0.21, 0.24, 1.0 };
        pub const thumbnail_selected_border: Color = .{ 0.30, 0.60, 1.00, 1.0 };
        pub const path_bar_bg: Color = .{ 0.18, 0.19, 0.22, 1.0 };
    };

    // ── AI / Jarvis ──────────────────────────────────────────────────────────
    pub const ai = struct {
        pub const accent: Color = .{ 0.60, 0.34, 0.90, 1.0 };
        pub const accent_hovered: Color = .{ 0.65, 0.40, 0.95, 1.0 };
        pub const badge_bg: Color = .{ 0.36, 0.18, 0.56, 0.30 };
        pub const user_msg_bg: Color = .{ 0.22, 0.23, 0.27, 1.0 };
        pub const assistant_msg_bg: Color = .{ 0.18, 0.19, 0.22, 1.0 };
        pub const streaming_indicator: Color = .{ 0.60, 0.34, 0.90, 1.0 };
    };
};

// ── Spacing ──────────────────────────────────────────────────────────────────
/// 4px grid-based spacing system for consistent layout.
///
/// All spacing values are multiples of 4 for visual consistency.
pub const Spacing = struct {
    // ── Base grid ────────────────────────────────────────────────────────────
    pub const x1: f32 = 4.0;
    pub const x2: f32 = 8.0;
    pub const x3: f32 = 12.0;
    pub const x4: f32 = 16.0;
    pub const x5: f32 = 20.0;
    pub const x6: f32 = 24.0;
    pub const x8: f32 = 32.0;

    // ── Panel internals ──────────────────────────────────────────────────────
    pub const panel_padding: f32 = 6.0;
    pub const panel_spacing: f32 = 4.0;
    pub const section_padding: f32 = 14.0;
    pub const item_spacing: f32 = 10.0;
    pub const row_spacing: f32 = 8.0;
    pub const cell_padding: f32 = 4.0;

    // ── Component spacing ────────────────────────────────────────────────────
    pub const button_padding: [2]f32 = .{ 8.0, 4.0 };
    pub const frame_padding: [2]f32 = .{ 6.0, 3.0 };
    pub const table_cell_padding: [2]f32 = .{ 4.0, 2.0 };

    // ── Indent ───────────────────────────────────────────────────────────────
    pub const tree_indent: f32 = 16.0;
    pub const group_indent: f32 = 12.0;
};

// ── Typography ───────────────────────────────────────────────────────────────

pub const Typography = struct {
    // ── Font sizes ───────────────────────────────────────────────────────────
    pub const base_size: f32 = 13.0;
    pub const small_size: f32 = 11.0;
    pub const large_size: f32 = 15.0;

    // ── Line heights ─────────────────────────────────────────────────────────
    pub const line_height: f32 = 18.0;
    pub const line_height_small: f32 = 14.0;
    pub const line_height_large: f32 = 22.0;

    // ── Text hierarchy ───────────────────────────────────────────────────────
    pub const heading: Color = Palette.text_bright;
    pub const body: Color = Palette.text_primary;
    pub const secondary: Color = Palette.text_secondary;
    pub const muted: Color = Palette.text_muted;
};

// ── Sizes ────────────────────────────────────────────────────────────────────

pub const Size = struct {
    // ── Icons ────────────────────────────────────────────────────────────────
    pub const icon_xs: f32 = 12.0;
    pub const icon_sm: f32 = 16.0;
    pub const icon_md: f32 = 20.0;
    pub const icon_lg: f32 = 24.0;
    pub const icon_xl: f32 = 32.0;

    // Hierarchy (legacy aliases)
    pub const hierarchy_icon: f32 = 16.0;
    pub const status_button_extent: f32 = 26.0;
    pub const status_column_width: f32 = 32.0;
    pub const drag_preview_icon: f32 = 20.0;

    // Icon padding
    pub const compact_icon_padding: [2]f32 = .{ 3.0, 3.0 };
    pub const regular_icon_padding: [2]f32 = .{ 5.0, 5.0 };

    // ── Controls ─────────────────────────────────────────────────────────────
    pub const control_height: f32 = 28.0;
    pub const control_height_small: f32 = 22.0;
    pub const control_height_large: f32 = 36.0;
    pub const button_min_width: f32 = 60.0;
    pub const input_min_width: f32 = 80.0;

    // ── Inspector property grid ──────────────────────────────────────────────
    pub const stacked_grid_min_width: f32 = 320.0;
    pub const transform_grid_min_width: f32 = 360.0;

    // ── Layout ───────────────────────────────────────────────────────────────
    pub const section_padding: f32 = 14.0;
    pub const item_spacing: f32 = 10.0;
    pub const row_spacing: f32 = 8.0;

    // ── Window constraints ───────────────────────────────────────────────────
    pub const panel_min_width: f32 = 220.0;
    pub const panel_min_height: f32 = 120.0;

    // ── Viewport ─────────────────────────────────────────────────────────────
    pub const view_cube_size_min: f32 = 72.0;
    pub const view_cube_size_max: f32 = 92.0;
    pub const view_cube_margin: f32 = 20.0;
    pub const overlay_top_inset: f32 = 14.0;
    pub const overlay_icon_size: f32 = 14.0;
    pub const bottom_drawer_bar_height: f32 = 38.0;
    pub const bottom_overlay_gap: f32 = 18.0;
    pub const overlay_bg_alpha: f32 = 0.38;

    // ── Toolbar ──────────────────────────────────────────────────────────────
    pub const toolbar_icon_size: f32 = 20.0;
    pub const toolbar_play_button_size: f32 = 28.0;
    pub const toolbar_item_spacing: f32 = 6.0;

    // ── Menu ─────────────────────────────────────────────────────────────────
    pub const menu_bar_height: f32 = 22.0;
    pub const menu_item_height: f32 = 24.0;
    pub const menu_double_click_interval: f32 = 0.35;
    pub const menu_double_click_max_dist: f32 = 6.0;
    pub const menu_drag_start_dist: f32 = 4.0;
    pub const menu_trailing_button_reserve: f32 = 114.0;

    // ── Inspector ────────────────────────────────────────────────────────────
    pub const transform_label_width: f32 = 42.0;
    pub const transform_drag_speed: f32 = 0.05;
    pub const transform_drag_min: f32 = -500.0;
    pub const transform_drag_max: f32 = 500.0;
    pub const rotation_drag_speed: f32 = 0.01;
    pub const scale_drag_speed: f32 = 0.01;
    pub const scale_drag_min: f32 = 0.05;
    pub const scale_drag_max: f32 = 100.0;
    pub const inspector_toggle_width: f32 = 72.0;
    pub const inspector_projection_toggle_width: f32 = 116.0;
    pub const inspector_action_button_min_width: f32 = 80.0;

    // ── Hierarchy ────────────────────────────────────────────────────────────
    pub const hierarchy_filter_compact_threshold: f32 = 180.0;
    pub const hierarchy_filter_right_margin: f32 = 40.0;
    pub const hierarchy_max_depth: usize = 32;
    pub const hierarchy_unparent_spacing: f32 = 4.0;
};

// ── Border Radius ────────────────────────────────────────────────────────────

pub const BorderRadius = struct {
    // ── Controls ─────────────────────────────────────────────────────────────
    pub const control: f32 = 2.0;
    pub const button: f32 = 2.0;
    pub const frame: f32 = 2.0;
    pub const popup: f32 = 4.0;
    pub const window: f32 = 2.0;

    // ── Icons ────────────────────────────────────────────────────────────────
    pub const compact_icon_rounding: f32 = 6.0;
    pub const regular_icon_rounding: f32 = 8.0;

    // ── Special ──────────────────────────────────────────────────────────────
    pub const thumbnail: f32 = 4.0;
    pub const badge: f32 = 8.0;
    pub const progress: f32 = 2.0;
};

// ── Style Helpers ────────────────────────────────────────────────────────────

/// Select a button palette based on an active/inactive flag.
pub fn statusPalette(active: bool) ButtonPalette {
    return if (active) Palette.status.on else Palette.status.off;
}

/// Select an icon tint based on entity state flags.
pub fn hierarchyIconTint(opts: struct {
    selected: bool = false,
    frozen: bool = false,
    visible: bool = true,
}) IconTint {
    if (opts.selected) return Palette.hierarchy.selected_icon;
    if (opts.frozen) return Palette.hierarchy.frozen_icon;
    if (opts.visible) return Palette.hierarchy.active_icon;
    return Palette.hierarchy.dimmed_icon;
}

/// Select icon padding/rounding based on button size.
pub fn iconPadding(size: f32) [2]f32 {
    return if (size >= 28.0) Size.regular_icon_padding else Size.compact_icon_padding;
}

pub fn iconRounding(size: f32) f32 {
    return if (size >= 28.0) Size.regular_icon_rounding else Size.compact_icon_rounding;
}
