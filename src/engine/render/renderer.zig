const std = @import("std");
const base_pass_mod = @import("base_pass.zig");
const depth_prepass_mod = @import("depth_prepass.zig");
const id_pass_mod = @import("id_pass.zig");
const gizmo_pass_mod = @import("gizmo_pass.zig");
const outline_pass_mod = @import("outline_pass.zig");
const platform_mod = @import("../core/platform.zig");
const selection_history_mod = @import("selection_history.zig");
const imgui_mod = @import("../ui/imgui.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");

pub const GraphicsAPI = rhi_types.GraphicsAPI;
pub const RuntimeInfo = rhi_types.RuntimeInfo;
pub const SelectionHistory = selection_history_mod.SelectionHistory;
pub const SelectionUpdateMode = selection_history_mod.SelectionUpdateMode;
pub const EditorGizmoState = gizmo_pass_mod.EditorGizmoState;

pub const RendererConfig = struct {
    requested_backends: []const rhi_types.GraphicsAPI = &.{},
    selection_policy: rhi_types.BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
};

pub const FrameReport = struct {
    backend: types.GraphicsAPI,
    passes_executed: usize,
    graph_resources: usize,
    scene: types.SceneSnapshot,
    runtime: types.RuntimeInfo,
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,
};

const SelectionReadbackRequest = struct {
    pixel_x: u32,
    pixel_y: u32,
    mode: SelectionUpdateMode,
};

const InFlightSelectionReadback = struct {
    request: SelectionReadbackRequest,
    transfer_buffer: rhi_mod.TransferBuffer,
};

const InFlightSelectionBatch = struct {
    fence: rhi_mod.Fence,
    readbacks: []InFlightSelectionReadback,

    fn deinit(self: *InFlightSelectionBatch, allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) void {
        for (self.readbacks) |*readback| {
            device.releaseTransferBuffer(&readback.transfer_buffer);
        }
        allocator.free(self.readbacks);
        device.releaseFence(&self.fence);
        self.* = undefined;
    }
};

