//! 应用程序核心模块
//!
//! 本模块提供应用程序的生命周期管理和主循环实现。
//! Application 是 Guava Engine 应用的主入口点，负责协调所有子系统。
//!
//! ## 主要功能
//!
//! - **生命周期管理** - 初始化、运行、清理
//! - **窗口管理** - 创建和管理主窗口
//! - **渲染器集成** - 初始化和管理渲染系统
//! - **场景管理** - 创建和管理场景世界
//! - **层栈系统** - 管理应用逻辑层
//! - **输入处理** - 处理键盘、鼠标输入
//! - **物理模拟** - 固定时间步进物理
//! - **脚本系统** - 脚本热重载和执行
//! - **动画系统** - 骨骼动画更新
//!
//! ## 使用示例
//!
//! ```zig
//! const guava = @import("guava");
//!
//! pub fn main() !void {
//!     // 创建应用配置
//!     const config = guava.core.ApplicationConfig{
//!         .name = "My Game",
//!         .window_width = 1920,
//!         .window_height = 1080,
//!     };
//!
//!     // 初始化应用
//!     var app = try guava.core.Application.init(allocator, config);
//!     defer app.deinit();
//!
//!     // 推送应用层
//!     try app.pushLayer(my_layer);
//!
//!     // 运行应用（0 表示无限循环）
//!     const report = try app.run(0);
//! }
//! ```

const std = @import("std");
const animator_system = @import("../animation/animator_system.zig");
const physics_system = @import("../physics/system.zig");
const editor_utility_runtime_mod = @import("../script/editor_utility_runtime.zig");
const script_system = @import("../script/script.zig");
const handles = @import("../assets/handles.zig");
const layer_mod = @import("layer.zig");
const layer_stack_mod = @import("layer_stack.zig");
const input_mod = @import("input.zig");
const command_queue_mod = @import("command_queue.zig");
const platform_mod = @import("platform.zig");
const renderer_mod = @import("../render/renderer.zig");
const render_types = @import("../render/types.zig");
const imgui_mod = @import("../ui/imgui.zig");
const window_mod = @import("../platform/window.zig");
const scene_mod = @import("../scene/scene.zig");
const job_system_mod = @import("job_system.zig");

/// 应用程序配置
///
/// 用于初始化应用程序时指定各种参数。
pub const ApplicationConfig = struct {
    /// 应用程序名称（显示在窗口标题栏）
    name: []const u8 = "Guava Engine",
    /// 窗口宽度（像素）
    window_width: u32 = 1280,
    /// 窗口高度（像素）
    window_height: u32 = 720,
    /// 是否无边框窗口
    window_borderless: bool = false,
    /// 是否使用原生标题栏控件（macOS）
    window_native_titlebar_controls: bool = false,
    /// 帧延迟（毫秒，用于限制帧率）
    frame_delay_ms: u32 = 16,
    /// 首选的图形后端列表
    preferred_backends: []const render_types.GraphicsAPI = render_types.defaultPreferredBackends,
    /// 后端选择策略
    backend_selection_policy: render_types.BackendSelectionPolicy = .explicit_order,
    /// 是否启用验证层（调试用）
    enable_validation: bool = true,
    /// 帧在飞数量（用于帧同步）
    frames_in_flight: u32 = 2,
    /// 线程数量（null 表示自动检测）
    thread_count: ?usize = null,
    /// 物理系统配置
    physics: physics_system.Config = .{},
    /// 脚本系统配置
    script: script_system.ScriptSystemConfig = .{},
};

/// 运行报告
///
/// 包含应用程序运行结束后的统计信息。
pub const RunReport = struct {
    /// 渲染的帧数
    frames: usize,
    /// 使用的图形后端
    backend: render_types.GraphicsAPI,
    /// 场景摘要
    scene: scene_mod.Summary,
    /// 渲染通道数量
    passes: usize,
    /// 运行时信息
    runtime: render_types.RuntimeInfo,
    /// 绘制调用次数
    draw_calls: usize,
    /// 绘制的三角形数量
    triangles_drawn: usize,
};

