const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const types = @import("./types.zig");
const context = @import("./context.zig");
const vm_interface = @import("./vm_interface.zig");
const wasm_vm_mod = @import("./wasm_vm.zig");
const components = @import("../scene/components.zig");
const quat = @import("../math/quat.zig");
const vec3 = @import("../math/vec3.zig");
const world_mod = @import("../scene/world.zig");
const input_mod = @import("../core/input.zig");

const log = std.log.scoped(.vm);

const BuiltinKind = enum(u8) {
    none,
    rotate,
    patrol,
    fly_camera,
    fps_controller,
};

const ScriptDefinition = struct {
    kind: BuiltinKind = .none,

    rotate_axis: components.Vec3 = .{ 0.0, 1.0, 0.0 },
    rotate_speed_radians: f32 = std.math.pi * 0.25,
    rotate_local_space: bool = true,

    patrol_speed: f32 = 2.0,
    patrol_waypoints: [8]components.Vec3 = [_]components.Vec3{.{ 0.0, 0.0, 0.0 }} ** 8,
    patrol_waypoint_count: u8 = 0,
    patrol_arrival_threshold: f32 = 0.1,
    patrol_loop: bool = true,
    patrol_wait_at_waypoint: bool = false,
    patrol_wait_time: f32 = 1.0,

    fly_move_speed: f32 = 5.0,
    fly_mouse_sensitivity: f32 = 0.002,

    fps_move_speed: f32 = 5.0,
    fps_mouse_sensitivity: f32 = 0.002,
    fps_gravity: f32 = -9.8,
    fps_jump_velocity: f32 = 5.0,
};

const RotateState = struct {
    axis: components.Vec3,
    speed_radians: f32,
    local_space: bool,
};

const PatrolState = struct {
    speed: f32,
    waypoints: [8]components.Vec3,
    waypoint_count: u8,
    arrival_threshold: f32,
    loop: bool,
    wait_at_waypoint: bool,
    wait_time: f32,
    wait_timer: f32 = 0.0,
    current_waypoint: u8 = 0,
};

const FlyCameraState = struct {
    move_speed: f32,
    mouse_sensitivity: f32,
    first_mouse: bool = true,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    pitch: f32 = 0.0,
    yaw: f32 = -std.math.pi * 0.5,
};

const FpsControllerState = struct {
    move_speed: f32,
    mouse_sensitivity: f32,
    gravity: f32,
    jump_velocity: f32,
    is_grounded: bool = false,
    vertical_velocity: f32 = 0.0,
    first_mouse: bool = true,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    pitch: f32 = 0.0,
    yaw: f32 = -std.math.pi * 0.5,
};

pub const ScriptVM = vm_interface.ScriptVM;
pub const WasmVM = wasm_vm_mod.WasmVM;

