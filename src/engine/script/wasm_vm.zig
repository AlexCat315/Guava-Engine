const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const components = @import("../scene/components.zig");
const ui = @import("../ui/imgui.zig");
const context = @import("./context.zig");
const parameter_reflection = @import("./parameter_reflection.zig");
const types = @import("./types.zig");
const vm_interface = @import("./vm_interface.zig");

const c = @cImport({
    @cInclude("wasm_export.h");
});

extern fn guava_wamr_native_symbols() [*]c.NativeSymbol;
extern fn guava_wamr_native_symbol_count() c_uint;

const log = std.log.scoped(.wasm_vm);

const runtime_state = struct {
    var mutex: std.Thread.Mutex = .{};
    var ref_count: usize = 0;
    var initialized: bool = false;
};

pub const WasmVM = struct {
    allocator: std.mem.Allocator,
    loaded_source: []u8 = &.{},
    loaded_bytecode: []u8 = &.{},
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) !WasmVM {
        try acquireRuntime();
        return .{
            .allocator = allocator,
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

        var error_buffer = std.mem.zeroes([512]u8);

        state.module = c.wasm_runtime_load(
            state.bytecode.ptr,
            @as(u32, @intCast(state.bytecode.len)),
            @ptrCast(&error_buffer),
            error_buffer.len,
        );
        if (state.module == null) {
            vm.captureRuntimeError(state, std.mem.sliceTo(&error_buffer, 0));
            return types.ScriptError.LoadError;
        }

        state.module_inst = c.wasm_runtime_instantiate(
            state.module,
            64 * 1024,
            64 * 1024,
            @ptrCast(&error_buffer),
            error_buffer.len,
        );
        if (state.module_inst == null) {
            vm.captureRuntimeError(state, std.mem.sliceTo(&error_buffer, 0));
            return types.ScriptError.LoadError;
        }

        c.wasm_runtime_set_custom_data(state.module_inst, state);

        state.exec_env = c.wasm_runtime_create_exec_env(state.module_inst, 64 * 1024);
        if (state.exec_env == null) {
            vm.captureRuntimeError(state, "failed to create WAMR exec env");
            return types.ScriptError.OutOfMemory;
        }

        state.on_init = findRequiredFunction(vm, state, "guava_on_init") catch return types.ScriptError.LoadError;
        state.on_update = findRequiredFunction(vm, state, "guava_on_update") catch return types.ScriptError.LoadError;
        state.on_destroy = findRequiredFunction(vm, state, "guava_on_destroy") catch return types.ScriptError.LoadError;
        initializeParameterReflectionFunctions(state);

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

        c.wasm_runtime_clear_exception(state.module_inst);

        const ok = if (dt) |delta| blk: {
            var argv = [_]u32{@bitCast(delta)};
            break :blk c.wasm_runtime_call_wasm(state.exec_env, function, argv.len, &argv);
        } else c.wasm_runtime_call_wasm(state.exec_env, function, 0, null);

        if (!ok) {
            vm.captureRuntimeError(state, "wasm runtime trap");
            return err_tag;
        }
    }

    fn captureRuntimeError(vm: *WasmVM, state: *WasmInstanceState, fallback: []const u8) void {
        if (state.last_panic_message.len != 0) {
            if (state.last_panic_file.len > 0) {
                const formatted = std.fmt.allocPrint(
                    vm.allocator,
                    "{s} at {s}:{d}:{d} (in {s})",
                    .{
                        state.last_panic_message,
                        state.last_panic_file,
                        state.last_panic_line,
                        state.last_panic_column,
                        state.last_panic_function,
                    },
                ) catch {
                    setOwnedMessage(vm.allocator, &vm.error_msg, state.last_panic_message);
                    return;
                };
                setOwnedMessage(vm.allocator, &vm.error_msg, formatted);
                vm.allocator.free(formatted);
            } else {
                setOwnedMessage(vm.allocator, &vm.error_msg, state.last_panic_message);
            }
            return;
        }

        if (state.module_inst != null) {
            const exception = c.wasm_runtime_get_exception(state.module_inst);
            if (exception != null) {
                const message = std.mem.span(exception);
                if (message.len != 0) {
                    setOwnedMessage(vm.allocator, &vm.error_msg, message);
                    return;
                }
            }
        }

        setOwnedMessage(vm.allocator, &vm.error_msg, fallback);
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm: *WasmVM = @ptrCast(@alignCast(context_ptr));
        clearOwnedBytes(vm.allocator, &vm.loaded_source);
        clearOwnedBytes(vm.allocator, &vm.loaded_bytecode);
        clearOwnedMessage(vm.allocator, &vm.error_msg);
        releaseRuntime();
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
    module: c.wasm_module_t = null,
    module_inst: c.wasm_module_inst_t = null,
    exec_env: c.wasm_exec_env_t = null,
    on_init: c.wasm_function_inst_t = null,
    on_update: c.wasm_function_inst_t = null,
    on_destroy: c.wasm_function_inst_t = null,
    param_count_fn: c.wasm_function_inst_t = null,
    param_name_ptr_fn: c.wasm_function_inst_t = null,
    param_name_len_fn: c.wasm_function_inst_t = null,
    param_kind_fn: c.wasm_function_inst_t = null,
    param_get_f32_fn: c.wasm_function_inst_t = null,
    param_set_f32_fn: c.wasm_function_inst_t = null,
    param_get_bool_fn: c.wasm_function_inst_t = null,
    param_set_bool_fn: c.wasm_function_inst_t = null,
    param_get_i32_fn: c.wasm_function_inst_t = null,
    param_set_i32_fn: c.wasm_function_inst_t = null,
    active_context: ?*context.ScriptContext = null,
    source: []u8 = &.{},
    bytecode: []u8 = &.{},
    last_panic_message: []u8 = &.{},
    last_panic_file: []u8 = &.{},
    last_panic_function: []u8 = &.{},
    last_panic_line: u32 = 0,
    last_panic_column: u32 = 0,

    fn init(self: *WasmInstanceState, allocator: std.mem.Allocator, source: []const u8, bytecode: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .source = try allocator.dupe(u8, source),
            .bytecode = try allocator.dupe(u8, bytecode),
        };
    }

    fn deinit(self: *WasmInstanceState) void {
        if (self.exec_env != null) {
            c.wasm_runtime_destroy_exec_env(self.exec_env);
            self.exec_env = null;
        }
        if (self.module_inst != null) {
            c.wasm_runtime_deinstantiate(self.module_inst);
            self.module_inst = null;
        }
        if (self.module != null) {
            c.wasm_runtime_unload(self.module);
            self.module = null;
        }
        clearOwnedBytes(self.allocator, &self.source);
        clearOwnedBytes(self.allocator, &self.bytecode);
        clearOwnedMessage(self.allocator, &self.last_panic_message);
        clearOwnedMessage(self.allocator, &self.last_panic_file);
        clearOwnedMessage(self.allocator, &self.last_panic_function);
        self.* = undefined;
    }
};

