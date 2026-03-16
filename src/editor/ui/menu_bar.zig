const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const content_browser = @import("../assets/browser.zig");
const scene_hierarchy = @import("windows/scene_hierarchy.zig");
const i18n = @import("../i18n/mod.zig");

pub fn drawMenuBar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!engine.ui.ImGui.beginMainMenuBar()) {
        return;
    }
    defer engine.ui.ImGui.endMainMenuBar();

    const native_titlebar_controls = layer_context.window.hasNativeTitlebarControls();
    if (native_titlebar_controls and layer_context.window.titlebarLeadingInset() > 0.0) {
        engine.ui.ImGui.dummy(layer_context.window.titlebarLeadingInset(), 1.0);
        engine.ui.ImGui.sameLine();
    }

    if (engine.ui.ImGui.beginMenu(state.text(.file))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.new_scene), "Ctrl+N", false, true)) {
            try history.newScene(state, layer_context);
        }
        engine.ui.ImGui.separator();
        if (engine.ui.ImGui.menuItem(state.text(.save_scene), "Ctrl+S", false, true)) {
            history.saveScene(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.load_scene), "Ctrl+O", false, true)) {
            try history.loadScene(state, layer_context);
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.assets_menu))) {
        defer engine.ui.ImGui.endMenu();
        const can_instantiate = content_browser.selectedAssetCanLoadScene(state) or content_browser.selectedAssetCanImportModel(state);
        if (engine.ui.ImGui.menuItem(state.text(.instantiate_slash_load), null, false, can_instantiate)) {
            try content_browser.instantiateSelectedAsset(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.refresh), null, false, true)) {
            try content_browser.refreshAssetBrowser(state, layer_context);
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.edit))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.undo), "Ctrl+Z", false, true)) {
            try history.undo(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.redo), "Ctrl+Y", false, true)) {
            try history.redo(state, layer_context);
        }
        engine.ui.ImGui.separator();
        const has_selection = layer_context.renderer.selectedEntity() != null;
        if (engine.ui.ImGui.menuItem(state.text(.duplicate), "Ctrl+D", false, has_selection)) {
            try history.duplicateSelection(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.delete), "Del", false, has_selection)) {
            try history.deleteSelection(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.parent_to_active), "P", false, layer_context.renderer.selectedEntities().len > 1)) {
            try scene_hierarchy.parentSelection(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.unparent), "Shift+P", false, has_selection)) {
            try scene_hierarchy.unparentSelection(state, layer_context);
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.rendering))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.editor_camera_mode), null, state.editor_camera_active, true) and !state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.scene_camera_mode), null, !state.editor_camera_active, true) and state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.focus), "F", false, layer_context.renderer.selectedEntity() != null)) {
            camera.focusSelection(state, layer_context);
        }
        engine.ui.ImGui.separator();
        if (engine.ui.ImGui.menuItem(state.text(.translation_snap), "Ctrl+Shift+T", false, true)) {
            state.translation_snap_enabled = !state.translation_snap_enabled;
        }
        if (engine.ui.ImGui.menuItem(state.text(.rotation_snap), "Ctrl+Shift+R", false, true)) {
            state.rotation_snap_enabled = !state.rotation_snap_enabled;
        }
        if (engine.ui.ImGui.menuItem(state.text(.scale_snap), "Ctrl+Shift+S", false, true)) {
            state.scale_snap_enabled = !state.scale_snap_enabled;
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.window))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.material_editor), null, state.material_editor_open, true)) {
            state.material_editor_open = !state.material_editor_open;
        }
        if (engine.ui.ImGui.menuItem(state.text(.settings), null, state.settings_open, true)) {
            state.settings_open = !state.settings_open;
        }
        if (engine.ui.ImGui.beginMenu(state.text(.layout))) {
            defer engine.ui.ImGui.endMenu();
            if (engine.ui.ImGui.menuItem(state.text(.save_current_layout), null, false, true)) {
                engine.ui.ImGui.saveLayout();
            }
            if (engine.ui.ImGui.menuItem(state.text(.load_default_layout), null, false, true)) {
                engine.ui.ImGui.resetDefaultLayout();
                state.dock_layout_initialized = true;
            }
            if (engine.ui.ImGui.menuItem(state.text(.load_animation_layout), null, false, true)) {
                engine.ui.ImGui.loadAnimationLayout();
                state.dock_layout_initialized = true;
            }
            if (engine.ui.ImGui.menuItem(state.text(.reset_dock_layout), null, false, true)) {
                engine.ui.ImGui.resetDefaultLayout();
                state.dock_layout_initialized = true;
            }
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.help))) {
        defer engine.ui.ImGui.endMenu();
        for (i18n.available_languages) |language| {
            const locale_info = i18n.locale(language);
            if (engine.ui.ImGui.menuItem(locale_info.native_name, null, state.language == language, true)) {
                state.language = language;
            }
        }
    }

    const trailing_button_reserve: f32 = if (native_titlebar_controls)
        layer_context.window.titlebarTrailingInset()
    else
        114.0;
    const available = engine.ui.ImGui.contentRegionAvail();
    const drag_width = @max(available[0] - trailing_button_reserve, 48.0);

    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.invisibleButton("top_bar_drag_region", drag_width, 22.0);
    if (engine.ui.ImGui.isItemActive() and layer_context.input.wasMousePressed(.left)) {
        try beginTopBarDrag(state, layer_context);
    }

    if (state.top_bar_drag_active) {
        if (layer_context.input.isMouseDown(.left)) {
            const mouse = layer_context.window.globalMousePosition();
            try layer_context.window.setPosition(
                @as(i32, @intFromFloat(mouse[0] - state.top_bar_drag_offset[0])),
                @as(i32, @intFromFloat(mouse[1] - state.top_bar_drag_offset[1])),
            );
        } else {
            state.top_bar_drag_active = false;
        }
    }

    if (!native_titlebar_controls) {
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.windowControlButton(.minimize, false)) {
            state.top_bar_drag_active = false;
            try layer_context.window.minimize();
        }

        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.windowControlButton(.maximize, layer_context.window.isMaximized())) {
            state.top_bar_drag_active = false;
            if (layer_context.window.isMaximized()) {
                try layer_context.window.restore();
            } else {
                try layer_context.window.maximize();
            }
        }

        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.windowControlButton(.close, false)) {
            state.top_bar_drag_active = false;
            layer_context.window.requestClose();
        }
    }
}