/// Zig 原生虚拟机 - 使用内建脚本定义驱动运行时行为
pub const ZigVM = struct {
    /// 当前加载的脚本源码
    source: []const u8 = &.{},
    /// 已解析的内建脚本定义
    definition: ScriptDefinition = .{},
    /// 错误信息
    error_msg: []u8 = &.{},
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZigVM {
        return .{
            .allocator = allocator,
        };
    }

    pub fn load(vm: *ZigVM, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        if (resource.language != .zig) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "script language does not match ZigVM");
            return types.ScriptError.InvalidLanguage;
        }

        vm.source = resource.source;
        vm.definition = parseScriptDefinition(resource.source) catch |err| {
            const message = switch (err) {
                error.InvalidDirective => "invalid //!guava directive in Zig script",
                error.UnsupportedBuiltinScript => "dynamic Zig compilation is unavailable; add //!guava builtin=rotate|patrol|fly_camera|fps_controller",
            };
            setOwnedMessage(vm.allocator, &vm.error_msg, message);
            return types.ScriptError.CompileError;
        };

        clearOwnedMessage(vm.allocator, &vm.error_msg);
        log.info("Zig builtin script loaded kind={s}", .{@tagName(vm.definition.kind)});
    }

    pub fn unload(vm: *ZigVM) void {
        vm.source = &.{};
        vm.definition = .{};
        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }

    pub fn createInstance(vm: *ZigVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        if (vm.definition.kind == .none) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "no Zig builtin script is loaded");
            return types.ScriptError.NotFound;
        }

        const instance = try vm.allocator.create(types.ScriptInstance);
        errdefer vm.allocator.destroy(instance);

        instance.* = .{
            .id = 0, // 由 runtime 分配
            .entity_id = ctx.entity,
            .script_handle = undefined,
            .vtable = vtableForKind(vm.definition.kind),
            .user_data_tag = @intFromEnum(vm.definition.kind),
            .state = .ready,
        };

        switch (vm.definition.kind) {
            .rotate => {
                const state = try vm.allocator.create(RotateState);
                state.* = .{
                    .axis = vec3.normalize(vm.definition.rotate_axis),
                    .speed_radians = vm.definition.rotate_speed_radians,
                    .local_space = vm.definition.rotate_local_space,
                };
                instance.user_data = state;
                instance.user_data_size = @sizeOf(RotateState);
            },
            .patrol => {
                const state = try vm.allocator.create(PatrolState);
                state.* = .{
                    .speed = vm.definition.patrol_speed,
                    .waypoints = vm.definition.patrol_waypoints,
                    .waypoint_count = vm.definition.patrol_waypoint_count,
                    .arrival_threshold = vm.definition.patrol_arrival_threshold,
                    .loop = vm.definition.patrol_loop,
                    .wait_at_waypoint = vm.definition.patrol_wait_at_waypoint,
                    .wait_time = vm.definition.patrol_wait_time,
                };
                instance.user_data = state;
                instance.user_data_size = @sizeOf(PatrolState);
            },
            .fly_camera => {
                const state = try vm.allocator.create(FlyCameraState);
                state.* = .{
                    .move_speed = vm.definition.fly_move_speed,
                    .mouse_sensitivity = vm.definition.fly_mouse_sensitivity,
                };
                initializeLookAnglesFromTransform(&state.pitch, &state.yaw, ctx);
                instance.user_data = state;
                instance.user_data_size = @sizeOf(FlyCameraState);
            },
            .fps_controller => {
                const state = try vm.allocator.create(FpsControllerState);
                state.* = .{
                    .move_speed = vm.definition.fps_move_speed,
                    .mouse_sensitivity = vm.definition.fps_mouse_sensitivity,
                    .gravity = vm.definition.fps_gravity,
                    .jump_velocity = vm.definition.fps_jump_velocity,
                };
                initializeLookAnglesFromTransform(&state.pitch, &state.yaw, ctx);
                instance.user_data = state;
                instance.user_data_size = @sizeOf(FpsControllerState);
            },
            .none => unreachable,
        }

        return instance;
    }

    pub fn destroyInstance(vm: *ZigVM, instance: *types.ScriptInstance) void {
        if (instance.user_data) |data| {
            switch (builtinKindFromTag(instance.user_data_tag)) {
                .rotate => vm.allocator.destroy(castUserData(RotateState, data)),
                .patrol => vm.allocator.destroy(castUserData(PatrolState, data)),
                .fly_camera => vm.allocator.destroy(castUserData(FlyCameraState, data)),
                .fps_controller => vm.allocator.destroy(castUserData(FpsControllerState, data)),
                .none => {},
            }
            instance.user_data = null;
            instance.user_data_size = 0;
        }
        vm.allocator.destroy(instance);
    }

    pub fn callInit(_: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        ctx.instance = instance;
        if (instance.vtable.onInit) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn callUpdate(_: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        ctx.instance = instance;
        if (instance.vtable.onUpdate) |fn_ptr| {
            fn_ptr(ctx, dt);
        }
    }

    pub fn callDestroy(_: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        ctx.instance = instance;
        if (instance.vtable.onDestroy) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn getError(vm: *ZigVM) []const u8 {
        return vm.error_msg;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(ZigVM, context_ptr);
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        allocator.destroy(vm);
    }

    /// 获取 Zig VM 的 VTable
    pub const script_vm_vtable: ScriptVM.VTable = .{
        .load = zigLoadBridge,
        .unload = zigUnloadBridge,
        .createInstance = zigCreateInstanceBridge,
        .destroyInstance = zigDestroyInstanceBridge,
        .callInit = zigCallInitBridge,
        .callUpdate = zigCallUpdateBridge,
        .callDestroy = zigCallDestroyBridge,
        .getError = zigGetErrorBridge,
        .destroy = destroyContext,
    };
};

/// C# 虚拟机存根 - 当前构建不包含 .NET 运行时
pub const CSharpVM = struct {
    allocator: std.mem.Allocator,
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) CSharpVM {
        return .{ .allocator = allocator };
    }

    pub fn load(vm: *CSharpVM, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        if (resource.language != .csharp) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "script language does not match CSharpVM");
            return types.ScriptError.InvalidLanguage;
        }
        setOwnedMessage(vm.allocator, &vm.error_msg, "C# scripting is not available in this build");
        return types.ScriptError.NotFound;
    }

    pub fn getError(vm: *CSharpVM) []const u8 {
        return vm.error_msg;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(CSharpVM, context_ptr);
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        allocator.destroy(vm);
    }

    pub const script_vm_vtable: ScriptVM.VTable = .{
        .load = csharpLoadBridge,
        .unload = csharpUnloadBridge,
        .createInstance = csharpCreateInstanceBridge,
        .destroyInstance = csharpDestroyInstanceBridge,
        .callInit = csharpCallInitBridge,
        .callUpdate = csharpCallUpdateBridge,
        .callDestroy = csharpCallDestroyBridge,
        .getError = csharpGetErrorBridge,
        .destroy = destroyContext,
    };

    fn unloadStub(vm: *CSharpVM) void {
        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }
    fn createInstanceStub(vm: *CSharpVM, _: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        setOwnedMessage(vm.allocator, &vm.error_msg, "C# scripting is not available in this build");
        return types.ScriptError.NotFound;
    }
    fn destroyInstanceStub(vm: *CSharpVM, instance: *types.ScriptInstance) void {
        vm.allocator.destroy(instance);
    }
    fn callInitStub(vm: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {
        setOwnedMessage(vm.allocator, &vm.error_msg, "C# scripting is not available in this build");
        return types.ScriptError.NotFound;
    }
    fn callUpdateStub(vm: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext, _: f32) types.ScriptError!void {
        setOwnedMessage(vm.allocator, &vm.error_msg, "C# scripting is not available in this build");
        return types.ScriptError.NotFound;
    }
    fn callDestroyStub(vm: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {
        setOwnedMessage(vm.allocator, &vm.error_msg, "C# scripting is not available in this build");
        return types.ScriptError.NotFound;
    }
};

/// 获取指定语言的虚拟机
pub fn createVM(language: types.ScriptLanguage, allocator: std.mem.Allocator) types.ScriptError!*ScriptVM {
    switch (language) {
        .zig => {
            const script_vm = try allocator.create(ScriptVM);
            errdefer allocator.destroy(script_vm);
            const vm = try allocator.create(ZigVM);
            errdefer allocator.destroy(vm);
            vm.* = ZigVM.init(allocator);
            script_vm.* = .{
                .context = vm,
                .vtable = &ZigVM.script_vm_vtable,
            };
            return script_vm;
        },
        .csharp => {
            const script_vm = try allocator.create(ScriptVM);
            errdefer allocator.destroy(script_vm);
            const vm = try allocator.create(CSharpVM);
            errdefer allocator.destroy(vm);
            vm.* = CSharpVM.init(allocator);
            script_vm.* = .{
                .context = vm,
                .vtable = &CSharpVM.script_vm_vtable,
            };
            return script_vm;
        },
        .wasm => {
            const script_vm = try allocator.create(ScriptVM);
            errdefer allocator.destroy(script_vm);
            const vm = try allocator.create(WasmVM);
            errdefer allocator.destroy(vm);
            vm.* = try WasmVM.init(allocator);
            script_vm.* = .{
                .context = vm,
                .vtable = &WasmVM.script_vm_vtable,
            };
            return script_vm;
        },
    }
}

fn clearOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8) void {
    if (slot.*.len != 0) {
        allocator.free(slot.*);
        slot.* = &.{};
    }
}

