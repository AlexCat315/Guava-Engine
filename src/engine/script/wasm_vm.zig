const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const components = @import("../scene/components.zig");
const context = @import("./context.zig");
const types = @import("./types.zig");
const vm_interface = @import("./vm_interface.zig");

const c = @cImport({
    @cInclude("wasm3.h");
});

extern fn guava_wasm_link_host_functions(module: c.IM3Module, userdata: ?*anyopaque) ?[*:0]const u8;
extern fn guava_wasm_call_0(function: c.IM3Function) ?[*:0]const u8;
extern fn guava_wasm_call_f32(function: c.IM3Function, value: f32) ?[*:0]const u8;

const log = std.log.scoped(.wasm_vm);

pub const WasmVM = struct {
    allocator: std.mem.Allocator,
    environment: c.IM3Environment = null,
    loaded_source: []u8 = &.{},
    loaded_bytecode: []u8 = &.{},
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) !WasmVM {
        const environment = c.m3_NewEnvironment() orelse return types.ScriptError.OutOfMemory;
        return .{
            .allocator = allocator,
            .environment = environment,
        };
    }

    pub fn load(vm: *WasmVM, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        if (resource.language != .wasm) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "script language does not match WasmVM");
            return types.ScriptError.InvalidLanguage;
        }
        if (resource.bytecode.len == 0) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "wasm script resource is missing compiled bytecode");
            return types.ScriptError.LoadError;
        }

        replaceOwnedBytes(vm.allocator, &vm.loaded_source, resource.source) catch {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to copy wasm source");
            return types.ScriptError.OutOfMemory;
        };
        errdefer clearOwnedBytes(vm.allocator, &vm.loaded_source);

        replaceOwnedBytes(vm.allocator, &vm.loaded_bytecode, resource.bytecode) catch {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to copy wasm bytecode");
            return types.ScriptError.OutOfMemory;
        };

        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }

    pub fn unload(vm: *WasmVM) void {
        clearOwnedBytes(vm.allocator, &vm.loaded_source);
        clearOwnedBytes(vm.allocator, &vm.loaded_bytecode);
        clearOwnedMessage(vm.allocator, &vm.error_msg);
    }

    pub fn createInstance(vm: *WasmVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        if (vm.loaded_bytecode.len == 0) {
            setOwnedMessage(vm.allocator, &vm.error_msg, "no wasm module is loaded");
            return types.ScriptError.NotFound;
        }

        const instance = try vm.allocator.create(types.ScriptInstance);
        errdefer vm.allocator.destroy(instance);

        const state = try vm.allocator.create(WasmInstanceState);
        errdefer vm.allocator.destroy(state);
        try state.init(vm.allocator, vm.loaded_source, vm.loaded_bytecode);
        errdefer state.deinit();

        state.runtime = c.m3_NewRuntime(vm.environment, 64 * 1024, state) orelse {
            setOwnedMessage(vm.allocator, &vm.error_msg, "failed to create Wasm3 runtime");
            return types.ScriptError.OutOfMemory;
        };

        var module: c.IM3Module = null;
        const parse_result = c.m3_ParseModule(
            vm.environment,
            &module,
            state.bytecode.ptr,
            @as(u32, @intCast(state.bytecode.len)),
        );
        if (parse_result != null) {
            vm.captureRuntimeError(state, parse_result.?);
            return types.ScriptError.LoadError;
        }
        state.module = module;

        const link_result = guava_wasm_link_host_functions(state.module, state);
        if (link_result != null) {
            vm.captureRuntimeError(state, link_result.?);
            return types.ScriptError.LoadError;
        }

        const load_result = c.m3_LoadModule(state.runtime, state.module);
        if (load_result != null) {
            vm.captureRuntimeError(state, load_result.?);
            return types.ScriptError.LoadError;
        }
        state.module_loaded = true;

        const compile_result = c.m3_CompileModule(state.module);
        if (compile_result != null) {
            vm.captureRuntimeError(state, compile_result.?);
            return types.ScriptError.LoadError;
        }

        const start_result = c.m3_RunStart(state.module);
        if (start_result != null) {
            vm.captureRuntimeError(state, start_result.?);
            return types.ScriptError.LoadError;
        }

        state.on_init = findRequiredFunction(vm, state, "guava_on_init") catch return types.ScriptError.LoadError;
        state.on_update = findRequiredFunction(vm, state, "guava_on_update") catch return types.ScriptError.LoadError;
        state.on_destroy = findRequiredFunction(vm, state, "guava_on_destroy") catch return types.ScriptError.LoadError;

        instance.* = .{
            .id = 0,
            .entity_id = ctx.entity,
            .script_handle = undefined,
            .language = .wasm,
            .vtable = .{},
            .state = .ready,
            .user_data = state,
            .user_data_size = @sizeOf(WasmInstanceState),
        };
        return instance;
    }

    pub fn destroyInstance(vm: *WasmVM, instance: *types.ScriptInstance) void {
        if (instance.user_data) |userdata| {
            const state: *WasmInstanceState = @ptrCast(@alignCast(userdata));
            state.deinit();
            vm.allocator.destroy(state);
        }
        vm.allocator.destroy(instance);
    }

    pub fn callInit(vm: *WasmVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return vm.callFunction(instance, ctx, .on_init, null, types.ScriptError.InitError);
    }

    pub fn callUpdate(vm: *WasmVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return vm.callFunction(instance, ctx, .on_update, dt, types.ScriptError.UpdateError);
    }

    pub fn callDestroy(vm: *WasmVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return vm.callFunction(instance, ctx, .on_destroy, null, types.ScriptError.LoadError);
    }

    pub fn getError(vm: *WasmVM) []const u8 {
        return vm.error_msg;
    }

    fn callFunction(
        vm: *WasmVM,
        instance: *types.ScriptInstance,
        ctx: *context.ScriptContext,
        comptime which: enum { on_init, on_update, on_destroy },
        dt: ?f32,
        err_tag: types.ScriptError,
    ) types.ScriptError!void {
        const state = getInstanceState(instance) orelse return types.ScriptError.NotFound;
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        clearOwnedMessage(state.allocator, &state.last_panic_message);

        state.active_context = ctx;
        defer state.active_context = null;

        const function = switch (which) {
            .on_init => state.on_init,
            .on_update => state.on_update,
            .on_destroy => state.on_destroy,
        };

        const result = if (dt) |delta|
            guava_wasm_call_f32(function, delta)
        else
            guava_wasm_call_0(function);
        if (result != null) {
            vm.captureRuntimeError(state, result.?);
            return err_tag;
        }
    }

    fn captureRuntimeError(vm: *WasmVM, state: *WasmInstanceState, raw_result: [*:0]const u8) void {
        if (state.last_panic_message.len != 0) {
            setOwnedMessage(vm.allocator, &vm.error_msg, state.last_panic_message);
            return;
        }

        var info: c.M3ErrorInfo = undefined;
        c.m3_GetErrorInfo(state.runtime, &info);

        if (info.function != null and info.message != null) {
            const function_name = std.mem.span(c.m3_GetFunctionName(info.function));
            const message = std.mem.span(info.message);
            const owned = std.fmt.allocPrint(vm.allocator, "{s}: {s}", .{ function_name, message }) catch return;
            clearOwnedMessage(vm.allocator, &vm.error_msg);
            vm.error_msg = owned;
            return;
        }

        setOwnedMessage(vm.allocator, &vm.error_msg, std.mem.span(raw_result));
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm: *WasmVM = @ptrCast(@alignCast(context_ptr));
        clearOwnedBytes(vm.allocator, &vm.loaded_source);
        clearOwnedBytes(vm.allocator, &vm.loaded_bytecode);
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        if (vm.environment != null) {
            c.m3_FreeEnvironment(vm.environment);
            vm.environment = null;
        }
        allocator.destroy(vm);
    }

    pub const script_vm_vtable: vm_interface.ScriptVM.VTable = .{
        .load = wasmLoadBridge,
        .unload = wasmUnloadBridge,
        .createInstance = wasmCreateInstanceBridge,
        .destroyInstance = wasmDestroyInstanceBridge,
        .callInit = wasmCallInitBridge,
        .callUpdate = wasmCallUpdateBridge,
        .callDestroy = wasmCallDestroyBridge,
        .getError = wasmGetErrorBridge,
        .destroy = destroyContext,
    };
};

