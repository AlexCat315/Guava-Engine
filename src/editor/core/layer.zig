const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
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
const animation_editor = @import("../ui/panels/tools/animation_editor.zig");
const editor_utilities = @import("../ui/panels/debug/editor_utilities.zig");
const prefab_browser = @import("../ui/panels/assets/prefab_browser.zig");
const particle_editor = @import("../ui/panels/tools/particle_editor.zig");
const script_editor = @import("../ui/panels/tools/script_editor.zig");
const physics_visualization = @import("../ui/panels/rendering/physics_visualization.zig");
const post_process_editor = @import("../ui/panels/rendering/post_process_editor.zig");
const prefab_editor = @import("../ui/panels/assets/prefab_editor.zig");
const camera_bookmarks = @import("../ui/panels/viewport/camera_bookmarks.zig");
const rhi_stats = @import("../ui/panels/debug/rhi_stats.zig");
const preferences = @import("preferences.zig");

fn initEditorStyle() void {
    // Phase 2 shell redesign:
    // 建立统一的深色编辑器基调，并为 AI 协作态预留更明确的紫色强调层级。
    const accent_primary = .{ 0.22, 0.62, 0.48, 1.0 };
    const accent_hover = .{ 0.29, 0.72, 0.58, 1.0 };
    const accent_active = .{ 0.16, 0.52, 0.38, 1.0 };
    const accent_dimmed = .{ 0.22, 0.62, 0.48, 0.22 };

    const ai_accent = .{ 0.60, 0.34, 0.90, 1.0 };
    const ai_accent_dimmed = .{ 0.60, 0.34, 0.90, 0.22 };

    const bg_base = .{ 0.14, 0.15, 0.16, 1.0 };
    const bg_mid = .{ 0.11, 0.12, 0.14, 1.0 };
    const bg_light = .{ 0.14, 0.15, 0.18, 1.0 };
    const bg_panel = .{ 0.12, 0.13, 0.15, 1.0 };
    const bg_frame = .{ 0.08, 0.09, 0.10, 1.0 };
    const bg_frame_hover = .{ 0.15, 0.17, 0.20, 1.0 };
    const bg_frame_active = .{ 0.18, 0.20, 0.24, 1.0 };

    const text_main = .{ 0.89, 0.91, 0.94, 1.0 };
    const text_dim = .{ 0.58, 0.62, 0.68, 1.0 };
    const border_subtle = .{ 0.18, 0.20, 0.24, 1.0 };

    gui.setStyleColor(@intFromEnum(gui.Col.text), text_main);
    gui.setStyleColor(@intFromEnum(gui.Col.text_disabled), text_dim);
    gui.setStyleColor(@intFromEnum(gui.Col.window_bg), bg_mid);
    gui.setStyleColor(@intFromEnum(gui.Col.child_bg), bg_panel);
    gui.setStyleColor(@intFromEnum(gui.Col.popup_bg), bg_light);
    gui.setStyleColor(@intFromEnum(gui.Col.modal_window_dim_bg), .{ 0.03, 0.04, 0.05, 0.76 });

    gui.setStyleColor(@intFromEnum(gui.Col.border), border_subtle);
    gui.setStyleColor(@intFromEnum(gui.Col.border), .{ 0.0, 0.0, 0.0, 0.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.separator), border_subtle);
    gui.setStyleColor(@intFromEnum(gui.Col.separator_hovered), accent_hover);
    gui.setStyleColor(@intFromEnum(gui.Col.separator_active), accent_primary);

    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg), bg_frame);
    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg_hovered), bg_frame_hover);
    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg_active), bg_frame_active);

    gui.setStyleColor(@intFromEnum(gui.Col.title_bg), bg_base);
    gui.setStyleColor(@intFromEnum(gui.Col.title_bg_active), bg_base);
    gui.setStyleColor(@intFromEnum(gui.Col.title_bg_collapsed), bg_base);

    gui.setStyleColor(@intFromEnum(gui.Col.menu_bar_bg), bg_base);
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_bg), bg_base);
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab), .{ 0.22, 0.24, 0.28, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab_hovered), .{ 0.28, 0.31, 0.36, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab_active), .{ 0.34, 0.38, 0.44, 1.0 });

    gui.setStyleColor(@intFromEnum(gui.Col.header), accent_dimmed);
    gui.setStyleColor(@intFromEnum(gui.Col.header_hovered), accent_hover);
    gui.setStyleColor(@intFromEnum(gui.Col.header_active), accent_primary);

    gui.setStyleColor(@intFromEnum(gui.Col.button), .{ 0.17, 0.18, 0.21, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.button_hovered), .{ 0.23, 0.25, 0.30, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.button_active), accent_primary);

    gui.setStyleColor(@intFromEnum(gui.Col.tab), .{ 0.13, 0.14, 0.17, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.tab_hovered), .{ 0.22, 0.24, 0.30, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.tab_active), .{ 0.18, 0.21, 0.26, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.tab_unfocused), .{ 0.11, 0.12, 0.14, 1.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.tab_unfocused_active), .{ 0.15, 0.17, 0.21, 1.0 });

    gui.setStyleColor(@intFromEnum(gui.Col.docking_preview), accent_dimmed);
    gui.setStyleColor(@intFromEnum(gui.Col.drag_drop_target), ai_accent);
    gui.setStyleColor(@intFromEnum(gui.Col.nav_highlight), ai_accent);
    gui.setStyleColor(@intFromEnum(gui.Col.text_selected_bg), ai_accent_dimmed);

    gui.setStyleColor(@intFromEnum(gui.Col.slider_grab), accent_primary);
    gui.setStyleColor(@intFromEnum(gui.Col.slider_grab_active), accent_active);
    gui.setStyleColor(@intFromEnum(gui.Col.check_mark), accent_primary);
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip), .{ 0.00, 0.00, 0.00, 0.0 });
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip_hovered), accent_hover);
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip_active), ai_accent);

    gui.setStyleVarFloat(100, 1.0); // WindowBorderSize
    gui.setStyleVarFloat(101, 1.0); // FrameBorderSize
    gui.setStyleVarFloat(102, 5.0); // FrameRounding
}

