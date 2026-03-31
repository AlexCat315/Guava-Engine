//! Centralized theme system for UI components.
//!
//! All color palettes, spacing, and sizing constants live here so that
//! components never hard-code magic numbers.  Swap the palette to restyle
//! the entire editor without touching component code.

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
    // ── General ──────────────────────────────────────────────────────────────
    pub const text_dimmed: Color = .{ 0.64, 0.68, 0.74, 1.0 };
    pub const text_bright: Color = .{ 0.88, 0.92, 0.98, 1.0 };
    pub const separator: Color = .{ 0.20, 0.21, 0.23, 1.0 };

    // ── Hierarchy panel ──────────────────────────────────────────────────────
    pub const hierarchy = struct {
        pub const selected_icon: IconTint = .{ 41, 150, 112, 255 };
        pub const frozen_icon: IconTint = .{ 148, 158, 173, 255 };
        pub const active_icon: IconTint = .{ 224, 230, 235, 255 };
        pub const dimmed_icon: IconTint = .{ 100, 105, 115, 255 };

        pub const filter_text: Color = .{ 0.55, 0.58, 0.62, 1.0 };
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

    // ── Inspector ────────────────────────────────────────────────────────────
    pub const inspector = struct {
        pub const ai_preview_badge: Color = .{ 0.78, 0.50, 1.0, 1.0 };
        pub const ai_preview_bg: Color = .{ 0.36, 0.18, 0.56, 0.30 };
        pub const ai_preview_name: Color = .{ 0.78, 0.50, 1.0, 0.80 };
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
};

// ── Sizes ────────────────────────────────────────────────────────────────────

pub const Size = struct {
    // Hierarchy
    pub const hierarchy_icon: f32 = 16.0;
    pub const status_button_extent: f32 = 26.0;
    pub const status_column_width: f32 = 32.0;
    pub const drag_preview_icon: f32 = 20.0;

    // Icons
    pub const compact_icon_padding: [2]f32 = .{ 3.0, 3.0 };
    pub const regular_icon_padding: [2]f32 = .{ 5.0, 5.0 };
    pub const compact_icon_rounding: f32 = 6.0;
    pub const regular_icon_rounding: f32 = 8.0;

    // Inspector property grid
    pub const stacked_grid_min_width: f32 = 320.0;
    pub const transform_grid_min_width: f32 = 360.0;

    // Layout
    pub const section_padding: f32 = 14.0;
    pub const item_spacing: f32 = 10.0;
    pub const row_spacing: f32 = 8.0;

    // Window constraints
    pub const panel_min_width: f32 = 220.0;
    pub const panel_min_height: f32 = 120.0;
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