fn beginTopBarDrag(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const mouse = layer_context.window.globalMousePosition();

    if (layer_context.window.isMaximized()) {
        const usable = try layer_context.window.usableBounds();
        const width_before_restore = @max(layer_context.window.logical_width, 1);
        const click_ratio_x = std.math.clamp(
            layer_context.input.mouse_position[0] / @as(f32, @floatFromInt(width_before_restore)),
            0.1,
            0.9,
        );
        const click_offset_y = std.math.clamp(layer_context.input.mouse_position[1], 8.0, 28.0);

        try layer_context.window.restore();
        try layer_context.window.sync();
        try layer_context.window.refreshSizes();

        const restored_width: i32 = @intCast(@max(layer_context.window.logical_width, 1));
        const restored_height: i32 = @intCast(@max(layer_context.window.logical_height, 1));
        const min_x = usable.x;
        const max_x = usable.x + usable.w - restored_width;
        const min_y = usable.y;
        const max_y = usable.y + usable.h - restored_height;
        const target_x = std.math.clamp(
            @as(i32, @intFromFloat(mouse[0] - @as(f32, @floatFromInt(restored_width)) * click_ratio_x)),
            min_x,
            @max(min_x, max_x),
        );
        const target_y = std.math.clamp(
            @as(i32, @intFromFloat(mouse[1] - click_offset_y)),
            min_y,
            @max(min_y, max_y),
        );
        try layer_context.window.setPosition(target_x, target_y);

        state.top_bar_drag_active = true;
        state.top_bar_drag_offset = .{
            mouse[0] - @as(f32, @floatFromInt(target_x)),
            mouse[1] - @as(f32, @floatFromInt(target_y)),
        };
        return;
    }

    const window_pos = try layer_context.window.position();
    state.top_bar_drag_active = true;
    state.top_bar_drag_offset = .{
        mouse[0] - @as(f32, @floatFromInt(window_pos[0])),
        mouse[1] - @as(f32, @floatFromInt(window_pos[1])),
    };
}