const WasmInstanceState = struct {
    allocator: std.mem.Allocator,
    runtime: c.IM3Runtime = null,
    module: c.IM3Module = null,
    module_loaded: bool = false,
    on_init: c.IM3Function = null,
    on_update: c.IM3Function = null,
    on_destroy: c.IM3Function = null,
    active_context: ?*context.ScriptContext = null,
    source: []u8 = &.{},
    bytecode: []u8 = &.{},
    last_panic_message: []u8 = &.{},

    fn init(self: *WasmInstanceState, allocator: std.mem.Allocator, source: []const u8, bytecode: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .source = try allocator.dupe(u8, source),
            .bytecode = try allocator.dupe(u8, bytecode),
        };
    }

    fn deinit(self: *WasmInstanceState) void {
        if (self.runtime != null) {
            c.m3_FreeRuntime(self.runtime);
            self.runtime = null;
        }
        if (!self.module_loaded and self.module != null) {
            c.m3_FreeModule(self.module);
        }
        clearOwnedBytes(self.allocator, &self.source);
        clearOwnedBytes(self.allocator, &self.bytecode);
        clearOwnedMessage(self.allocator, &self.last_panic_message);
        self.* = undefined;
    }
};

fn findRequiredFunction(vm: *WasmVM, state: *WasmInstanceState, name: [:0]const u8) !c.IM3Function {
    var function: c.IM3Function = null;
    const result = c.m3_FindFunction(&function, state.runtime, name.ptr);
    if (result != null) {
        vm.captureRuntimeError(state, result.?);
        return types.ScriptError.LoadError;
    }
    return function;
}

