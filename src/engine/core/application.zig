const std = @import("std");
const animator_system = @import("../animation/animator_system.zig");
const physics_system = @import("../physics/system.zig");
const script_system = @import("../script/script.zig");
const handles = @import("../assets/handles.zig");
const layer_mod = @import("layer.zig");
const layer_stack_mod = @import("layer_stack.zig");
const input_mod = @import("input.zig");
const platform_mod = @import("platform.zig");
const renderer_mod = @import("../render/renderer.zig");
const render_types = @import("../render/types.zig");
const imgui_mod = @import("../ui/imgui.zig");
const window_mod = @import("../platform/window.zig");
const scene_mod = @import("../scene/scene.zig");
const job_system_mod = @import("job_system.zig");

pub const ApplicationConfig = struct {
    name: []const u8 = "Guava Engine",
    window_width: u32 = 1280,
    window_height: u32 = 720,
    window_borderless: bool = false,
    window_native_titlebar_controls: bool = false,
    frame_delay_ms: u32 = 16,
    preferred_backends: []const render_types.GraphicsAPI = render_types.defaultPreferredBackends,
    backend_selection_policy: render_types.BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
    thread_count: ?usize = null,
    physics: physics_system.Config = .{},
    script: script_system.ScriptSystemConfig = .{},
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
    world: scene_mod.World,
    layers: layer_stack_mod.LayerStack,
    job_system: *job_system_mod.JobSystem,
    script_runtime: script_system.ScriptRuntime,
    input: input_mod.InputState = .{},
    playback_controller: layer_mod.PlaybackController = .{},
    initialized: bool = false,
    timer: std.time.Timer,
    /// 全局时间（秒）
    global_time: f32 = 0.0,
    /// 时间缩放（用于慢动作、暂停等）
    time_scale: f32 = 1.0,
    /// 物理时间累积器
    physics_accumulator_seconds: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator, config: ApplicationConfig) !Application {
        const platform = platform_mod.detect();

        var window = try window_mod.Window.init(allocator, .{
            .title = config.name,
            .width = config.window_width,
            .height = config.window_height,
            .borderless = config.window_borderless,
            .native_titlebar_controls = config.window_native_titlebar_controls,
        });
        errdefer window.deinit();

        const job_system = try job_system_mod.JobSystem.init(allocator, config.thread_count);
        errdefer job_system.deinit();

        var world = scene_mod.World.init(allocator, job_system);
        errdefer world.deinit();
        try world.bootstrap3D();

        const renderer = try renderer_mod.Renderer.init(allocator, platform, &window, .{
            .requested_backends = config.preferred_backends,
            .selection_policy = config.backend_selection_policy,
            .enable_validation = config.enable_validation,
            .frames_in_flight = config.frames_in_flight,
        });

        // 初始化脚本运行时
        var script_runtime = script_system.ScriptRuntime.init(allocator, config.script);
        try script_runtime.initVMs();

        const timer = try std.time.Timer.start();

        return .{
            .allocator = allocator,
            .config = config,
            .platform = platform,
            .window = window,
            .renderer = renderer,
            .world = world,
            .job_system = job_system,
            .script_runtime = script_runtime,
            .layers = layer_stack_mod.LayerStack.init(allocator),
            .input = .{},
            .timer = timer,
        };
    }

    pub fn deinit(self: *Application) void {
        if (self.initialized) {
            self.detachLayers();
        }
        self.layers.deinit();
        self.script_runtime.deinit();
        physics_system.deinitWorld(&self.world);
        self.world.deinit();
        self.renderer.deinit();
        self.window.deinit();
        self.job_system.deinit();
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
            .graph_resources = self.renderer.graph.resourceCount(),
            .scene = .{},
            .runtime = self.renderer.runtimeInfo(),
        };

        while ((frame_count == 0 or frames_rendered < frame_count) and !self.window.should_close) : (frames_rendered += 1) {
            self.input.beginFrame();
            try self.pumpEvents();
            imgui_mod.newFrame();

            const elapsed_ns = self.timer.lap();
            var delta_seconds = @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
            delta_seconds = @min(delta_seconds, 0.1); // 最大帧间隔锁定为 0.1 秒
            
            // 更新全局时间
            self.global_time += delta_seconds * self.time_scale;
            
            const should_advance_simulation = self.playback_controller.shouldAdvance();
            if (should_advance_simulation) {
                animator_system.update(&self.world, delta_seconds);
                self.advancePhysics(delta_seconds);
                // 更新脚本系统（传递时间和输入）
                self.updateScripts(delta_seconds);
            }

            // P1: Update hierarchy transforms and bounds once per frame
            self.world.updateHierarchy();

            var layer_context = self.makeLayerContext(frames_rendered, delta_seconds);
            for (self.layers.layers.items, 0..) |layer, index| {
                if (index < self.layers.overlay_start and !should_advance_simulation) {
                    continue;
                }
                layer.update(&layer_context) catch |err| {
                    std.log.err("layer '{s}' update failed: {s}", .{ layer.name, @errorName(err) });
                };
            }
            if (should_advance_simulation) {
                self.playback_controller.consumeAdvance();
            }

            last_frame = try self.renderer.drawFrame(&self.world);
        }

        const summary = self.world.summary();
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
            imgui_mod.processEvent(&event.raw);
            const wants_text_input = imgui_mod.wantsTextInput();
            switch (event.kind) {
                .resized, .pixel_size_changed, .metal_view_resized, .exposed => {
                    try self.renderer.handleResize(event.width, event.height);
                },
                .quit_requested, .close_requested => {
                    self.window.should_close = true;
                },
                .mouse_button_down => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    if (event.button) |button| {
                        self.input.setMouseButton(button, true, event.clicks);
                    }
                },
                .mouse_button_up => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    if (event.button) |button| {
                        self.input.setMouseButton(button, false, event.clicks);
                    }
                },
                .mouse_moved => {
                    self.input.setModifiers(event.modifiers);
                    // Editor viewport interactions decide their own hover/capture rules.
                    // Always forwarding raw mouse motion keeps orbit, gizmo drag, selection,
                    // and view-cube interactions responsive even inside ImGui windows.
                    self.input.addMouseDelta(event.x, event.y, event.delta_x, event.delta_y);
                },
                .mouse_wheel => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    self.input.addMouseWheel(event.delta_x, event.delta_y);
                },
                .key_down => {
                    self.input.setModifiers(event.modifiers);
                    if (!wants_text_input) {
                        if (event.key) |key| {
                            self.input.setKey(key, true);
                        }
                    }
                },
                .key_up => {
                    self.input.setModifiers(event.modifiers);
                    if (event.key) |key| {
                        if (!wants_text_input or self.input.isKeyDown(key)) {
                            self.input.setKey(key, false);
                        }
                    }
                },
            }
        }
    }

    fn makeLayerContext(self: *Application, frame_index: usize, delta_seconds: f32) layer_mod.LayerContext {
        return .{
            .world = &self.world,
            .scene = &self.world,
            .renderer = &self.renderer,
            .input = &self.input,
            .window = &self.window,
            .playback_controller = &self.playback_controller,
            .frame_index = frame_index,
            .delta_seconds = delta_seconds,
        };
    }

    fn advancePhysics(self: *Application, delta_seconds: f32) void {
        if (!self.config.physics.enabled or self.config.physics.fixed_timestep_seconds <= 0.0001) {
            return;
        }

        const max_window = self.config.physics.fixed_timestep_seconds *
            @as(f32, @floatFromInt(self.config.physics.max_substeps_per_frame));
        self.physics_accumulator_seconds = @min(self.physics_accumulator_seconds + delta_seconds, max_window);

        var substeps: u8 = 0;
        while (self.physics_accumulator_seconds + 0.000001 >= self.config.physics.fixed_timestep_seconds and
            substeps < self.config.physics.max_substeps_per_frame) : (substeps += 1)
        {
            _ = physics_system.step(&self.world, self.config.physics.fixed_timestep_seconds, self.config.physics);
            self.physics_accumulator_seconds -= self.config.physics.fixed_timestep_seconds;
        }

        if (substeps == self.config.physics.max_substeps_per_frame and
            self.physics_accumulator_seconds >= self.config.physics.fixed_timestep_seconds)
        {
            self.physics_accumulator_seconds = 0.0;
        }
    }

    fn updateScripts(self: *Application, delta_seconds: f32) void {
        // 检查热重载
        self.script_runtime.checkHotReload();
        
        // 遍历所有实体，调用脚本的 OnUpdate
        for (self.world.entities.items) |*entity| {
            if (entity.script) |*script| {
                if (!script.enabled) continue;
                if (script.instance_id) |instance_id| {
                    // 获取脚本实例
                    if (self.script_runtime.instances.get(instance_id)) |instance| {
                        // 获取 VM
                        if (self.script_runtime.getVM(script.language)) |vm| {
                            // 创建上下文（包含输入和时间）
                            var ctx = script_system.context.ScriptContext{
                                .entity = entity.id,
                                .world = &self.world,
                                .instance = instance,
                                .allocator = self.allocator,
                                .input = &self.input,
                                .time = self.global_time,
                                .delta_time = delta_seconds,
                                .time_scale = self.time_scale,
                            };
                            
                            // 调用 OnUpdate（处理错误）
                            vm.callUpdate(instance, &ctx, delta_seconds) catch |err| {
                                std.log.err("Script update error: {}", .{err});
                                instance.state = .failed;
                            };
                        }
                    }
                }
            }
        }
    }

    /// 加载脚本资源
    pub fn loadScript(self: *Application, path: []const u8) !handles.ScriptHandle {
        const source = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        errdefer self.allocator.free(source);

        const desc = .{
            .source = source,
            .language = .zig,
            .entry_fn = "main",
            .description = path,
            .source_path = path,
        };

        const handle = try self.world.resources.createScript(desc);
        return handle;
    }
};