fn setOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8, message: []const u8) void {
    clearOwnedMessage(allocator, slot);
    slot.* = allocator.dupe(u8, message) catch &.{};
}

fn parseScriptDefinition(source: []const u8) !ScriptDefinition {
    var definition = ScriptDefinition{};
    var found_directive = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const payload = directivePayload(line) orelse continue;
        found_directive = true;

        var tokens = std.mem.tokenizeScalar(u8, payload, ' ');
        while (tokens.next()) |token| {
            try applyDirectiveToken(&definition, token);
        }
    }

    if (!found_directive) {
        if (inferLegacyDefinition(source)) |legacy| {
            return legacy;
        }
        return error.UnsupportedBuiltinScript;
    }

    if (definition.kind == .none) {
        return error.InvalidDirective;
    }
    return definition;
}

fn directivePayload(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "//!guava")) {
        return std.mem.trimLeft(u8, line["//!guava".len..], " \t");
    }
    if (std.mem.startsWith(u8, line, "// guava:")) {
        return std.mem.trimLeft(u8, line["// guava:".len..], " \t");
    }
    return null;
}

fn applyDirectiveToken(definition: *ScriptDefinition, token: []const u8) !void {
    if (token.len == 0) {
        return;
    }

    const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidDirective;
    const key = token[0..eq_index];
    const value = token[eq_index + 1 ..];

    if (std.mem.eql(u8, key, "builtin")) {
        definition.kind = try parseBuiltinKind(value);
        return;
    }

    switch (definition.kind) {
        .rotate => try applyRotateDirective(definition, key, value),
        .patrol => try applyPatrolDirective(definition, key, value),
        .fly_camera => try applyFlyDirective(definition, key, value),
        .fps_controller => try applyFpsDirective(definition, key, value),
        .none => return error.InvalidDirective,
    }
}

