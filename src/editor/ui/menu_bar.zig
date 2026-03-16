const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const history = @import("../actions/history.zig");
const scene_hierarchy = @import("windows/scene_hierarchy.zig");

pub fn drawMenuBar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!engine.ui.ImGui.beginMainMenuBar()) {
        return;
    }
    defer engine.ui.ImGui.endMainMenuBar();

    if (engine.ui.ImGui.beginMenu(state.text(.file))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.save_scene), "Ctrl+S", false, true)) {
            history.saveScene(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.load_scene), "Ctrl+O", false, true)) {
            try history.loadScene(state, layer_context);
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.create))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.empty), null, false, true)) {
            try history.spawnEmptyEntity(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.camera), null, false, true)) {
            try history.spawnCameraEntity(state, layer_context);
        }
        if (engine.ui.ImGui.menuItem(state.text(.cube), "1", false, true)) {
            try history.spawnPrimitive(state, layer_context, .cube);
        }
        if (engine.ui.ImGui.menuItem(state.text(.sphere), "2", false, true)) {
            try history.spawnPrimitive(state, layer_context, .sphere);
        }
        if (engine.ui.ImGui.menuItem(state.text(.plane), "3", false, true)) {
            try history.spawnPrimitive(state, layer_context, .plane);
        }
        if (engine.ui.ImGui.menuItem(state.text(.point_light), "L", false, true)) {
            try history.spawnPointLight(state, layer_context);
        }
    }

    if (engine.ui.ImGui.beginMenu(state.text(.edit))) {
        defer engine.ui.ImGui.endMenu();
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

    if (engine.ui.ImGui.beginMenu(state.text(.window))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.reset_dock_layout), null, false, true)) {
            engine.ui.ImGui.resetDefaultLayout();
            state.dock_layout_initialized = true;
        }
    }

    if (engine.ui.ImGui.button(state.text(.settings))) {
        state.settings_open = !state.settings_open;
    }
}
