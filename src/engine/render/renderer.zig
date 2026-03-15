const std = @import("std");
const platform_mod = @import("../core/platform.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const primitive_stage_mod = @import("primitive_stage.zig");
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

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    platform: platform_mod.Platform,
    rhi: rhi_mod.RhiDevice,
    graph: graph_mod.RenderGraph,
    primitive_stage: primitive_stage_mod.PrimitiveStage,

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
            .primitive_stage = undefined,
        };
        errdefer renderer.graph.deinit();
        errdefer renderer.rhi.deinit();

        renderer.primitive_stage = try primitive_stage_mod.PrimitiveStage.init(allocator, &renderer.rhi);
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.primitive_stage.deinit(&self.rhi);
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

        if (!self.primitive_stage.isReady()) {
            try self.rhi.clearAndPresent(frame, clear);
            return .{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
            };
        }

        const pass = try self.rhi.beginRenderPass(frame, clear);
        const draw_stats = try self.primitive_stage.draw(&self.rhi, frame, pass, scene);
        self.rhi.endRenderPass(pass);
        try self.rhi.submitFrame(frame);

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
};