const SceneViewportState = struct {
    width: u32 = 0,
    height: u32 = 0,
    color_texture: ?rhi_mod.Texture = null,
    depth_texture: ?rhi_mod.Texture = null,

    fn deinit(self: *SceneViewportState, device: *rhi_mod.RhiDevice) void {
        if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = .{};
    }

    fn ensure(self: *SceneViewportState, device: *rhi_mod.RhiDevice, width: u32, height: u32) !void {
        if (width == 0 or height == 0) {
            self.deinit(device);
            return;
        }

        if (self.color_texture) |color_texture| {
            if (self.depth_texture != null and color_texture.desc.width == width and color_texture.desc.height == height) {
                self.width = width;
                self.height = height;
                return;
            }
        }

        self.deinit(device);

        self.color_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
            self.color_texture = null;
        };

        self.depth_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .d32_float,
            .usage = rhi_types.TextureUsage.depth_stencil_target,
        });

        self.width = width;
        self.height = height;
    }

    fn active(self: *const SceneViewportState) bool {
        return self.width > 0 and self.height > 0 and self.color_texture != null and self.depth_texture != null;
    }

    fn color(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn depth(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.depth_texture) |*texture| {
            return texture;
        }
        return null;
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    platform: platform_mod.Platform,
    rhi: rhi_mod.RhiDevice,
    graph: graph_mod.RenderGraph,
    scene_cache: mesh_pass_mod.MeshSceneCache,
    id_pass: id_pass_mod.IdPass,
    depth_prepass: depth_prepass_mod.DepthPrepass,
    base_pass: base_pass_mod.BasePass,
    outline_pass: outline_pass_mod.OutlinePass,
    gizmo_pass: gizmo_pass_mod.GizmoPass,
    selection_history: SelectionHistory,
    selection_seeded: bool = false,
    editor_gizmo_state: EditorGizmoState = .{},
    pending_selection_readbacks: std.ArrayList(SelectionReadbackRequest) = .empty,
    in_flight_selection_batches: std.ArrayList(InFlightSelectionBatch) = .empty,
    scene_viewport: SceneViewportState = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        platform: platform_mod.Platform,
        window: *window_mod.Window,
        config: RendererConfig,
    ) !Renderer {
        var renderer = Renderer{
            .allocator = allocator,
            .platform = platform,
            .rhi = try rhi_mod.RhiDevice.init(
                allocator,
                platform,
                window,
                .{
                    .preferred_backends = config.requested_backends,
                    .selection_policy = config.selection_policy,
                    .enable_validation = config.enable_validation,
                    .frames_in_flight = config.frames_in_flight,
                },
            ),
            .graph = try graph_mod.RenderGraph.initDefault3D(allocator),
            .scene_cache = undefined,
            .id_pass = undefined,
            .depth_prepass = undefined,
            .base_pass = undefined,
            .outline_pass = undefined,
            .gizmo_pass = undefined,
            .selection_history = SelectionHistory.init(allocator, 64),
        };
        errdefer renderer.in_flight_selection_batches.deinit(allocator);
        errdefer renderer.pending_selection_readbacks.deinit(allocator);
        errdefer renderer.selection_history.deinit();
        errdefer renderer.graph.deinit();
        errdefer renderer.rhi.deinit();

        renderer.scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.scene_cache.deinit(&renderer.rhi);

        renderer.id_pass = try id_pass_mod.IdPass.init(&renderer.rhi);
        errdefer renderer.id_pass.deinit(&renderer.rhi);

        renderer.depth_prepass = try depth_prepass_mod.DepthPrepass.init(&renderer.rhi);
        errdefer renderer.depth_prepass.deinit(&renderer.rhi);

        renderer.base_pass = try base_pass_mod.BasePass.init(&renderer.rhi);
        errdefer renderer.base_pass.deinit(&renderer.rhi);

        renderer.outline_pass = try outline_pass_mod.OutlinePass.init(&renderer.rhi);
        errdefer renderer.outline_pass.deinit(&renderer.rhi);

        renderer.gizmo_pass = try gizmo_pass_mod.GizmoPass.init(&renderer.rhi);
        renderer.graph.writeExports("dist/reports/render_graph.dot", "dist/reports/render_graph.json") catch |err| {
            std.log.warn("failed to write render graph exports: {}", .{err});
        };
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.releaseInFlightSelectionBatches();
        self.pending_selection_readbacks.deinit(self.allocator);
        self.selection_history.deinit();
        self.scene_viewport.deinit(&self.rhi);
        self.gizmo_pass.deinit(&self.rhi);
        self.outline_pass.deinit(&self.rhi);
        self.base_pass.deinit(&self.rhi);
        self.depth_prepass.deinit(&self.rhi);
        self.id_pass.deinit(&self.rhi);
        self.scene_cache.deinit(&self.rhi);
        self.rhi.deinit();
        self.graph.deinit();
    }

    pub fn backendApi(self: *const Renderer) rhi_types.GraphicsAPI {
        return self.rhi.api;
    }

    pub fn runtimeInfo(self: *const Renderer) types.RuntimeInfo {
        return self.rhi.runtimeInfo();
    }

    pub fn device(self: *Renderer) *rhi_mod.RhiDevice {
        return &self.rhi;
    }

    pub fn handleResize(self: *Renderer, width: u32, height: u32) !void {
        try self.rhi.resize(width, height);
    }

    pub fn requestSelectionReadback(
        self: *Renderer,
        pixel_x: u32,
        pixel_y: u32,
        mode: SelectionUpdateMode,
    ) !void {
        try self.pending_selection_readbacks.append(self.allocator, .{
            .pixel_x = pixel_x,
            .pixel_y = pixel_y,
            .mode = mode,
        });
        self.selection_seeded = true;
    }

    pub fn selectedEntity(self: *const Renderer) ?scene_mod.EntityId {
        return self.selection_history.primarySelection();
    }

    pub fn selectedEntities(self: *const Renderer) []const scene_mod.EntityId {
        return self.selection_history.currentSelection();
    }

    pub fn resetSceneState(self: *Renderer) !void {
        self.releaseInFlightSelectionBatches();
        self.in_flight_selection_batches = .empty;
        self.pending_selection_readbacks.deinit(self.allocator);
        self.pending_selection_readbacks = .empty;
        self.selection_history.deinit();
        self.selection_history = SelectionHistory.init(self.allocator, 64);
        self.selection_seeded = false;
        self.scene_cache.deinit(&self.rhi);
        self.scene_cache = try mesh_pass_mod.MeshSceneCache.init(self.allocator, &self.rhi);
    }

    pub fn replaceSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .replace);
        self.selection_seeded = true;
    }

    pub fn toggleSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .toggle);
        self.selection_seeded = true;
    }

    pub fn setEditorGizmoState(self: *Renderer, state: EditorGizmoState) void {
        self.editor_gizmo_state = state;
    }

    pub fn setSceneViewportSize(self: *Renderer, width: u32, height: u32) !void {
        try self.scene_viewport.ensure(&self.rhi, width, height);
    }

    pub fn sceneViewportTexture(self: *Renderer) ?*const rhi_mod.Texture {
        if (self.scene_viewport.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn sceneViewportSize(self: *const Renderer) [2]u32 {
        return .{ self.scene_viewport.width, self.scene_viewport.height };
    }

    pub fn passCount(self: *const Renderer) usize {
        return self.graph.passCount();
    }

    pub fn drawFrame(self: *Renderer, scene: *const scene_mod.Scene) !FrameReport {
        try self.resolveSelectionReadbacks();

        const pass_stats = try self.graph.allocatePassStats(self.allocator);
        defer self.allocator.free(pass_stats);

        const snapshot = buildSceneSnapshot(scene);
        const result = blk: {
            const frame = try self.rhi.beginFrame();
            const clear = clearAndDepthForScene(snapshot, self.passCount());
            if (frame.swapchain_texture == null) {
                try self.rhi.cancelFrame(frame);
                break :blk FrameReport{
                    .backend = self.rhi.api,
                    .passes_executed = self.passCount(),
                    .graph_resources = self.graph.resourceCount(),
                    .scene = snapshot,
                    .runtime = self.runtimeInfo(),
                };
            }

            if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
                try self.rhi.clearAndPresent(frame, clear);
                break :blk FrameReport{
                    .backend = self.rhi.api,
                    .passes_executed = self.passCount(),
                    .graph_resources = self.graph.resourceCount(),
                    .scene = snapshot,
                    .runtime = self.runtimeInfo(),
                };
            }

            const viewport_active = self.scene_viewport.active();
            const render_width = if (viewport_active) self.scene_viewport.width else frame.width;
            const render_height = if (viewport_active) self.scene_viewport.height else frame.height;

            var prepared_scene = try self.scene_cache.prepareScene(&self.rhi, scene, render_width, render_height);
            defer prepared_scene.deinit();

            if (!self.selection_seeded) {
                _ = try self.selection_history.applyPick(
                    self.scene_cache.defaultSelectionEntity(scene),
                    .replace,
                );
                self.selection_seeded = true;
            }

            try self.id_pass.ensureTargetSize(&self.rhi, render_width, render_height);

            const scene_color_target: rhi_mod.ColorTarget = if (viewport_active)
                .{ .texture = self.scene_viewport.color().? }
            else
                .swapchain;
            const scene_depth_target: ?rhi_mod.DepthAttachmentDesc = blk_depth: {
                const depth_texture = if (viewport_active)
                    self.scene_viewport.depth().?
                else
                    self.rhi.depthTexture() orelse break :blk_depth null;
                break :blk_depth .{
                    .texture = depth_texture,
                    .clear_depth = 1.0,
                    .clear_stencil = 0,
                    .load_op = .clear,
                    .store_op = .dont_care,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                };
            };

            var draw_stats = mesh_pass_mod.DrawStats{};

            if (self.id_pass.isReady()) {
                const id_texture = self.id_pass.texture().?;
                const id_render_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                    .color = .{
                        .target = .{ .texture = id_texture },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                        .load_op = .clear,
                        .store_op = .store,
                    },
                    .depth = scene_depth_target,
                });
                const start = std.time.nanoTimestamp();
                const id_stats = self.id_pass.draw(&self.rhi, frame, id_render_pass, &prepared_scene);
                self.graph.recordPassStat(pass_stats, .id_pass, durationNs(start, std.time.nanoTimestamp()), id_stats.draw_calls, id_stats.triangles_drawn);
                draw_stats.add(id_stats);
                self.rhi.endRenderPass(id_render_pass);
            }

            const scene_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                .color = .{
                    .target = scene_color_target,
                    .clear_color = clear.color,
                    .load_op = .clear,
                    .store_op = .store,
                },
                .depth = scene_depth_target,
            });
            const depth_start = std.time.nanoTimestamp();
            const depth_stats = self.depth_prepass.draw(&self.rhi, frame, scene_pass, &prepared_scene);
            self.graph.recordPassStat(pass_stats, .depth_prepass, durationNs(depth_start, std.time.nanoTimestamp()), depth_stats.draw_calls, depth_stats.triangles_drawn);
            draw_stats.add(depth_stats);

            const base_start = std.time.nanoTimestamp();
            const base_stats = self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene);
            self.graph.recordPassStat(pass_stats, .base_pass, durationNs(base_start, std.time.nanoTimestamp()), base_stats.draw_calls, base_stats.triangles_drawn);
            draw_stats.add(base_stats);
            self.rhi.endRenderPass(scene_pass);

            const selected_entities = self.selection_history.currentSelection();
            if (self.outline_pass.isReady() and self.id_pass.texture() != null and selected_entities.len > 0) {
                try self.outline_pass.syncTexture(&self.rhi, self.id_pass.texture().?);
                const outline_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                    .color = .{
                        .target = scene_color_target,
                        .load_op = .load,
                        .store_op = .store,
                    },
                    .depth = null,
                });
                const outline_start = std.time.nanoTimestamp();
                const outline_stats = self.outline_pass.draw(&self.rhi, frame, outline_pass, selected_entities);
                self.graph.recordPassStat(pass_stats, .outline_pass, durationNs(outline_start, std.time.nanoTimestamp()), outline_stats.draw_calls, outline_stats.triangles_drawn);
                draw_stats.add(outline_stats);
                self.rhi.endRenderPass(outline_pass);
            }

            if (self.gizmo_pass.isReady()) {
                if (self.selection_history.primarySelection()) |selected_entity_id| {
                    if (scene.worldTransform(selected_entity_id)) |selected_transform| {
                        const gizmo_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                            .color = .{
                                .target = scene_color_target,
                                .load_op = .load,
                                .store_op = .store,
                            },
                            .depth = null,
                        });
                        const gizmo_start = std.time.nanoTimestamp();
                        const gizmo_stats = self.gizmo_pass.draw(
                            &self.rhi,
                            frame,
                            gizmo_pass,
                            &prepared_scene,
                            selected_transform,
                            self.editor_gizmo_state,
                        );
                        self.graph.recordPassStat(pass_stats, .gizmo_overlay, durationNs(gizmo_start, std.time.nanoTimestamp()), gizmo_stats.draw_calls, gizmo_stats.triangles_drawn);
                        draw_stats.add(gizmo_stats);
                        self.rhi.endRenderPass(gizmo_pass);
                    }
                }
            }

            imgui_mod.prepare(frame.command_buffer);
            const ui_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                .color = .{
                    .target = .swapchain,
                    .clear_color = clear.color,
                    .load_op = if (viewport_active) .clear else .load,
                    .store_op = .store,
                },
                .depth = null,
            });
            const ui_start = std.time.nanoTimestamp();
            imgui_mod.render(frame.command_buffer, ui_pass.raw);
            self.graph.recordPassStat(pass_stats, .ui_overlay, durationNs(ui_start, std.time.nanoTimestamp()), 0, 0);
            self.rhi.endRenderPass(ui_pass);

            if (self.pending_selection_readbacks.items.len > 0) {
                if (self.id_pass.texture()) |id_texture| {
                    try self.enqueueSelectionReadbacks(frame, id_texture);
                } else {
                    try self.rhi.submitFrame(frame);
                    try self.applyPendingSelectionMisses();
                }
            } else {
                try self.rhi.submitFrame(frame);
            }
            try self.resolveSelectionReadbacks();

            break :blk FrameReport{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .graph_resources = self.graph.resourceCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
                .draw_calls = draw_stats.draw_calls,
                .triangles_drawn = draw_stats.triangles_drawn,
            };
        };

        self.graph.writeFrameReport(
            self.allocator,
            "dist/reports/latest_frame_report.json",
            rhi_types.graphicsApiName(self.rhi.api),
            result.draw_calls,
            result.triangles_drawn,
            pass_stats,
        ) catch |err| {
            std.log.warn("failed to write frame report: {}", .{err});
        };
        return result;
    }

    fn buildSceneSnapshot(scene: *const scene_mod.Scene) types.SceneSnapshot {
        const summary = scene.summary();
        return .{
            .entity_count = summary.entity_count,
            .camera_count = summary.camera_count,
            .mesh_count = summary.mesh_count,
            .material_count = summary.material_count,
            .light_count = summary.light_count,
        };
    }

    fn clearAndDepthForScene(snapshot: types.SceneSnapshot, pass_count: usize) rhi_types.ClearState {
        const mesh_bias = @as(f32, @floatFromInt(@min(snapshot.mesh_count, 12))) * 0.01;
        const light_bias = @as(f32, @floatFromInt(@min(snapshot.light_count, 4))) * 0.02;
        const pass_bias = @as(f32, @floatFromInt(@min(pass_count, 8))) * 0.005;

        return .{
            .color = .{
                0.05 + mesh_bias,
                0.06 + light_bias,
                0.1 + pass_bias,
                1.0,
            },
            .depth = 1.0,
        };
    }

    fn durationNs(start: i128, end: i128) u64 {
        return if (end > start) @intCast(end - start) else 0;
    }

    fn enqueueSelectionReadbacks(self: *Renderer, frame: rhi_mod.Frame, id_texture: *const rhi_mod.Texture) !void {
        const pending = self.pending_selection_readbacks.items;
        var readbacks = try self.allocator.alloc(InFlightSelectionReadback, pending.len);
        errdefer self.allocator.free(readbacks);

        var created_count: usize = 0;
        errdefer {
            var index: usize = 0;
            while (index < created_count) : (index += 1) {
                self.rhi.releaseTransferBuffer(&readbacks[index].transfer_buffer);
            }
        }

        for (pending, 0..) |request, index| {
            readbacks[index] = .{
                .request = request,
                .transfer_buffer = try self.rhi.createTransferBuffer(.{
                    .size = 4,
                    .upload = false,
                }),
            };
            created_count += 1;
        }

        const copy_pass = try self.rhi.beginCopyPass(frame);

        for (readbacks) |*readback| {
            const pixel_x = @min(readback.request.pixel_x, id_texture.desc.width - 1);
            const pixel_y = @min(readback.request.pixel_y, id_texture.desc.height - 1);
            self.rhi.downloadTexturePixel(copy_pass, id_texture, &readback.transfer_buffer, pixel_x, pixel_y);
        }

        self.rhi.endCopyPass(copy_pass);

        var fence = try self.rhi.submitFrameAndAcquireFence(frame);
        errdefer self.rhi.releaseFence(&fence);

        try self.in_flight_selection_batches.append(self.allocator, .{
            .fence = fence,
            .readbacks = readbacks,
        });
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn resolveSelectionReadbacks(self: *Renderer) !void {
        while (self.in_flight_selection_batches.items.len > 0) {
            if (!self.rhi.isFenceSignaled(&self.in_flight_selection_batches.items[0].fence)) {
                break;
            }

            var batch = self.in_flight_selection_batches.orderedRemove(0);
            defer batch.deinit(self.allocator, &self.rhi);

            for (batch.readbacks) |*readback| {
                var pixel: [4]u8 = undefined;
                try self.rhi.readTransferBufferBytes(&readback.transfer_buffer, pixel[0..]);
                const entity = id_pass_mod.decodeEntityIdBgra(pixel);
                _ = try self.selection_history.applyPick(entity, readback.request.mode);
            }
        }
    }

    fn applyPendingSelectionMisses(self: *Renderer) !void {
        for (self.pending_selection_readbacks.items) |request| {
            _ = try self.selection_history.applyPick(null, request.mode);
        }
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn releaseInFlightSelectionBatches(self: *Renderer) void {
        for (self.in_flight_selection_batches.items) |*batch| {
            batch.deinit(self.allocator, &self.rhi);
        }
        self.in_flight_selection_batches.deinit(self.allocator);
    }
};