pub fn reflectParameterSchemaJsonAlloc(allocator: std.mem.Allocator, bytecode: []const u8) ![]u8 {
    var state: WasmInstanceState = undefined;
    try state.init(allocator, "", bytecode);
    defer state.deinit();

    try instantiateReflectionState(&state);
    defer releaseRuntime();

    const definitions = try readReflectedParametersAlloc(allocator, &state);
    defer parameter_reflection.deinitDefinitions(allocator, definitions);
    return try parameter_reflection.buildMetadataJsonAlloc(allocator, definitions);
}

pub fn applyParameterPayload(
    allocator: std.mem.Allocator,
    instance: *types.ScriptInstance,
    schema_json: []const u8,
    payload_json: []const u8,
) !bool {
    const state = getInstanceState(instance) orelse return false;
    if (state.param_count_fn == null) {
        return false;
    }

    const definitions = try parameter_reflection.parseMetadataAlloc(allocator, schema_json);
    defer parameter_reflection.deinitDefinitions(allocator, definitions);
    if (definitions.len == 0) {
        return false;
    }

    const values = try parameter_reflection.parseValuesAlloc(allocator, definitions, payload_json);
    defer allocator.free(values);

    for (definitions, values, 0..) |definition, value, index| {
        const parameter_index: u32 = @intCast(index);
        switch (definition.kind) {
            .float => {
                if (state.param_set_f32_fn == null) continue;
                if (!try callSetterF32(state, state.param_set_f32_fn.?, parameter_index, value.float)) {
                    return false;
                }
            },
            .boolean => {
                if (state.param_set_bool_fn == null) continue;
                if (!try callSetterBool(state, state.param_set_bool_fn.?, parameter_index, value.boolean)) {
                    return false;
                }
            },
            .integer => {
                if (state.param_set_i32_fn == null) continue;
                if (!try callSetterI32(state, state.param_set_i32_fn.?, parameter_index, value.integer)) {
                    return false;
                }
            },
        }
    }

    return true;
}

