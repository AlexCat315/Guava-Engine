const std = @import("std");
const engine = @import("guava");
const EditorState = @import("state.zig").EditorState;
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const viewport = @import("../ui/viewport.zig");
const icon_cache = @import("../ui/icon_cache.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const history = @import("../actions/history.zig");
const vfx_runtime = @import("../runtime/vfx.zig");
const layout = @import("../ui/layout.zig");
const animation_editor = @import("../ui/windows/animation_editor.zig");
const prefab_browser = @import("../ui/windows/prefab_browser.zig");

fn initEditorStyle() void {
    // 采用更沉稳、现代的深灰色调，精简强调色应用以减少视觉疲劳
    const accent_primary = .{ 0.20, 0.60, 0.45, 1.0 }; // 调暗的翡翠绿，更专业
    const accent_hover = .{ 0.25, 0.70, 0.55, 1.0 };
    const accent_active = .{ 0.15, 0.50, 0.35, 1.0 };
    const accent_dimmed = .{ 0.20, 0.60, 0.45, 0.25 }; // 更淡的背景高亮

    // 中性灰阶体系 - 提升纵深感，减少绿色冲击
    const bg_mid = .{ 0.11, 0.12, 0.13, 1.0 }; // 主背景
    const bg_light = .{ 0.15, 0.16, 0.17, 1.0 }; // 浮窗背景
    const bg_frame = .{ 0.08, 0.09, 0.10, 1.0 }; // 控件背景

    const text_main = .{ 0.85, 0.87, 0.90, 1.0 };
    const text_dim = .{ 0.55, 0.58, 0.62, 1.0 };

    // 强调色精简应用
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header), accent_dimmed);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.header_active), accent_primary);

    // Tab 样式优化 - 仅激活状态显示强调色
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab), .{ 0.11, 0.12, 0.13, 0.0 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_active), accent_primary);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_unfocused), .{ 0.11, 0.12, 0.13, 0.0 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.tab_unfocused_active), .{ 0.15, 0.16, 0.17, 1.0 });

    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.slider_grab), accent_primary);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.slider_grab_active), accent_active);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.check_mark), accent_primary);

    // 按钮样式调整 - 降低默认亮度
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.button), .{ 0.18, 0.19, 0.21, 1.0 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.button_hovered), .{ 0.24, 0.25, 0.28, 1.0 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.button_active), accent_primary);

    // 背景体系
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.text), text_main);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.text_disabled), text_dim);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.window_bg), bg_mid);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.child_bg), bg_frame);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.frame_bg), bg_frame);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.popup_bg), bg_light);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.modal_window_dim_bg), .{ 0.05, 0.05, 0.06, 0.7 });

    // 边框与间距优化
    engine.ui.ImGui.setStyleVarFloat(100, 0.0); // WindowBorderSize
    engine.ui.ImGui.setStyleVarFloat(101, 1.0); // FrameBorderSize
    engine.ui.ImGui.setStyleVarFloat(102, 3.0); // FrameRounding

    // 分割线颜色调暗
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.separator), .{ 0.15, 0.16, 0.18, 1.0 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.separator_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.separator_active), accent_primary);

    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.text_selected_bg), .{ 0.20, 0.60, 0.45, 0.35 });
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.drag_drop_target), accent_primary);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.docking_preview), accent_dimmed);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.resize_grip_hovered), accent_hover);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.resize_grip_active), accent_primary);
    engine.ui.ImGui.setStyleColor(@intFromEnum(engine.ui.ImGui.Col.nav_highlight), accent_primary);
}

pub const EditorLayer = struct {
    state: EditorState = .{},
    animation_editor_state: ?animation_editor.AnimationEditorState = null,

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
        self.state.ai_preview_runtime = .init(layer_context.world.allocator, layer_context.world.job_system);
        self.state.preview_device = layer_context.rhi();
        self.state.icon_device = layer_context.rhi();
        self.state.asset_registry = engine.assets.AssetRegistry.init(layer_context.world.allocator);
        try engine.ui.ImGui.init(layer_context.window, layer_context.rhi());

        initEditorStyle();

        self.state.dock_layout_initialized = false;
        self.state.scene_camera = layer_context.world.primaryCameraEntity();

        // Initialize animation editor state
        self.animation_editor_state = try animation_editor.createAnimationEditorState(layer_context.world.allocator);

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
            self.state.ai_preview_entities.deinit(allocator);
            self.state.ai_preview_entities = .empty;
            self.state.ai_preview_selected_entity = null;

            // Cleanup animation editor state
            if (self.animation_editor_state) |*editor_state| {
                animation_editor.destroyAnimationEditorState(editor_state, allocator);
                self.animation_editor_state = null;
            }

            if (self.state.ai_preview_runtime) |*runtime| {
                runtime.deinit();
                self.state.ai_preview_runtime = null;
            }
        }

        layout.releaseLayoutTemplates(&self.state);
        content_browser.clearAssetBrowser(&self.state);
        self.state.clearOwnedClipboards();
        if (self.state.asset_registry) |*registry| {
            registry.deinit();
            self.state.asset_registry = null;
        }
        history.clearSnapshotHistory(&self.state);
        engine.ui.ImGui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));

        ai_collaboration.beginFrame(&self.state);
        try vfx_runtime.update(layer_context);
        try history.pruneMissingSelection(&self.state, layer_context);
        utils.pruneFrozenEntities(&self.state, layer_context.world);
        utils.pruneSelectionLockEntities(&self.state, layer_context.world);
        try utils.pruneFrozenSelection(&self.state, layer_context);
        try utils.pruneLockedSelection(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        engine.ui.ImGui.beginDockspace();
        if (!self.state.dock_layout_initialized) {
            std.log.info("Editor: Initializing default dock layout", .{});
            engine.ui.ImGui.resetDefaultLayout();
            self.state.dock_layout_initialized = true;
        }
        try viewport.drawEditorUi(&self.state, layer_context);
        try content_browser.flushMaterialThumbnailRequests(&self.state, layer_context);
        try manipulation.handleEditingShortcuts(&self.state, layer_context);
        manipulation.applyManipulation(&self.state, layer_context);
        camera.handleCameraControls(&self.state, layer_context);
        try viewport.handleViewportSelection(&self.state, layer_context);
        manipulation.syncGizmoState(&self.state, layer_context);
        ai_collaboration.syncContext(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI collaboration context: {s}", .{@errorName(err)});
        };
        ai_collaboration.syncPreviewWorld(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI preview world: {s}", .{@errorName(err)});
            layer_context.renderer.setPreviewScene(null);
            layer_context.renderer.setPreviewGizmoTransform(null);
        };

        // Draw animation editor window if open
        if (self.state.animation_editor_open) {
            if (self.animation_editor_state) |*editor_state| {
                try animation_editor.drawAnimationEditorWindow(&self.state, layer_context, editor_state);
            }
        }

        if (self.state.prefab_browser_open) {
            try prefab_browser.drawPrefabBrowserWindow(&self.state, layer_context);
        }
    }
};
