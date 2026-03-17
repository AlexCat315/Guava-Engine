const engine = @import("guava");
const EditorState = @import("state.zig").EditorState;
const utils = @import("../common/utils.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const viewport = @import("../ui/viewport.zig");
const icon_cache = @import("../ui/icon_cache.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const history = @import("../actions/history.zig");
const vfx_runtime = @import("../runtime/vfx.zig");
const layout = @import("../ui/layout.zig");

fn initEditorStyle() void {
    // 翡翠绿强调色 - #22c55e
    const accent_green = .{ 0.133, 0.773, 0.369, 1.0 };
    const accent_green_hover = .{ 0.233, 0.873, 0.469, 1.0 };
    const accent_green_dim = .{ 0.133, 0.773, 0.369, 0.4 };

    // 暗板岩灰灰阶体系 - 构建空间纵深感
    const slate_mid = .{ 0.11, 0.12, 0.13, 1.0 };
    const slate_light = .{ 0.14, 0.15, 0.16, 1.0 };
    const slate_child = .{ 0.13, 0.13, 0.14, 1.0 };
    const slate_frame = .{ 0.08, 0.08, 0.09, 1.0 };

    // 强调色应用
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header), accent_green_dim);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header_hovered), accent_green_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header_active), accent_green);

    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_active), accent_green);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_hovered), accent_green_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_unfocused_active), accent_green_dim);

    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.slider_grab), accent_green);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.slider_grab_active), accent_green_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.check_mark), accent_green);

    // 灰阶背景体系
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.window_bg), slate_mid);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.child_bg), slate_child);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.frame_bg), slate_frame);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.popup_bg), slate_light);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.modal_window_dim_bg), .{ 0.08, 0.08, 0.10, 0.6 });

    // 边框设置为0 - 去边框化
    engine.ui.ImGui.setStyleVarFloat(100, 0.0);
    engine.ui.ImGui.setStyleVarFloat(101, 0.0);
    engine.ui.ImGui.setStyleVarFloat(102, 3.0);

    // 1. 分割线 - 解决鼠标悬停和拖拽面板边缘时变蓝的问题
    const accent_hover = .{ 0.180, 0.820, 0.420, 1.0 };
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.separator_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.separator_active), accent_green);

    // 2. 文本选中背景 - 解决在 Inspector 输入框里拖拽选中文字时出现的蓝色高亮
    const accent_dim = .{ 0.133, 0.773, 0.369, 0.3 };
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.text_selected_bg), accent_dim);

    // 3. 拖拽与停靠高亮 - 解决拖拽面板停靠或从浏览器拖拽资产时出现的蓝色外框
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.drag_drop_target), accent_green);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.docking_preview), accent_dim);

    // 4. 调整大小角标 - 解决右下角拖拽缩放标识变蓝的问题
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.resize_grip_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.resize_grip_active), accent_green);

    // 5. 键盘导航高亮 - 解决用键盘切换 UI 焦点时出现的蓝色边框
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.nav_highlight), accent_green);
}

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
        self.state.icon_device = layer_context.rhi();
        self.state.asset_registry = engine.assets.AssetRegistry.init(layer_context.world.allocator);
        try engine.ui.ImGui.init(layer_context.window, layer_context.rhi());

        initEditorStyle();

        self.state.dock_layout_initialized = false;
        self.state.scene_camera = layer_context.world.primaryCameraEntity();
        try camera.createEditorCamera(&self.state, layer_context);
        manipulation.syncGizmoState(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        try history.resetSnapshotHistory(&self.state, layer_context);
        try content_browser.refreshAssetBrowser(&self.state, layer_context);
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        icon_cache.clearIconCache(&self.state);
        asset_preview.clearPreviewTexture(&self.state);
        self.state.preview_device = null;
        self.state.icon_device = null;
        if (self.state.allocator) |allocator| {
            self.state.frozen_entities.deinit(allocator);
            self.state.frozen_entities = .empty;
            self.state.selection_locked_entities.deinit(allocator);
            self.state.selection_locked_entities = .empty;
        }
        vfx_runtime.releaseState(&self.state);
        layout.releaseLayoutTemplates(&self.state);
        content_browser.clearAssetBrowser(&self.state);
        if (self.state.asset_registry) |*registry| {
            registry.deinit();
            self.state.asset_registry = null;
        }
        history.clearSnapshotHistory(&self.state);
        engine.ui.ImGui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        try vfx_runtime.update(&self.state, layer_context);
        try history.pruneMissingSelection(&self.state, layer_context);
        utils.pruneFrozenEntities(&self.state, layer_context.world);
        utils.pruneSelectionLockEntities(&self.state, layer_context.world);
        try utils.pruneFrozenSelection(&self.state, layer_context);
        try utils.pruneLockedSelection(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        engine.ui.ImGui.beginDockspace();
        if (!self.state.dock_layout_initialized) {
            engine.ui.ImGui.resetDefaultLayout();
            self.state.dock_layout_initialized = true;
        }
        try viewport.drawEditorUi(&self.state, layer_context);
        try content_browser.flushMaterialThumbnailRequests(&self.state, layer_context);
        try viewport.handleViewportSelection(&self.state, layer_context);
        try manipulation.handleEditingShortcuts(&self.state, layer_context);
        manipulation.applyManipulation(&self.state, layer_context);
        camera.handleCameraControls(&self.state, layer_context);
        manipulation.syncGizmoState(&self.state, layer_context);
    }
};