fn seedPostProcessViewportState(state: *const EditorState, viewport_state: *engine.render.EditorViewportState) void {
    viewport_state.exposure_enabled = state.viewport_exposure_enabled;
    viewport_state.exposure = state.viewport_exposure;
    viewport_state.bloom_enabled = state.viewport_bloom_enabled;
    viewport_state.bloom_threshold = state.viewport_bloom_threshold;
    viewport_state.bloom_intensity = state.viewport_bloom_intensity;
    viewport_state.color_grading_enabled = state.viewport_color_grading_enabled;
    viewport_state.color_grading_saturation = state.viewport_color_grading_saturation;
    viewport_state.color_grading_contrast = state.viewport_color_grading_contrast;
    viewport_state.color_grading_gamma = state.viewport_color_grading_gamma;
    viewport_state.fxaa_enabled = state.viewport_fxaa_enabled;
    viewport_state.rt_shadows_enabled = state.viewport_rt_shadows_enabled;
    viewport_state.rt_shadow_samples = state.viewport_rt_shadow_samples;
    viewport_state.rt_shadow_strength = state.viewport_rt_shadow_strength;
    viewport_state.rt_shadow_softness = state.viewport_rt_shadow_softness;
    viewport_state.rt_shadow_resolution_scale = state.viewport_rt_shadow_resolution_scale;
    viewport_state.taa_enabled = state.viewport_taa_enabled;
    viewport_state.lut_enabled = state.viewport_lut_enabled;
    viewport_state.lut_intensity = state.viewport_lut_intensity;
    viewport_state.lut_preset = state.viewport_lut_preset;
}

