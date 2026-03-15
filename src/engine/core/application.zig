const std = @import("std");
const layer_mod = @import("layer.zig");
const layer_stack_mod = @import("layer_stack.zig");
const platform_mod = @import("platform.zig");
const renderer_mod = @import("../render/renderer.zig");
const render_types = @import("../render/types.zig");
const window_mod = @import("../platform/window.zig");
const scene_mod = @import("../scene/scene.zig");

pub const ApplicationConfig = struct {
    name: []const u8 = "Guava Engine",
    window_width: u32 = 1280,
    window_height: u32 = 720,
    frame_delay_ms: u32 = 16,
    preferred_backends: []const render_types.GraphicsAPI = &.{ .vulkan, .dx12, .metal },
    backend_selection_policy: render_types.BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
};

pub const RunReport = struct {
    frames: usize,
    backend: render_types.GraphicsAPI,
    scene: scene_mod.Summary,
    passes: usize,
    runtime: render_types.RuntimeInfo,
    draw_calls: usize,
    triangles_drawn: usize,
};

pub const Application = struct {
    allocator: std.mem.Allocator,
    config: ApplicationConfig,
    platform: platform_mod.Platform,
    window: window_mod.Window,
    renderer: renderer_mod.Renderer,
    scene: scene_mod.Scene,
    layers: layer_stack_mod.LayerStack,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: ApplicationConfig) !Application {
        const platform = platform_mod.detect();

        var window = try window_mod.Window.init(allocator, .{
            .title = config.name,
            .width = config.window_width,
            .height = config.window_height,
        });
        errdefer window.deinit();

        var scene = scene_mod.Scene.init(allocator);
        errdefer scene.deinit();
        try scene.bootstrap3D();

        const renderer = try renderer_mod.Renderer.init(allocator, platform, &window, .{
            .requested_backends = config.preferred_backends,
            .selection_policy = config.backend_selection_policy,
            .enable_validation = config.enable_validation,
            .frames_in_flight = config.frames_in_flight,
        });

        return .{
            .allocator = allocator,
            .config = config,
            .platform = platform,
            .window = window,
            .renderer = renderer,
            .scene = scene,
            .layers = layer_stack_mod.LayerStack.init(allocator),
        };
    }

    pub fn deinit(self: *Application) void {
        if (self.initialized) {
            self.detachLayers();
        }
        self.layers.deinit();
        self.scene.deinit();
        self.renderer.deinit();
        self.window.deinit();
    }

    pub fn pushLayer(self: *Application, layer: layer_mod.Layer) !void {
        try self.layers.pushLayer(layer);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try layer.attach(&layer_context);
        }
    }

    pub fn pushOverlay(self: *Application, overlay: layer_mod.Layer) !void {
        try self.layers.pushOverlay(overlay);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try overlay.attach(&layer_context);
        }
    }

    pub fn run(self: *Application, frame_count: usize) !RunReport {
        if (!self.initialized) {
            try self.attachLayers();
        }

        var frames_rendered: usize = 0;
        var last_frame = renderer_mod.FrameReport{
            .backend = self.renderer.backendApi(),
            .passes_executed = self.renderer.passCount(),
            .scene = .{},
            .runtime = self.renderer.runtimeInfo(),
        };

        while (frames_rendered < frame_count and !self.window.should_close) : (frames_rendered += 1) {
            try self.pumpEvents();

            const delta_seconds = @as(f32, @floatFromInt(self.config.frame_delay_ms)) / 1000.0;
            var layer_context = self.makeLayerContext(frames_rendered, delta_seconds);
            for (self.layers.layers.items) |layer| {
                try layer.update(&layer_context);
            }

            last_frame = try self.renderer.drawFrame(&self.scene);
            self.window.delay(self.config.frame_delay_ms);
        }

        const summary = self.scene.summary();
        return .{
            .frames = frames_rendered,
            .backend = self.renderer.backendApi(),
            .scene = summary,
            .passes = self.renderer.passCount(),
            .runtime = last_frame.runtime,
            .draw_calls = last_frame.draw_calls,
            .triangles_drawn = last_frame.triangles_drawn,
        };
    }

    fn attachLayers(self: *Application) !void {
        var layer_context = self.makeLayerContext(0, 0.0);
        for (self.layers.layers.items) |layer| {
            try layer.attach(&layer_context);
        }
        self.initialized = true;
    }

    fn detachLayers(self: *Application) void {
        var index = self.layers.layers.items.len;
        while (index > 0) {
            index -= 1;
            self.layers.layers.items[index].detach();
        }
        self.initialized = false;
    }

    fn pumpEvents(self: *Application) !void {
        while (try self.window.pollEvent()) |event| {
            switch (event.kind) {
                .resized, .pixel_size_changed, .metal_view_resized, .exposed => {
                    try self.renderer.handleResize(event.width, event.height);
                },
                .quit_requested, .close_requested => {
                    self.window.should_close = true;
                },
            }
        }
    }

    fn makeLayerContext(self: *Application, frame_index: usize, delta_seconds: f32) layer_mod.LayerContext {
        return .{
            .scene = &self.scene,
            .renderer = &self.renderer,
            .frame_index = frame_index,
            .delta_seconds = delta_seconds,
        };
    }
};
