const std = @import("std");
const base_pass_mod = @import("base_pass.zig");
const depth_prepass_mod = @import("depth_prepass.zig");
const id_pass_mod = @import("id_pass.zig");
const outline_pass_mod = @import("outline_pass.zig");
const platform_mod = @import("../core/platform.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");

pub const GraphicsAPI = rhi_types.GraphicsAPI;
pub const RuntimeInfo = rhi_types.RuntimeInfo;

pub const RendererConfig = struct {
    requested_backends: []const rhi_types.GraphicsAPI = &.{},
    selection_policy: rhi_types.BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
};

pub const FrameReport = struct {
    backend: types.GraphicsAPI,
    passes_executed: usize,
    scene: types.SceneSnapshot,
    runtime: types.RuntimeInfo,
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,
};

const SelectionReadbackRequest = struct {
    pixel_x: u32,
    pixel_y: u32,
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
    selected_entity: ?scene_mod.EntityId = null,
    selection_seeded: bool = false,
    pending_selection_readback: ?SelectionReadbackRequest = null,

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
        };
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
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
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

    pub fn requestSelectionReadback(self: *Renderer, pixel_x: u32, pixel_y: u32) void {
        self.pending_selection_readback = .{
            .pixel_x = pixel_x,
            .pixel_y = pixel_y,
        };
        self.selection_seeded = true;
    }

    pub fn selectedEntity(self: *const Renderer) ?scene_mod.EntityId {
        return self.selected_entity;
    }

    pub fn passCount(self: *const Renderer) usize {
        return self.graph.passes.items.len;
    }

    pub fn drawFrame(self: *Renderer, scene: *const scene_mod.Scene) !FrameReport {
        const snapshot = buildSceneSnapshot(scene);
        const frame = try self.rhi.beginFrame();
        const clear = clearAndDepthForScene(snapshot, self.passCount());
        if (frame.swapchain_texture == null) {
            try self.rhi.cancelFrame(frame);
            return .{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
            };
        }

        if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
            try self.rhi.clearAndPresent(frame, clear);
            return .{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
            };
        }

        var prepared_scene = try self.scene_cache.prepareScene(&self.rhi, frame, scene);
        defer prepared_scene.deinit();

        if (!self.selection_seeded) {
            self.selected_entity = self.scene_cache.defaultSelectionEntity(scene);
            self.selection_seeded = true;
        }

        try self.id_pass.ensureTarget(&self.rhi);

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
                .depth = if (self.rhi.depthTexture()) |depth_texture|
                    .{
                        .texture = depth_texture,
                        .clear_depth = 1.0,
                        .clear_stencil = 0,
                        .load_op = .clear,
                        .store_op = .dont_care,
                        .stencil_load_op = .dont_care,
                        .stencil_store_op = .dont_care,
                    }
                else
                    null,
            });
            draw_stats.add(self.id_pass.draw(&self.rhi, frame, id_render_pass, &prepared_scene));
            self.rhi.endRenderPass(id_render_pass);
        }

        const scene_pass = try self.rhi.beginRenderPass(frame, clear);
        draw_stats.add(self.depth_prepass.draw(&self.rhi, frame, scene_pass, &prepared_scene));
        draw_stats.add(self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene));
        self.rhi.endRenderPass(scene_pass);

        if (self.outline_pass.isReady() and self.id_pass.texture() != null and self.selected_entity != null) {
            try self.outline_pass.syncTexture(&self.rhi, self.id_pass.texture().?);
            const outline_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                .color = .{
                    .target = .swapchain,
                    .load_op = .load,
                    .store_op = .store,
                },
                .depth = null,
            });
            draw_stats.add(self.outline_pass.draw(&self.rhi, frame, outline_pass, self.selected_entity));
            self.rhi.endRenderPass(outline_pass);
        }

        try self.rhi.submitFrame(frame);
        try self.resolveSelectionReadback();

        return .{
            .backend = self.rhi.api,
            .passes_executed = self.passCount(),
            .scene = snapshot,
            .runtime = self.runtimeInfo(),
            .draw_calls = draw_stats.draw_calls,
            .triangles_drawn = draw_stats.triangles_drawn,
        };
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

    fn resolveSelectionReadback(self: *Renderer) !void {
        const request = self.pending_selection_readback orelse return;
        defer self.pending_selection_readback = null;

        const id_texture = self.id_pass.texture() orelse {
            self.selected_entity = null;
            return;
        };
        if (id_texture.desc.width == 0 or id_texture.desc.height == 0) {
            self.selected_entity = null;
            return;
        }

        const pixel_x = @min(request.pixel_x, id_texture.desc.width - 1);
        const pixel_y = @min(request.pixel_y, id_texture.desc.height - 1);
        const pixel = try self.rhi.readTexturePixel(id_texture, pixel_x, pixel_y);
        self.selected_entity = id_pass_mod.decodeEntityIdBgra(pixel);
    }
};