fn acquireRuntime() !void {
    runtime_state.mutex.lock();
    defer runtime_state.mutex.unlock();

    if (!runtime_state.initialized) {
        var init_args = std.mem.zeroes(c.RuntimeInitArgs);
        init_args.mem_alloc_type = c.Alloc_With_System_Allocator;
        init_args.native_module_name = "env";
        init_args.native_symbols = guava_wamr_native_symbols();
        init_args.n_native_symbols = @as(u32, @intCast(guava_wamr_native_symbol_count()));
        init_args.running_mode = c.Mode_Interp;

        if (!c.wasm_runtime_full_init(&init_args)) {
            return types.ScriptError.LoadError;
        }
        runtime_state.initialized = true;
    }

    runtime_state.ref_count += 1;
}

fn releaseRuntime() void {
    runtime_state.mutex.lock();
    defer runtime_state.mutex.unlock();

    if (runtime_state.ref_count == 0) {
        return;
    }

    runtime_state.ref_count -= 1;
    if (runtime_state.ref_count == 0 and runtime_state.initialized) {
        c.wasm_runtime_destroy();
        runtime_state.initialized = false;
    }
}

fn findRequiredFunction(vm: *WasmVM, state: *WasmInstanceState, name: [:0]const u8) !c.wasm_function_inst_t {
    const function = c.wasm_runtime_lookup_function(state.module_inst, name.ptr);
    if (function == null) {
        const message = std.fmt.allocPrint(vm.allocator, "missing required wasm export: {s}", .{name}) catch return types.ScriptError.OutOfMemory;
        defer vm.allocator.free(message);
        vm.captureRuntimeError(state, message);
        return types.ScriptError.LoadError;
    }
    return function;
}

fn findOptionalFunction(state: *WasmInstanceState, name: [:0]const u8) c.wasm_function_inst_t {
    return c.wasm_runtime_lookup_function(state.module_inst, name.ptr);
}

fn initializeParameterReflectionFunctions(state: *WasmInstanceState) void {
    state.param_count_fn = findOptionalFunction(state, "guava_param_count");
    state.param_name_ptr_fn = findOptionalFunction(state, "guava_param_name_ptr");
    state.param_name_len_fn = findOptionalFunction(state, "guava_param_name_len");
    state.param_kind_fn = findOptionalFunction(state, "guava_param_kind");
    state.param_get_f32_fn = findOptionalFunction(state, "guava_param_get_f32");
    state.param_set_f32_fn = findOptionalFunction(state, "guava_param_set_f32");
    state.param_get_bool_fn = findOptionalFunction(state, "guava_param_get_bool");
    state.param_set_bool_fn = findOptionalFunction(state, "guava_param_set_bool");
    state.param_get_i32_fn = findOptionalFunction(state, "guava_param_get_i32");
    state.param_set_i32_fn = findOptionalFunction(state, "guava_param_set_i32");
}

fn instantiateReflectionState(state: *WasmInstanceState) !void {
    try acquireRuntime();
    errdefer releaseRuntime();

    var error_buffer = std.mem.zeroes([512]u8);
    state.module = c.wasm_runtime_load(
        state.bytecode.ptr,
        @as(u32, @intCast(state.bytecode.len)),
        @ptrCast(&error_buffer),
        error_buffer.len,
    );
    if (state.module == null) {
        return error.LoadError;
    }

    state.module_inst = c.wasm_runtime_instantiate(
        state.module,
        64 * 1024,
        64 * 1024,
        @ptrCast(&error_buffer),
        error_buffer.len,
    );
    if (state.module_inst == null) {
        return error.LoadError;
    }

    state.exec_env = c.wasm_runtime_create_exec_env(state.module_inst, 64 * 1024);
    if (state.exec_env == null) {
        return error.OutOfMemory;
    }

    initializeParameterReflectionFunctions(state);
}