fn getInstanceState(instance: *types.ScriptInstance) ?*WasmInstanceState {
    const userdata = instance.user_data orelse return null;
    return @ptrCast(@alignCast(userdata));
}

fn activeContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const state: *WasmInstanceState = @ptrCast(@alignCast(userdata orelse return null));
    return state.active_context;
}

fn resolveLocalTransform(ctx: *context.ScriptContext, entity_id: types.EntityId) ?components.Transform {
    if (ctx.command_queue) |queue| {
        if (queue.latestPendingLocalTransform(entity_id)) |pending| {
            return pending;
        }
    }
    const entity = ctx.world.getEntityConst(entity_id) orelse return null;
    return entity.local_transform;
}

fn enqueueLocalTransform(ctx: *context.ScriptContext, entity_id: types.EntityId, transform: components.Transform) bool {
    const queue = ctx.command_queue orelse return false;
    queue.enqueueSetLocalTransform(entity_id, transform) catch return false;
    return true;
}

pub export fn guava_wasm_host_get_entity_id(userdata: ?*anyopaque) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    return @as(u32, @intCast(ctx.entity));
}

pub export fn guava_wasm_host_find_entity_by_name(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const name = ptr[0..len];
    for (ctx.world.entities.items) |entity| {
        if (std.mem.eql(u8, entity.name, name)) {
            return @as(u32, @intCast(entity.id));
        }
    }
    return 0;
}

pub export fn guava_wasm_host_log(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    const ctx = activeContext(userdata) orelse return;
    std.log.info("[WasmScript:{d}] {s}", .{ ctx.entity, ptr[0..len] });
}