fn applyRotateDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "axis")) {
        definition.rotate_axis = try parseVec3Value(value);
    } else if (std.mem.eql(u8, key, "speed_deg")) {
        definition.rotate_speed_radians = try parseFloatValue(value) * (std.math.pi / 180.0);
    } else if (std.mem.eql(u8, key, "speed_rad")) {
        definition.rotate_speed_radians = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "local")) {
        definition.rotate_local_space = try parseBoolValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn applyPatrolDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "speed")) {
        definition.patrol_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "arrival")) {
        definition.patrol_arrival_threshold = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "loop")) {
        definition.patrol_loop = try parseBoolValue(value);
    } else if (std.mem.eql(u8, key, "wait")) {
        definition.patrol_wait_at_waypoint = try parseBoolValue(value);
    } else if (std.mem.eql(u8, key, "wait_time")) {
        definition.patrol_wait_time = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "waypoints")) {
        var count: usize = 0;
        var waypoint_it = std.mem.splitScalar(u8, value, ';');
        while (waypoint_it.next()) |waypoint| {
            if (waypoint.len == 0) {
                continue;
            }
            if (count >= definition.patrol_waypoints.len) {
                return error.InvalidDirective;
            }
            definition.patrol_waypoints[count] = try parseVec3Value(waypoint);
            count += 1;
        }
        definition.patrol_waypoint_count = @intCast(count);
    } else {
        return error.InvalidDirective;
    }
}

fn applyFlyDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "move_speed")) {
        definition.fly_move_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "mouse_sensitivity")) {
        definition.fly_mouse_sensitivity = try parseFloatValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn applyFpsDirective(definition: *ScriptDefinition, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "move_speed")) {
        definition.fps_move_speed = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "mouse_sensitivity")) {
        definition.fps_mouse_sensitivity = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "gravity")) {
        definition.fps_gravity = try parseFloatValue(value);
    } else if (std.mem.eql(u8, key, "jump_velocity")) {
        definition.fps_jump_velocity = try parseFloatValue(value);
    } else {
        return error.InvalidDirective;
    }
}

fn parseBuiltinKind(value: []const u8) !BuiltinKind {
    if (std.mem.eql(u8, value, "rotate")) return .rotate;
    if (std.mem.eql(u8, value, "patrol")) return .patrol;
    if (std.mem.eql(u8, value, "fly_camera")) return .fly_camera;
    if (std.mem.eql(u8, value, "fps_controller")) return .fps_controller;
    return error.InvalidDirective;
}

fn parseBoolValue(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidDirective;
}

fn parseFloatValue(value: []const u8) !f32 {
    return std.fmt.parseFloat(f32, value) catch error.InvalidDirective;
}

fn parseVec3Value(value: []const u8) !components.Vec3 {
    if (std.mem.eql(u8, value, "x")) return .{ 1.0, 0.0, 0.0 };
    if (std.mem.eql(u8, value, "y")) return .{ 0.0, 1.0, 0.0 };
    if (std.mem.eql(u8, value, "z")) return .{ 0.0, 0.0, 1.0 };

    var parts = std.mem.splitScalar(u8, value, ',');
    const x = parts.next() orelse return error.InvalidDirective;
    const y = parts.next() orelse return error.InvalidDirective;
    const z = parts.next() orelse return error.InvalidDirective;
    if (parts.next() != null) return error.InvalidDirective;

    return .{
        try parseFloatValue(x),
        try parseFloatValue(y),
        try parseFloatValue(z),
    };
}

