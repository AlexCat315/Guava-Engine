const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const EditorState = @import("../core/state.zig").EditorState;
const history = @import("../actions/history.zig");
const camera = @import("../interaction/camera.zig");
const content_browser = @import("../assets/browser.zig");
const scene_hierarchy = @import("panels/scene/scene_hierarchy.zig");
const floating_window_blocker = @import("floating_window_blocker.zig");
const layout = @import("layout.zig");
const i18n = @import("../i18n/mod.zig");

var g_pending_top_bar_drag = false;
var g_pending_top_bar_drag_mouse = [2]f32{ 0.0, 0.0 };

pub fn drawMenuBar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!gui.beginMainMenuBar()) {
        return;
    }
    defer gui.endMainMenuBar();

    const native_titlebar_controls = layer_context.window.hasNativeTitlebarControls();
    if (native_titlebar_controls and layer_context.window.titlebarLeadingInset() > 0.0) {
        gui.dummy(layer_context.window.titlebarLeadingInset(), 1.0);
        gui.sameLine();
    }

    if (gui.beginMenu(state.text(.file))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.new_scene), "Ctrl+N", false, true)) {
            try history.newScene(state, layer_context);
        }
        gui.separator();
        if (gui.menuItem(state.text(.save_scene), "Ctrl+S", false, true)) {
            history.saveScene(state, layer_context);
        }
        if (gui.menuItem(state.text(.load_scene), "Ctrl+O", false, true)) {
            try history.loadScene(state, layer_context);
        }
    }

    if (gui.beginMenu(state.text(.assets_menu))) {
        defer gui.endMenu();
        const can_instantiate = content_browser.selectedAssetCanLoadScene(state) or content_browser.selectedAssetCanImportModel(state);
        if (gui.menuItem(state.text(.instantiate_slash_load), null, false, can_instantiate)) {
            try content_browser.instantiateSelectedAsset(state, layer_context);
        }
        if (gui.menuItem(state.text(.refresh), null, false, true)) {
            try content_browser.refreshAssetBrowser(state, layer_context);
        }
    }

    if (gui.beginMenu(state.text(.edit))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.undo), "Ctrl+Z", false, true)) {
            try history.undo(state, layer_context);
        }
        if (gui.menuItem(state.text(.redo), "Ctrl+Y", false, true)) {
            try history.redo(state, layer_context);
        }
        gui.separator();
        const has_selection = layer_context.renderer.selectedEntity() != null;
        if (gui.menuItem(state.text(.duplicate), "Ctrl+D", false, has_selection)) {
            try history.duplicateSelection(state, layer_context);
        }
        if (gui.menuItem(state.text(.delete), "Del", false, has_selection)) {
            try history.deleteSelection(state, layer_context);
        }
        if (gui.menuItem(state.text(.parent_to_active), "P", false, layer_context.renderer.selectedEntities().len > 1)) {
            try scene_hierarchy.parentSelection(state, layer_context);
        }
        if (gui.menuItem(state.text(.unparent), "Shift+P", false, has_selection)) {
            try scene_hierarchy.unparentSelection(state, layer_context);
        }
    }

    if (gui.beginMenu(state.text(.rendering))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.editor_camera_mode), null, state.editor_camera_active, true) and !state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        }
        if (gui.menuItem(state.text(.scene_camera_mode), null, !state.editor_camera_active, true) and state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        }
        if (gui.menuItem(state.text(.focus), "F", false, layer_context.renderer.selectedEntity() != null)) {
            camera.focusSelection(state, layer_context);
        }
        gui.separator();
        if (gui.menuItem(state.text(.translation_snap), "Ctrl+Shift+T", false, true)) {
            state.translation_snap_enabled = !state.translation_snap_enabled;
        }
        if (gui.menuItem(state.text(.rotation_snap), "Ctrl+Shift+R", false, true)) {
            state.rotation_snap_enabled = !state.rotation_snap_enabled;
        }
        if (gui.menuItem(state.text(.scale_snap), "Ctrl+Shift+S", false, true)) {
            state.scale_snap_enabled = !state.scale_snap_enabled;
        }
    }

    if (gui.beginMenu(state.text(.window))) {
        defer gui.endMenu();
        if (gui.menuItem("Jarvis Terminal", null, state.ai_chat_open, true)) {
            state.ai_chat_open = !state.ai_chat_open;
        }
        if (gui.menuItem(state.text(.command_timeline), null, state.bottom_workspace_tab == .command_timeline, true)) {
            state.bottom_workspace_tab = .command_timeline;
        }
        if (gui.menuItem("Project Browser", null, state.bottom_workspace_tab == .project, true)) {
            state.bottom_workspace_tab = .project;
        }
        if (gui.menuItem("Console", null, state.bottom_workspace_tab == .console, true)) {
            state.bottom_workspace_tab = .console;
        }
        gui.separator();
        if (gui.menuItem("Ghost Highlight (AI Outline)", null, state.ghost_highlight_enabled, true)) {
            state.ghost_highlight_enabled = !state.ghost_highlight_enabled;
        }
        gui.separator();
        if (gui.menuItem(state.text(.material_editor), null, state.material_editor_open, true)) {
            state.material_editor_open = !state.material_editor_open;
        }
        if (gui.menuItem(state.text(.animation_editor), null, state.animation_editor_open, true)) {
            state.animation_editor_open = !state.animation_editor_open;
        }
        if (gui.menuItem(state.text(.post_process_pipeline), null, state.post_process_editor_open, true)) {
            state.post_process_editor_open = !state.post_process_editor_open;
        }
        if (gui.menuItem(state.text(.prefab_browser), null, state.prefab_browser_open, true)) {
            state.prefab_browser_open = !state.prefab_browser_open;
        }
        if (gui.menuItem(state.text(.settings), null, state.settings_open, true)) {
            state.settings_open = !state.settings_open;
        }
        if (gui.menuItem("RHI Stats", null, state.rhi_stats_open, true)) {
            state.rhi_stats_open = !state.rhi_stats_open;
        }
        if (gui.beginMenu(state.text(.layout))) {
            defer gui.endMenu();
            if (gui.menuItem(state.text(.load_default_layout), null, false, true)) {
                layout.resetDockLayout(state);
            }

            if (gui.menuItem(state.text(.save_as_template), null, false, true)) {
                var name_buffer: [64]u8 = undefined;
                const generated_name = try std.fmt.bufPrint(&name_buffer, "layout-{d}", .{std.time.timestamp()});
                _ = try layout.saveUserLayoutTemplate(state, generated_name);
            }

            gui.separator();
            try layout.ensureLayoutTemplatesLoaded(state);
            if (gui.beginMenu(state.text(.layout_templates))) {
                defer gui.endMenu();
                if (state.layout_templates.items.len == 0) {
                    _ = gui.menuItem(state.text(.no_saved_layout_templates), null, false, false);
                } else {
                    var template_deleted = false;
                    for (state.layout_templates.items, 0..) |entry, index| {
                        if (!gui.beginMenu(entry.name)) {
                            continue;
                        }
                        defer gui.endMenu();

                        if (gui.menuItem(state.text(.load_template), null, false, true)) {
                            _ = layout.loadUserLayoutTemplate(state, entry.path);
                        }
                        if (gui.menuItem(state.text(.delete_template), null, false, true)) {
                            _ = try layout.deleteUserLayoutTemplate(state, index);
                            template_deleted = true;
                        }

                        if (template_deleted) break;
                    }
                }
            }
        }
    }

    if (gui.beginMenu(state.text(.help))) {
        defer gui.endMenu();

        if (gui.menuItem(state.text(.ai_chat), "Ctrl+Shift+I", state.ai_chat_open, true)) {
            state.ai_chat_open = !state.ai_chat_open;
        }
        if (gui.menuItem("AI Utilities", null, state.editor_utilities_open, true)) {
            state.editor_utilities_open = !state.editor_utilities_open;
        }
        gui.separator();

        for (i18n.available_languages) |language| {
            const locale_info = i18n.locale(language);
            if (gui.menuItem(locale_info.native_name, null, state.language == language, true)) {
                state.language = language;
            }
        }
    }

    const trailing_button_reserve: f32 = if (native_titlebar_controls)
        layer_context.window.titlebarTrailingInset()
    else
        114.0;
    const available = gui.contentRegionAvail();
    const drag_width = @max(available[0] - trailing_button_reserve, 48.0);

    gui.sameLine();
    _ = gui.invisibleButton("top_bar_drag_region", drag_width, 22.0);
    // Allow starting a pending top-bar drag when the invisible top-bar region is hovered
    // and the left mouse button is pressed. Also keep existing behavior when the item
    // is already active (pressed). This makes dragging more responsive.
    if ((gui.isItemActive() or gui.isItemHovered()) and layer_context.input.wasMousePressed(.left)) {
        g_pending_top_bar_drag = true;
        g_pending_top_bar_drag_mouse = gui.mousePos();
    }
    if (gui.isItemHovered() and layer_context.input.wasMouseDoubleClicked(.left)) {
        // Clear any pending top-bar drag so resolvePendingTopBarDrag won't start a drag
        // immediately after a double-click maximize/restore.
        g_pending_top_bar_drag = false;
        state.top_bar_drag_active = false;
        // Treat maximizeFull as equivalent to native maximize for restore logic.
        if (layer_context.window.isMaximized() or layer_context.window.isMaximizedFull()) {
            try layer_context.window.restore();
        } else {
            try layer_context.window.maximizeFull();
        }
    }

    const mouse_over_floating_window = floating_window_blocker.anyContainsPoint(gui.mousePos());
    if (state.top_bar_drag_active) {
        if (mouse_over_floating_window and layer_context.input.isMouseDown(.left)) {
            state.top_bar_drag_active = false;
        } else if (layer_context.input.isMouseDown(.left)) {
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
        gui.sameLine();
        if (gui.windowControlButton(.minimize, false)) {
            state.top_bar_drag_active = false;
            try layer_context.window.minimize();
        }

        gui.sameLine();
        // Mark the maximize control active if either native maximize or our maximizeFull is active.
        if (gui.windowControlButton(.maximize, (layer_context.window.isMaximized() or layer_context.window.isMaximizedFull()))) {
            state.top_bar_drag_active = false;
            // Treat both maximize modes as needing a restore when active.
            if (layer_context.window.isMaximized() or layer_context.window.isMaximizedFull()) {
                try layer_context.window.restore();
            } else {
                try layer_context.window.maximize();
            }
        }

        gui.sameLine();
        if (gui.windowControlButton(.close, false)) {
            state.top_bar_drag_active = false;
            layer_context.window.requestClose();
        }
    }
}

pub fn resolvePendingTopBarDrag(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!g_pending_top_bar_drag) return;
    defer g_pending_top_bar_drag = false;

    if (!layer_context.input.isMouseDown(.left)) return;
    if (floating_window_blocker.anyContainsPoint(g_pending_top_bar_drag_mouse)) return;
    try beginTopBarDrag(state, layer_context);
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
