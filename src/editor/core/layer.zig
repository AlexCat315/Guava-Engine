const engine = @import("guava");
const EditorState = @import("state.zig").EditorState;
const utils = @import("../common/utils.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const viewport = @import("../ui/viewport.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const history = @import("../actions/history.zig");

pub const EditorLayer = struct {
    state: EditorState = .{},

    pub fn asLayer(self: *EditorLayer) engine.core.Layer {
        return .{
            .name = "Editor",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_detach = onDetach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        self.state.allocator = layer_context.world.allocator;
        self.state.preview_device = layer_context.rhi();
        try engine.ui.ImGui.init(layer_context.window, layer_context.rhi());
        self.state.dock_layout_initialized = false;
        self.state.scene_camera = layer_context.world.primaryCameraEntity();
        try camera.createEditorCamera(&self.state, layer_context);
        manipulation.syncGizmoState(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        try history.resetSnapshotHistory(&self.state, layer_context);
        try content_browser.refreshAssetBrowser(&self.state);
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        asset_preview.clearPreviewTexture(&self.state);
        self.state.preview_device = null;
        content_browser.clearAssetBrowser(&self.state);
        history.clearSnapshotHistory(&self.state);
        engine.ui.ImGui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        try history.pruneMissingSelection(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        engine.ui.ImGui.beginDockspace();
        if (!self.state.dock_layout_initialized) {
            engine.ui.ImGui.resetDefaultLayout();
            self.state.dock_layout_initialized = true;
        }
        try viewport.drawEditorUi(&self.state, layer_context);
        try viewport.handleViewportSelection(&self.state, layer_context);
        try manipulation.handleEditingShortcuts(&self.state, layer_context);
        manipulation.applyManipulation(&self.state, layer_context);
        camera.handleCameraControls(&self.state, layer_context);
        manipulation.syncGizmoState(&self.state, layer_context);
    }
};