fn inferLegacyDefinition(source: []const u8) ?ScriptDefinition {
    if (std.mem.indexOf(u8, source, "RotatorData") != null or std.mem.indexOf(u8, source, "RotateScript") != null) {
        return .{
            .kind = .rotate,
            .rotate_axis = .{ 0.0, 1.0, 0.0 },
            .rotate_speed_radians = std.math.pi * 0.25,
        };
    }
    if (std.mem.indexOf(u8, source, "PatrolScript") != null) {
        return .{
            .kind = .patrol,
        };
    }
    if (std.mem.indexOf(u8, source, "CameraData") != null) {
        return .{
            .kind = .fly_camera,
        };
    }
    if (std.mem.indexOf(u8, source, "FpsControllerScript") != null) {
        return .{
            .kind = .fps_controller,
        };
    }
    return null;
}

fn vtableForKind(kind: BuiltinKind) types.ScriptVTable {
    return switch (kind) {
        .rotate => .{
            .onInit = rotateOnInit,
            .onUpdate = rotateOnUpdate,
            .onDestroy = rotateOnDestroy,
        },
        .patrol => .{
            .onInit = patrolOnInit,
            .onUpdate = patrolOnUpdate,
            .onDestroy = patrolOnDestroy,
        },
        .fly_camera => .{
            .onInit = flyCameraOnInit,
            .onUpdate = flyCameraOnUpdate,
            .onDestroy = flyCameraOnDestroy,
        },
        .fps_controller => .{
            .onInit = fpsControllerOnInit,
            .onUpdate = fpsControllerOnUpdate,
            .onDestroy = fpsControllerOnDestroy,
        },
        .none => .{},
    };
}

fn rotateOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Rotate script initialized");
}

fn rotateOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(RotateState, ctx.instance) orelse return;
    const current = ctx.getRotation() orelse quat.identity();
    const delta = quat.fromAxisAngle(state.axis, state.speed_radians * dt);
    const next = if (state.local_space)
        quat.normalize(quat.mul(current, delta))
    else
        quat.normalize(quat.mul(delta, current));
    ctx.setRotation(next);
}

fn rotateOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Rotate script destroyed");
}

fn patrolOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Patrol script initialized");
}

fn patrolOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(PatrolState, ctx.instance) orelse return;
    if (state.waypoint_count == 0) {
        return;
    }

    if (state.wait_at_waypoint and state.wait_timer > 0.0) {
        state.wait_timer = @max(0.0, state.wait_timer - dt);
        return;
    }

    const current_position = ctx.getPosition() orelse return;
    var target = state.waypoints[state.current_waypoint];
    var to_target = vec3.sub(target, current_position);
    var distance = vec3.length(to_target);

    while (distance <= state.arrival_threshold) {
        if (state.wait_at_waypoint) {
            state.wait_timer = state.wait_time;
            return;
        }

        const previous_waypoint = state.current_waypoint;
        if (state.current_waypoint + 1 < state.waypoint_count) {
            state.current_waypoint += 1;
        } else if (state.loop) {
            state.current_waypoint = 0;
        } else {
            return;
        }

        if (state.current_waypoint == previous_waypoint) {
            return;
        }

        target = state.waypoints[state.current_waypoint];
        to_target = vec3.sub(target, current_position);
        distance = vec3.length(to_target);
    }

    const step = @min(state.speed * dt, distance);
    const direction = vec3.normalize(to_target);
    ctx.setPosition(vec3.add(current_position, vec3.scale(direction, step)));
}

fn patrolOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Patrol script destroyed");
}

fn flyCameraOnInit(ctx: *context.ScriptContext) void {
    ctx.log("Fly camera script initialized");
}