pub const EditorLayer = struct {
    state: EditorState = .{},
    animation_editor_state: ?animation_editor.AnimationEditorState = null,
    particle_editor_state: particle_editor.ParticleEditorState = .{},
    script_editor_state: ?script_editor.ScriptEditorState = null,
    post_process_editor_state: ?post_process_editor.PostProcessPipelineEditorState = null,
    post_process_viewport_state: engine.render.EditorViewportState = .{},
    prefab_editor_state: prefab_editor.PrefabEditorState = .{},
    physics_viz_settings: physics_visualization.PhysicsVisualizationSettings = .{},
    physics_debug_draw_mode: physics_visualization.PhysicsDebugDrawMode = .off,
    camera_bookmark_manager: ?camera_bookmarks.CameraBookmarkManager = null,

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
        try gui.init(layer_context.window, layer_context.rhi());

        initEditorStyle();
        preferences.loadAiProviderSettings(&self.state) catch |err| {
            std.log.warn("Editor: failed to load AI provider settings: {s}", .{@errorName(err)});
        };

        // Force textured startup viewport so imported model textures are visible immediately.
        self.state.viewport_render_mode = .textured;
        self.state.viewport_debug_overlay = false;

        self.state.dock_layout_initialized = false;
        self.state.scene_camera = layer_context.world.primaryCameraEntity();
        self.state.ai_chat_open = false;

        // Initialize animation editor state
        self.animation_editor_state = try animation_editor.createAnimationEditorState(layer_context.world.allocator);

        // Initialize tool panel states
        self.script_editor_state = script_editor.ScriptEditorState.init(layer_context.world.allocator);
        self.post_process_editor_state = post_process_editor.PostProcessPipelineEditorState.init(layer_context.world.allocator);
        seedPostProcessViewportState(&self.state, &self.post_process_viewport_state);
        self.camera_bookmark_manager = camera_bookmarks.CameraBookmarkManager.init(layer_context.world.allocator);

        try camera.createEditorCamera(&self.state, layer_context);
        manipulation.refreshGizmoState(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        try history.resetSnapshotHistory(&self.state, layer_context);
        try content_browser.refreshAssetBrowser(&self.state, layer_context);
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        preferences.saveAiProviderSettings(&self.state) catch |err| {
            std.log.warn("Editor: failed to save AI provider settings: {s}", .{@errorName(err)});
        };
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

            // Cleanup tool panel states
            if (self.script_editor_state) |*s| {
                s.deinit();
                self.script_editor_state = null;
            }
            if (self.post_process_editor_state) |*s| {
                s.deinit();
                self.post_process_editor_state = null;
            }
            if (self.camera_bookmark_manager) |*m| {
                m.deinit();
                self.camera_bookmark_manager = null;
            }
            self.particle_editor_state.deinit();
            self.prefab_editor_state.deinit(allocator);

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
        gui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));

        ai_collaboration.beginFrame(&self.state);
        history.tickDeferredSnapshot(&self.state, layer_context.world);
        try vfx_runtime.update(layer_context);
        try history.pruneMissingSelection(&self.state, layer_context);
        utils.pruneFrozenEntities(&self.state, layer_context.world);
        utils.pruneSelectionLockEntities(&self.state, layer_context.world);
        try utils.pruneFrozenSelection(&self.state, layer_context);
        try utils.pruneLockedSelection(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        gui.beginDockspace();
        if (!self.state.dock_layout_initialized) {
            std.log.info("Editor: Initializing default dock layout", .{});
            gui.resetDefaultLayout();
            gui.saveLayout();
            self.state.dock_layout_initialized = true;
        }
        try viewport.drawEditorUi(&self.state, &self.post_process_viewport_state, layer_context);
        try content_browser.flushMaterialThumbnailRequests(&self.state, layer_context);
        try manipulation.handleEditingShortcuts(&self.state, layer_context);
        manipulation.updateActiveTransform(&self.state, layer_context);
        camera.handleCameraControls(&self.state, layer_context);
        try viewport.handleViewportSelection(&self.state, layer_context);
        manipulation.refreshGizmoState(&self.state, layer_context);
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

        if (layer_context.editor_utility_runtime) |utility_runtime| {
            if (utility_runtime.takeHostOpenRequest()) {
                self.state.editor_utilities_open = true;
            }
        }

        if (self.state.editor_utilities_open) {
            try editor_utilities.drawEditorUtilitiesWindow(&self.state, layer_context);
        }

        // Draw migrated tool panels
        if (self.state.particle_editor_open) {
            try particle_editor.drawParticleEditorWindow(&self.state, layer_context, &self.particle_editor_state);
        }
        if (self.state.script_editor_open) {
            if (self.script_editor_state) |*es| {
                try script_editor.drawScriptEditorWindow(&self.state, layer_context, es);
            }
        }
        if (self.state.physics_visualization_open) {
            try physics_visualization.drawPhysicsVisualizationWindow(&self.state, &self.physics_viz_settings, &self.physics_debug_draw_mode);
        }
        if (self.state.post_process_editor_open) {
            if (self.post_process_editor_state) |*es| {
                try post_process_editor.drawPostProcessPipelineEditorWindow(&self.state, layer_context, es, &self.post_process_viewport_state);
            }
        }
        if (self.state.prefab_editor_open) {
            try prefab_editor.drawPrefabEditorWindow(&self.state, layer_context, &self.prefab_editor_state);
        }
        if (self.state.camera_bookmarks_open) {
            if (self.camera_bookmark_manager) |*bm| {
                try camera_bookmarks.drawCameraBookmarkWindow(&self.state, layer_context, bm);
            }
        }
        if (self.state.rhi_stats_open) {
            rhi_stats.drawRhiStatsWindow(&self.state, layer_context);
        }
    }
};