/// 应用程序主类
///
/// 管理引擎的所有子系统，提供主循环实现。
/// 这是构建 Guava Engine 应用的核心类。
///
/// ## 生命周期
///
/// 1. `init()` - 初始化所有子系统
/// 2. `pushLayer()` / `pushOverlay()` - 添加应用逻辑层
/// 3. `run()` - 运行主循环
/// 4. `deinit()` - 清理所有资源
///
/// ## 子系统
///
/// - **Window** - 窗口管理
/// - **Renderer** - 渲染系统
/// - **World** - 场景世界
/// - **JobSystem** - 作业系统
/// - **ScriptRuntime** - 脚本运行时
/// - **InputState** - 输入状态
/// - **LayerStack** - 层栈
pub const Application = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 应用程序配置
    config: ApplicationConfig,
    /// 平台信息
    platform: platform_mod.Platform,
    /// 主窗口
    window: window_mod.Window,
    /// 渲染器
    renderer: renderer_mod.Renderer,
    /// 引擎级命令队列
    command_queue: command_queue_mod.CommandQueue,
    /// 场景世界
    world: scene_mod.World,
    /// 层栈
    layers: layer_stack_mod.LayerStack,
    /// 作业系统
    job_system: *job_system_mod.JobSystem,
    /// 脚本运行时
    script_runtime: script_system.ScriptRuntime,
    /// 编辑器 Utility 运行时
    editor_utility_runtime: editor_utility_runtime_mod.EditorUtilityRuntime,
    /// 输入状态
    input: input_mod.InputState = .{},
    /// 播放控制器（用于暂停/步进）
    playback_controller: layer_mod.PlaybackController = .{},
    /// 是否已初始化
    initialized: bool = false,
    /// 高精度计时器
    timer: std.time.Timer,
    /// 全局时间（秒）
    global_time: f32 = 0.0,
    /// 时间缩放（用于慢动作、暂停等）
    time_scale: f32 = 1.0,
    /// 物理时间累积器
    physics_accumulator_seconds: f32 = 0.0,

    /// 初始化应用程序
    ///
    /// 创建窗口、渲染器、场景世界等所有子系统。
    ///
    /// ## 参数
    /// - `allocator` - 内存分配器
    /// - `config` - 应用程序配置
    ///
    /// ## 返回
    /// 初始化的 Application 实例
    ///
    /// ## 错误
    /// - `error.OutOfMemory` - 内存不足
    /// - `error.DeviceCreationFailed` - GPU 设备创建失败
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
            .command_queue = command_queue_mod.CommandQueue.init(allocator),
            .world = world,
            .job_system = job_system,
            .script_runtime = script_runtime,
            .editor_utility_runtime = editor_utility_runtime_mod.EditorUtilityRuntime.init(allocator),
            .layers = layer_stack_mod.LayerStack.init(allocator),
            .input = .{},
            .timer = timer,
        };
    }

    /// 清理应用程序
    ///
    /// 释放所有子系统占用的资源。
    /// 调用此方法后，应用程序不再可用。
    pub fn deinit(self: *Application) void {
        self.bindRuntimeContext();
        self.script_runtime.callDestroyAll(&self.world);
        if (self.initialized) {
            self.detachLayers();
        }
        self.layers.deinit();
        self.editor_utility_runtime.deinit();
        self.script_runtime.deinit();
        physics_system.deinitWorld(&self.world);
        self.world.deinit();
        self.command_queue.deinit();
        self.renderer.deinit();
        self.window.deinit();
        self.job_system.deinit();
    }

    /// 推送层到层栈
    ///
    /// 层是应用逻辑的基本单位。层按顺序更新，
    /// 后推送的层在先推送的层之上。
    ///
    /// ## 参数
    /// - `layer` - 要推送的层
    pub fn pushLayer(self: *Application, layer: layer_mod.Layer) !void {
        try self.layers.pushLayer(layer);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try layer.attach(&layer_context);
        }
    }

    /// 推送覆盖层到层栈
    ///
    /// 覆盖层总是在普通层之上渲染。
    /// 通常用于 UI 层。
    ///
    /// ## 参数
    /// - `overlay` - 要推送的覆盖层
    pub fn pushOverlay(self: *Application, overlay: layer_mod.Layer) !void {
        try self.layers.pushOverlay(overlay);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try overlay.attach(&layer_context);
        }
    }

    /// 运行应用程序主循环
    ///
    /// 主循环持续运行直到窗口关闭或达到指定帧数。
    /// 每帧执行以下操作：
    /// 1. 处理输入事件
    /// 2. 更新动画系统
    /// 3. 步进物理模拟
    /// 4. 更新脚本系统
    /// 5. 更新层级变换
    /// 6. 更新所有层
    /// 7. 渲染帧
    ///
    /// ## 参数
    /// - `frame_count` - 要渲染的帧数（0 表示无限循环）
    ///
    /// ## 返回
    /// 运行报告，包含统计信息
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

            try self.applyPendingCommands();

            // 更新全局时间
            self.global_time += delta_seconds * self.time_scale;

            const should_advance_simulation = self.playback_controller.shouldAdvance();
            if (should_advance_simulation) {
                animator_system.update(&self.world, delta_seconds);
                self.advancePhysics(delta_seconds);
                // 更新脚本系统（传递时间和输入）
                self.updateScripts(delta_seconds);
                try self.applyPendingCommands();
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

    /// 附加所有层
    fn attachLayers(self: *Application) !void {
        var layer_context = self.makeLayerContext(0, 0.0);
        for (self.layers.layers.items) |layer| {
            try layer.attach(&layer_context);
        }
        self.initialized = true;
    }

    /// 分离所有层
    fn detachLayers(self: *Application) void {
        var index = self.layers.layers.items.len;
        while (index > 0) {
            index -= 1;
            self.layers.layers.items[index].detach();
        }
        self.initialized = false;
    }

    /// 处理窗口事件
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

    /// 创建层上下文
    fn makeLayerContext(self: *Application, frame_index: usize, delta_seconds: f32) layer_mod.LayerContext {
        return .{
            .world = &self.world,
            .scene = &self.world,
            .renderer = &self.renderer,
            .command_queue = &self.command_queue,
            .script_runtime = &self.script_runtime,
            .editor_utility_runtime = &self.editor_utility_runtime,
            .input = &self.input,
            .window = &self.window,
            .playback_controller = &self.playback_controller,
            .frame_index = frame_index,
            .delta_seconds = delta_seconds,
        };
    }

    /// 步进物理模拟
    ///
    /// 使用固定时间步进，确保物理模拟的稳定性。
    /// 支持多次子步进以处理帧率波动。
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

    /// 更新脚本系统
    ///
    /// 检查热重载，调用所有脚本的 OnUpdate 方法。
    fn updateScripts(self: *Application, delta_seconds: f32) void {
        self.bindRuntimeContext();

        // 检查热重载
        self.script_runtime.checkHotReload();
        self.script_runtime.reconcileWorld(&self.world);

        // 遍历存活实例，避免脚本在更新时修改 world.entities 破坏迭代。
        var instance_iter = self.script_runtime.instances.valueIterator();
        while (instance_iter.next()) |instance_ptr| {
            const instance = instance_ptr.*;
            const entity = self.world.getEntityConst(instance.entity_id) orelse continue;
            const script = entity.script orelse continue;
            const script_language: script_system.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
            if (!script.enabled or
                script.instance_id != instance.id or
                script.script_handle == null or
                script.script_handle.? != instance.script_handle or
                script_language != instance.language)
            {
                continue;
            }

            if (self.script_runtime.getVM(instance.language)) |vm| {
                var ctx = script_system.ScriptContext{
                    .entity = entity.id,
                    .world = &self.world,
                    .instance = instance,
                    .allocator = self.allocator,
                    .command_queue = &self.command_queue,
                    .input = &self.input,
                    .time = self.global_time,
                    .delta_time = delta_seconds,
                    .time_scale = self.time_scale,
                };

                vm.callUpdate(instance, &ctx, delta_seconds) catch |err| {
                    std.log.err("Script update error for entity {}: {}", .{ entity.id, err });
                    self.script_runtime.recordEvent(.{
                        .script_handle = instance.script_handle,
                        .entity_id = entity.id,
                        .phase = .update,
                        .severity = .@"error",
                        .message = vm.getError(),
                    });
                    instance.state = .failed;
                };
            }
        }
    }

    /// 加载脚本资源
    ///
    /// 从文件加载脚本并注册到资源系统。
    /// 支持热重载。
    ///
    /// ## 参数
    /// - `path` - 脚本文件路径
    ///
    /// ## 返回
    /// 脚本资源句柄
    pub fn loadScript(self: *Application, path: []const u8) !handles.ScriptHandle {
        self.bindRuntimeContext();
        const source = try std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(source);

        const desc = .{
            .source = source,
            .language = .zig,
            .entry_fn = "main",
            .description = path,
            .source_path = path,
        };

        const handle = try self.world.resources.createScript(desc);
        if (self.script_runtime.hot_reload) |*hr| {
            try hr.registerScript(path, handle);
        }
        return handle;
    }

    fn applyPendingCommands(self: *Application) !void {
        if (self.command_queue.len() == 0) {
            return;
        }

        const results = try self.command_queue.executeAll(&self.world);
        defer self.allocator.free(results);

        for (results) |result| {
            if (result.err) |err| {
                std.log.warn("command queue execution failed for entity {any}: {s}", .{
                    result.entity_id,
                    @tagName(err),
                });
            }
        }
    }

    fn bindRuntimeContext(self: *Application) void {
        self.script_runtime.bindWorld(&self.world);
        self.script_runtime.bindCommandQueue(&self.command_queue);
    }
};