fn flyCameraOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(FlyCameraState, ctx.instance) orelse return;

    if (ctx.getMousePosition()) |mouse_pos| {
        updateLookAngles(&state.first_mouse, &state.last_mouse_x, &state.last_mouse_y, &state.pitch, &state.yaw, state.mouse_sensitivity, mouse_pos);
    }

    const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
    const right = vec3.rightFromYaw(state.yaw);

    var movement: components.Vec3 = .{ 0.0, 0.0, 0.0 };
    if (ctx.isKeyDown(input_mod.Key.w)) movement = vec3.add(movement, forward);
    if (ctx.isKeyDown(input_mod.Key.s)) movement = vec3.sub(movement, forward);
    if (ctx.isKeyDown(input_mod.Key.d)) movement = vec3.add(movement, right);
    if (ctx.isKeyDown(input_mod.Key.a)) movement = vec3.sub(movement, right);
    if (ctx.isKeyDown(input_mod.Key.e)) movement[1] += 1.0;
    if (ctx.isKeyDown(input_mod.Key.q)) movement[1] -= 1.0;

    if (vec3.length(movement) > 0.0001) {
        const current_position = ctx.getPosition() orelse .{ 0.0, 0.0, 0.0 };
        const direction = vec3.normalize(movement);
        ctx.setPosition(vec3.add(current_position, vec3.scale(direction, state.move_speed * dt)));
    }

    ctx.setRotation(quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }));
}

fn flyCameraOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("Fly camera script destroyed");
}

fn fpsControllerOnInit(ctx: *context.ScriptContext) void {
    ctx.log("FPS controller script initialized");
}

fn fpsControllerOnUpdate(ctx: *context.ScriptContext, dt: f32) void {
    const state = castInstanceState(FpsControllerState, ctx.instance) orelse return;

    if (ctx.getMousePosition()) |mouse_pos| {
        updateLookAngles(&state.first_mouse, &state.last_mouse_x, &state.last_mouse_y, &state.pitch, &state.yaw, state.mouse_sensitivity, mouse_pos);
    }

    var position = ctx.getPosition() orelse .{ 0.0, 0.0, 0.0 };
    const forward = vec3.forwardFromAngles(state.yaw, 0.0);
    const right = vec3.rightFromYaw(state.yaw);

    var planar: components.Vec3 = .{ 0.0, 0.0, 0.0 };
    if (ctx.isKeyDown(input_mod.Key.w)) planar = vec3.add(planar, forward);
    if (ctx.isKeyDown(input_mod.Key.s)) planar = vec3.sub(planar, forward);
    if (ctx.isKeyDown(input_mod.Key.d)) planar = vec3.add(planar, right);
    if (ctx.isKeyDown(input_mod.Key.a)) planar = vec3.sub(planar, right);

    if (vec3.length(planar) > 0.0001) {
        const direction = vec3.normalize(planar);
        position = vec3.add(position, vec3.scale(direction, state.move_speed * dt));
    }

    state.vertical_velocity += state.gravity * dt;
    if (ctx.wasKeyPressed(input_mod.Key.space) and state.is_grounded) {
        state.vertical_velocity = state.jump_velocity;
        state.is_grounded = false;
    }

    position[1] += state.vertical_velocity * dt;
    if (position[1] <= 0.0) {
        position[1] = 0.0;
        state.vertical_velocity = 0.0;
        state.is_grounded = true;
    } else {
        state.is_grounded = false;
    }

    ctx.setPosition(position);
    ctx.setRotation(quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }));
}

fn fpsControllerOnDestroy(ctx: *context.ScriptContext) void {
    ctx.log("FPS controller script destroyed");
}

fn initializeLookAnglesFromTransform(out_pitch: *f32, out_yaw: *f32, ctx: *context.ScriptContext) void {
    if (ctx.getRotation()) |rotation| {
        const euler = quat.toEuler(rotation);
        out_pitch.* = euler[0];
        out_yaw.* = euler[1];
    }
}

fn updateLookAngles(
    first_mouse: *bool,
    last_mouse_x: *f32,
    last_mouse_y: *f32,
    pitch: *f32,
    yaw: *f32,
    sensitivity: f32,
    mouse_pos: [2]f32,
) void {
    if (first_mouse.*) {
        last_mouse_x.* = mouse_pos[0];
        last_mouse_y.* = mouse_pos[1];
        first_mouse.* = false;
        return;
    }

    const delta_x = mouse_pos[0] - last_mouse_x.*;
    const delta_y = last_mouse_y.* - mouse_pos[1];
    last_mouse_x.* = mouse_pos[0];
    last_mouse_y.* = mouse_pos[1];

    yaw.* += delta_x * sensitivity;
    pitch.* = std.math.clamp(pitch.* + delta_y * sensitivity, -std.math.pi * 0.49, std.math.pi * 0.49);
}