fn readReflectedParametersAlloc(
    allocator: std.mem.Allocator,
    state: *WasmInstanceState,
) ![]parameter_reflection.ParameterDefinition {
    if (state.param_count_fn == null or
        state.param_name_ptr_fn == null or
        state.param_name_len_fn == null or
        state.param_kind_fn == null)
    {
        return allocator.alloc(parameter_reflection.ParameterDefinition, 0);
    }

    const count = try callGetterU32(state, state.param_count_fn.?, null);
    const definitions = try allocator.alloc(parameter_reflection.ParameterDefinition, count);
    errdefer {
        for (definitions[0..count]) |definition| {
            allocator.free(definition.name);
        }
        allocator.free(definitions);
    }

    for (definitions, 0..) |*definition, index| {
        const parameter_index: u32 = @intCast(index);
        const app_name_ptr = try callGetterU32(state, state.param_name_ptr_fn.?, parameter_index);
        const app_name_len = try callGetterU32(state, state.param_name_len_fn.?, parameter_index);
        const kind_raw = try callGetterU32(state, state.param_kind_fn.?, parameter_index);
        const kind = std.meta.intToEnum(parameter_reflection.ParameterKind, @as(u8, @intCast(kind_raw))) catch return error.InvalidData;
        const bounds = parameter_reflection.defaultBounds(kind);

        definition.* = .{
            .name = try readGuestStringAlloc(allocator, state, app_name_ptr, app_name_len),
            .kind = kind,
            .default_value = switch (kind) {
                .float => .{ .float = if (state.param_get_f32_fn) |function|
                    try callGetterF32(state, function, parameter_index)
                else
                    0.0 },
                .boolean => .{ .boolean = if (state.param_get_bool_fn) |function|
                    try callGetterU32(state, function, parameter_index) != 0
                else
                    false },
                .integer => .{ .integer = if (state.param_get_i32_fn) |function|
                    try callGetterI32(state, function, parameter_index)
                else
                    0 },
            },
            .min = bounds.min,
            .max = bounds.max,
            .step = bounds.step,
        };
    }

    return definitions;
}

fn readGuestStringAlloc(
    allocator: std.mem.Allocator,
    state: *WasmInstanceState,
    app_offset: u32,
    len: u32,
) ![]u8 {
    if (len == 0) {
        return allocator.alloc(u8, 0);
    }
    if (!c.wasm_runtime_validate_app_addr(state.module_inst, app_offset, len)) {
        return error.InvalidData;
    }
    const native_ptr = c.wasm_runtime_addr_app_to_native(state.module_inst, app_offset) orelse return error.InvalidData;
    const bytes: [*]const u8 = @ptrCast(native_ptr);
    return try allocator.dupe(u8, bytes[0..len]);
}

fn callGetterU32(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: ?u32) !u32 {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index orelse 0 };
    const argc: u32 = if (index != null) 2 else 1;
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, argc, &argv)) {
        return error.RuntimeError;
    }
    return argv[0];
}

fn callGetterF32(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: u32) !f32 {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, 2, &argv)) {
        return error.RuntimeError;
    }
    return @bitCast(argv[0]);
}

fn callGetterI32(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: u32) !i32 {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, 2, &argv)) {
        return error.RuntimeError;
    }
    return @bitCast(argv[0]);
}

fn callSetterF32(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: u32, value: f32) !bool {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index, @bitCast(value) };
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, 3, &argv)) {
        return error.RuntimeError;
    }
    return argv[0] != 0;
}

fn callSetterBool(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: u32, value: bool) !bool {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index, if (value) 1 else 0 };
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, 3, &argv)) {
        return error.RuntimeError;
    }
    return argv[0] != 0;
}

fn callSetterI32(state: *WasmInstanceState, function: c.wasm_function_inst_t, index: u32, value: i32) !bool {
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index, @bitCast(value) };
    if (!c.wasm_runtime_call_wasm(state.exec_env, function, 3, &argv)) {
        return error.RuntimeError;
    }
    return argv[0] != 0;
}

fn getInstanceState(instance: *types.ScriptInstance) ?*WasmInstanceState {
    const userdata = instance.user_data orelse return null;
    return @ptrCast(@alignCast(userdata));
}

fn activeContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const state: *WasmInstanceState = @ptrCast(@alignCast(userdata orelse return null));
    return state.active_context;
}

fn setLastItemChanged(userdata: ?*anyopaque, changed: bool) void {
    const ctx = activeContext(userdata) orelse return;
    if (ctx.editor_ui_state) |ui_state| {
        ui_state.last_item_changed = changed;
    }
}