pub export fn guava_wasm_host_set_local_transform(
    userdata: ?*anyopaque,
    entity_id_raw: u32,
    tx: f32,
    ty: f32,
    tz: f32,
    rx: f32,
    ry: f32,
    rz: f32,
    rw: f32,
    sx: f32,
    sy: f32,
    sz: f32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    const ok = enqueueLocalTransform(ctx, entity_id, .{
        .translation = .{ tx, ty, tz },
        .rotation = .{ rx, ry, rz, rw },
        .scale = .{ sx, sy, sz },
    });
    return if (ok) 1 else 0;
}

pub export fn guava_wasm_host_set_local_translation(
    userdata: ?*anyopaque,
    entity_id_raw: u32,
    tx: f32,
    ty: f32,
    tz: f32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    var transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    transform.translation = .{ tx, ty, tz };
    return if (enqueueLocalTransform(ctx, entity_id, transform)) 1 else 0;
}

pub export fn guava_wasm_host_set_local_rotation(
    userdata: ?*anyopaque,
    entity_id_raw: u32,
    rx: f32,
    ry: f32,
    rz: f32,
    rw: f32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    var transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    transform.rotation = .{ rx, ry, rz, rw };
    return if (enqueueLocalTransform(ctx, entity_id, transform)) 1 else 0;
}

pub export fn guava_wasm_host_set_local_scale(
    userdata: ?*anyopaque,
    entity_id_raw: u32,
    sx: f32,
    sy: f32,
    sz: f32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    var transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    transform.scale = .{ sx, sy, sz };
    return if (enqueueLocalTransform(ctx, entity_id, transform)) 1 else 0;
}

pub export fn guava_wasm_host_set_visible(userdata: ?*anyopaque, entity_id_raw: u32, visible_raw: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const queue = ctx.command_queue orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    queue.enqueueSetVisible(entity_id, visible_raw != 0) catch return 0;
    return 1;
}

pub export fn guava_wasm_host_report_panic(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    const state: *WasmInstanceState = @ptrCast(@alignCast(userdata orelse return));
    replaceOwnedBytes(state.allocator, &state.last_panic_message, ptr[0..len]) catch {
        log.err("failed to capture guest panic message", .{});
    };
}

fn castContext(comptime T: type, context_ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(context_ptr));
}

fn wasmLoadBridge(context_ptr: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
    return WasmVM.load(castContext(WasmVM, context_ptr), resource);
}

fn wasmUnloadBridge(context_ptr: *anyopaque) void {
    WasmVM.unload(castContext(WasmVM, context_ptr));
}

fn wasmCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return WasmVM.createInstance(castContext(WasmVM, context_ptr), ctx);
}

fn wasmDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    WasmVM.destroyInstance(castContext(WasmVM, context_ptr), instance);
}

fn wasmCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return WasmVM.callInit(castContext(WasmVM, context_ptr), instance, ctx);
}

fn wasmCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return WasmVM.callUpdate(castContext(WasmVM, context_ptr), instance, ctx, dt);
}

fn wasmCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return WasmVM.callDestroy(castContext(WasmVM, context_ptr), instance, ctx);
}

fn wasmGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return WasmVM.getError(castContext(WasmVM, context_ptr));
}

fn clearOwnedBytes(allocator: std.mem.Allocator, slot: *[]u8) void {
    if (slot.*.len != 0) {
        allocator.free(slot.*);
        slot.* = &.{};
    }
}

fn replaceOwnedBytes(allocator: std.mem.Allocator, slot: *[]u8, next: []const u8) !void {
    clearOwnedBytes(allocator, slot);
    slot.* = try allocator.dupe(u8, next);
}

fn clearOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8) void {
    clearOwnedBytes(allocator, slot);
}

fn setOwnedMessage(allocator: std.mem.Allocator, slot: *[]u8, message: []const u8) void {
    replaceOwnedBytes(allocator, slot, message) catch {
        clearOwnedBytes(allocator, slot);
    };
}