fn castUserData(comptime T: type, data: *anyopaque) *T {
    return @ptrCast(@alignCast(data));
}

fn castInstanceState(comptime T: type, instance: *types.ScriptInstance) ?*T {
    const data = instance.user_data orelse return null;
    if (builtinKindFromTag(instance.user_data_tag) != builtinKindForState(T)) {
        return null;
    }
    return castUserData(T, data);
}

fn builtinKindFromTag(tag: u32) BuiltinKind {
    return std.meta.intToEnum(BuiltinKind, tag) catch .none;
}

fn builtinKindForState(comptime T: type) BuiltinKind {
    return switch (T) {
        RotateState => .rotate,
        PatrolState => .patrol,
        FlyCameraState => .fly_camera,
        FpsControllerState => .fps_controller,
        else => .none,
    };
}

fn castContext(comptime T: type, context_ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(context_ptr));
}

fn zigLoadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
    return ZigVM.load(castContext(ZigVM, context_ptr), resource);
}

fn zigUnloadBridge(context_ptr: *anyopaque) void {
    ZigVM.unload(castContext(ZigVM, context_ptr));
}

fn zigCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return ZigVM.createInstance(castContext(ZigVM, context_ptr), ctx);
}

fn zigDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    ZigVM.destroyInstance(castContext(ZigVM, context_ptr), instance);
}

fn zigCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return ZigVM.callInit(castContext(ZigVM, context_ptr), instance, ctx);
}

fn zigCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return ZigVM.callUpdate(castContext(ZigVM, context_ptr), instance, ctx, dt);
}

fn zigCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return ZigVM.callDestroy(castContext(ZigVM, context_ptr), instance, ctx);
}

fn zigGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return ZigVM.getError(castContext(ZigVM, context_ptr));
}

fn csharpLoadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
    return CSharpVM.load(castContext(CSharpVM, context_ptr), resource);
}

fn csharpUnloadBridge(context_ptr: *anyopaque) void {
    CSharpVM.unloadStub(castContext(CSharpVM, context_ptr));
}

fn csharpCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return CSharpVM.createInstanceStub(castContext(CSharpVM, context_ptr), ctx);
}

fn csharpDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    CSharpVM.destroyInstanceStub(castContext(CSharpVM, context_ptr), instance);
}

fn csharpCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return CSharpVM.callInitStub(castContext(CSharpVM, context_ptr), instance, ctx);
}

fn csharpCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return CSharpVM.callUpdateStub(castContext(CSharpVM, context_ptr), instance, ctx, dt);
}

fn csharpCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return CSharpVM.callDestroyStub(castContext(CSharpVM, context_ptr), instance, ctx);
}

fn csharpGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return CSharpVM.getError(castContext(CSharpVM, context_ptr));
}

test "zig vm rotate builtin updates entity rotation" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "RotateMe" });
    const entity = world.getEntity(entity_id).?;
    entity.local_transform.rotation = quat.identity();

    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "//!guava builtin=rotate axis=y speed_deg=90 local=true\n",
        .language = .zig,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callUpdate(instance, &ctx, 1.0);
    try vm.callUpdate(instance, &ctx, 1.0);

    const rotated = world.getEntity(entity_id).?.local_transform.rotation;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated[3], 0.0001);
}

test "zig vm patrol builtin moves toward next waypoint" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{
        .name = "Patrol",
        .local_transform = .{ .translation = .{ 0.0, 0.0, 0.0 } },
    });

    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "//!guava builtin=patrol speed=2.0 waypoints=0,0,0;2,0,0\n",
        .language = .zig,
    };
    try vm.load(&resource);

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = undefined,
        .allocator = std.testing.allocator,
    };
    const instance = try vm.createInstance(&ctx);
    defer vm.destroyInstance(instance);
    ctx.instance = instance;

    try vm.callUpdate(instance, &ctx, 1.0);

    const moved = world.getEntity(entity_id).?.local_transform.translation;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), moved[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), moved[2], 0.0001);
}

test "zig vm rejects source without builtin directive" {
    var vm = ZigVM.init(std.testing.allocator);
    defer vm.unload();

    const resource = script_resource_mod.ScriptResource{
        .source = "pub fn onUpdate() void {}",
        .language = .zig,
    };
    try std.testing.expectError(types.ScriptError.CompileError, vm.load(&resource));
    try std.testing.expect(vm.getError().len != 0);
}