fn selectionEntity(ctx: *const context.ScriptContext, index: usize) ?types.EntityId {
    if (index >= ctx.editor_selection.len) {
        return null;
    }
    return ctx.editor_selection[index];
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

pub export fn guava_wasm_host_report_panic_with_location(
    userdata: ?*anyopaque,
    msg_ptr: [*]const u8,
    msg_len: u32,
    file_ptr: [*]const u8,
    file_len: u32,
    func_ptr: [*]const u8,
    func_len: u32,
    line: u32,
    column: u32,
) void {
    const state: *WasmInstanceState = @ptrCast(@alignCast(userdata orelse return));
    replaceOwnedBytes(state.allocator, &state.last_panic_message, msg_ptr[0..msg_len]) catch {};
    replaceOwnedBytes(state.allocator, &state.last_panic_file, file_ptr[0..file_len]) catch {};
    replaceOwnedBytes(state.allocator, &state.last_panic_function, func_ptr[0..func_len]) catch {};
    state.last_panic_line = line;
    state.last_panic_column = column;
}

pub export fn guava_wasm_host_get_selection_count(userdata: ?*anyopaque) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    return @intCast(ctx.editor_selection.len);
}

pub export fn guava_wasm_host_get_selection_entity(userdata: ?*anyopaque, index: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id = selectionEntity(ctx, index) orelse return 0;
    return @intCast(entity_id);
}

pub export fn guava_wasm_host_select_entity(userdata: ?*anyopaque, entity_id_raw: u32, additive_raw: u32) void {
    const ctx = activeContext(userdata) orelse return;
    if (ctx.editor_selection_api) |api| {
        api.select_entity(api.context, @intCast(entity_id_raw), additive_raw != 0);
    }
}

pub export fn guava_wasm_host_clear_selection(userdata: ?*anyopaque) void {
    const ctx = activeContext(userdata) orelse return;
    if (ctx.editor_selection_api) |api| {
        api.clear_selection(api.context);
    }
}

pub export fn guava_wasm_host_ui_last_item_changed(userdata: ?*anyopaque) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    if (ctx.editor_ui_state) |ui_state| {
        return if (ui_state.last_item_changed) 1 else 0;
    }
    return 0;
}

pub export fn guava_wasm_host_ui_text(_: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    ui.text(ptr[0..len]);
}

pub export fn guava_wasm_host_ui_text_wrapped(_: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    ui.textWrapped(ptr[0..len]);
}

pub export fn guava_wasm_host_ui_separator(_: ?*anyopaque) void {
    ui.separator();
}

pub export fn guava_wasm_host_ui_same_line(_: ?*anyopaque) void {
    ui.sameLine();
}

pub export fn guava_wasm_host_ui_button(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) u32 {
    const clicked = ui.button(ptr[0..len]);
    setLastItemChanged(userdata, clicked);
    return if (clicked) 1 else 0;
}

pub export fn guava_wasm_host_ui_checkbox(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, value_raw: u32) u32 {
    var value = value_raw != 0;
    const changed = ui.checkbox(ptr[0..len], &value);
    setLastItemChanged(userdata, changed);
    return if (value) 1 else 0;
}

pub export fn guava_wasm_host_ui_drag_float_bits(
    userdata: ?*anyopaque,
    ptr: [*]const u8,
    len: u32,
    current_bits: u32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) u32 {
    var value: f32 = @bitCast(current_bits);
    const changed = ui.dragFloat(ptr[0..len], &value, speed, min_value, max_value);
    setLastItemChanged(userdata, changed);
    return @bitCast(value);
}

pub export fn guava_wasm_host_ui_set_next_item_width(_: ?*anyopaque, width: f32) void {
    ui.setNextItemWidth(width);
}

pub export fn guava_wasm_host_ui_begin_window(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) u32 {
    _ = userdata;
    const open = ui.beginWindow(ptr[0..len]);
    return if (open) 1 else 0;
}

pub export fn guava_wasm_host_ui_end_window(_: ?*anyopaque) void {
    ui.endWindow();
}

pub export fn guava_wasm_host_ui_collapsing_header(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, default_open: u32) u32 {
    const open = ui.collapsingHeader(ptr[0..len], default_open != 0);
    setLastItemChanged(userdata, open);
    return if (open) 1 else 0;
}

pub export fn guava_wasm_host_ui_input_text(
    userdata: ?*anyopaque,
    label_ptr: [*]const u8,
    label_len: u32,
    buffer_ptr: [*]u8,
    buffer_len: u32,
) u32 {
    _ = userdata;
    const changed = ui.inputText(label_ptr[0..label_len], buffer_ptr[0..buffer_len]);
    return if (changed) 1 else 0;
}

pub export fn guava_wasm_host_ui_drag_float3_bits(
    userdata: ?*anyopaque,
    ptr: [*]const u8,
    len: u32,
    x_bits: u32,
    y_bits: u32,
    z_bits: u32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) u32 {
    var value: [3]f32 = .{
        @bitCast(x_bits),
        @bitCast(y_bits),
        @bitCast(z_bits),
    };
    const changed = ui.dragFloat3(ptr[0..len], &value, speed, min_value, max_value);
    setLastItemChanged(userdata, changed);
    return (@as(u32, @bitCast(value[0])) & 0xFFF) |
        ((@as(u32, @bitCast(value[1])) & 0xFFF) << 10) |
        ((@as(u32, @bitCast(value[2])) & 0xFFF) << 20);
}

pub export fn guava_wasm_host_ui_indent(_: ?*anyopaque, width: f32) void {
    ui.indent(width);
}

pub export fn guava_wasm_host_ui_unindent(_: ?*anyopaque, width: f32) void {
    ui.unindent(width);
}

pub export fn guava_wasm_host_ui_begin_child(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, width: f32, height: f32, border: u32) u32 {
    _ = userdata;
    const open = ui.beginChild(ptr[0..len], width, height, border != 0);
    return if (open) 1 else 0;
}

pub export fn guava_wasm_host_ui_end_child(_: ?*anyopaque) void {
    ui.endChild();
}

pub export fn guava_wasm_host_ui_is_item_clicked(_: ?*anyopaque) u32 {
    return if (ui.isItemClicked()) 1 else 0;
}

pub export fn guava_wasm_host_ui_is_item_hovered(_: ?*anyopaque) u32 {
    return if (ui.isItemHovered()) 1 else 0;
}

pub export fn guava_wasm_host_ui_set_tooltip(_: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    ui.setTooltip(ptr[0..len]);
}

pub export fn guava_wasm_host_audio_play(userdata: ?*anyopaque, entity_id_raw: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: @import("../scene/scene.zig").EntityId = @as(u64, entity_id_raw);
    const entity = ctx.world.getEntity(entity_id) orelse return 0;
    const audio_src = &(entity.audio_source orelse return 0);
    const audio_runtime = @import("../audio/mod.zig").get() catch return 0;
    const clip_handle = @intFromEnum(audio_src.clip_handle orelse return 0);
    if (audio_src.spatial) {
        const pos = entity.local_transform.translation;
        audio_src._voice_handle = audio_runtime.playClip3d(clip_handle, pos, audio_src.volume, audio_src.looping) catch return 0;
    } else {
        audio_src._voice_handle = audio_runtime.playClip2d(clip_handle, audio_src.volume, audio_src.looping) catch return 0;
    }
    audio_src._is_playing = true;
    return 1;
}

pub export fn guava_wasm_host_audio_stop(userdata: ?*anyopaque, entity_id_raw: u32) void {
    const ctx = activeContext(userdata) orelse return;
    const entity_id: @import("../scene/scene.zig").EntityId = @as(u64, entity_id_raw);
    const entity = ctx.world.getEntity(entity_id) orelse return;
    const audio_src = &(entity.audio_source orelse return);
    const audio_runtime = @import("../audio/mod.zig").get() catch return;
    if (audio_src._voice_handle) |vh| {
        audio_runtime.stopVoice(vh);
    }
    audio_src._voice_handle = null;
    audio_src._is_playing = false;
}

pub export fn guava_wasm_host_audio_set_volume(userdata: ?*anyopaque, entity_id_raw: u32, volume: f32) void {
    const ctx = activeContext(userdata) orelse return;
    const entity_id: @import("../scene/scene.zig").EntityId = @as(u64, entity_id_raw);
    const entity = ctx.world.getEntity(entity_id) orelse return;
    const audio_src = &(entity.audio_source orelse return);
    audio_src.volume = @max(0.0, @min(1.0, volume));
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
