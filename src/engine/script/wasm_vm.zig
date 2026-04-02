const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const components = @import("../scene/components.zig");
const ui = @import("../ui/imgui.zig");
const context = @import("./context.zig");
const parameter_reflection = @import("./parameter_reflection.zig");
const types = @import("./types.zig");
const vm_interface = @import("./vm_interface.zig");
const input_mod = @import("../core/input.zig");

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

pub const HostProfile = enum {
    plugin,
    editor_utility,
};

pub const WasmVM = struct {
    allocator: std.mem.Allocator,
    host_profile: HostProfile,
    loaded_source: []u8 = &.{},
    loaded_bytecode: []u8 = &.{},
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, host_profile: HostProfile) !WasmVM {
        try acquireRuntime();
        return .{
            .allocator = allocator,
            .host_profile = host_profile,
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
        try state.init(vm.allocator, vm.host_profile, vm.loaded_source, vm.loaded_bytecode);
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
    host_profile: HostProfile,
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

    fn init(self: *WasmInstanceState, allocator: std.mem.Allocator, host_profile: HostProfile, source: []const u8, bytecode: []const u8) !void {
        self.* = .{
            .allocator = allocator,
            .host_profile = host_profile,
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
    try state.init(allocator, .plugin, "", bytecode);
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

fn activeState(userdata: ?*anyopaque) ?*WasmInstanceState {
    return @ptrCast(@alignCast(userdata orelse return null));
}

fn activeContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const state = activeState(userdata) orelse return null;
    return state.active_context;
}

fn supportsEditorUi(userdata: ?*anyopaque) bool {
    const state = activeState(userdata) orelse return false;
    return state.host_profile == .editor_utility;
}

fn setLastItemChanged(userdata: ?*anyopaque, changed: bool) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
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
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const ctx = activeContext(userdata) orelse return 0;
    return @intCast(ctx.editor_selection.len);
}

pub export fn guava_wasm_host_get_selection_entity(userdata: ?*anyopaque, index: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id = selectionEntity(ctx, index) orelse return 0;
    return @intCast(entity_id);
}

pub export fn guava_wasm_host_select_entity(userdata: ?*anyopaque, entity_id_raw: u32, additive_raw: u32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    const ctx = activeContext(userdata) orelse return;
    if (ctx.editor_selection_api) |api| {
        api.select_entity(api.context, @intCast(entity_id_raw), additive_raw != 0);
    }
}

pub export fn guava_wasm_host_clear_selection(userdata: ?*anyopaque) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    const ctx = activeContext(userdata) orelse return;
    if (ctx.editor_selection_api) |api| {
        api.clear_selection(api.context);
    }
}

pub export fn guava_wasm_host_ui_last_item_changed(userdata: ?*anyopaque) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const ctx = activeContext(userdata) orelse return 0;
    if (ctx.editor_ui_state) |ui_state| {
        return if (ui_state.last_item_changed) 1 else 0;
    }
    return 0;
}

pub export fn guava_wasm_host_ui_text(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.text(ptr[0..len]);
}

pub export fn guava_wasm_host_ui_text_wrapped(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.textWrapped(ptr[0..len]);
}

pub export fn guava_wasm_host_ui_separator(userdata: ?*anyopaque) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.separator();
}

pub export fn guava_wasm_host_ui_same_line(userdata: ?*anyopaque) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.sameLine();
}

pub export fn guava_wasm_host_ui_button(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const clicked = ui.button(ptr[0..len]);
    setLastItemChanged(userdata, clicked);
    return if (clicked) 1 else 0;
}

pub export fn guava_wasm_host_ui_checkbox(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, value_raw: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return value_raw;
    }
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
    if (!supportsEditorUi(userdata)) {
        return current_bits;
    }
    var value: f32 = @bitCast(current_bits);
    const changed = ui.dragFloat(ptr[0..len], &value, speed, min_value, max_value);
    setLastItemChanged(userdata, changed);
    return @bitCast(value);
}

pub export fn guava_wasm_host_ui_set_next_item_width(userdata: ?*anyopaque, width: f32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.setNextItemWidth(width);
}

pub export fn guava_wasm_host_ui_begin_window(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const open = ui.beginWindow(ptr[0..len]);
    return if (open) 1 else 0;
}

pub export fn guava_wasm_host_ui_end_window(userdata: ?*anyopaque) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.endWindow();
}

pub export fn guava_wasm_host_ui_collapsing_header(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, default_open: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
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
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
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
    if (!supportsEditorUi(userdata)) {
        return x_bits;
    }
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

pub export fn guava_wasm_host_ui_indent(userdata: ?*anyopaque, width: f32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.indent(width);
}

pub export fn guava_wasm_host_ui_unindent(userdata: ?*anyopaque, width: f32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.unindent(width);
}

pub export fn guava_wasm_host_ui_begin_child(userdata: ?*anyopaque, ptr: [*]const u8, len: u32, width: f32, height: f32, border: u32) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    const open = ui.beginChild(ptr[0..len], width, height, border != 0);
    return if (open) 1 else 0;
}

pub export fn guava_wasm_host_ui_end_child(userdata: ?*anyopaque) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.endChild();
}

pub export fn guava_wasm_host_ui_is_item_clicked(userdata: ?*anyopaque) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    return if (ui.isItemClicked()) 1 else 0;
}

pub export fn guava_wasm_host_ui_is_item_hovered(userdata: ?*anyopaque) u32 {
    if (!supportsEditorUi(userdata)) {
        return 0;
    }
    return if (ui.isItemHovered()) 1 else 0;
}

pub export fn guava_wasm_host_ui_set_tooltip(userdata: ?*anyopaque, ptr: [*]const u8, len: u32) void {
    if (!supportsEditorUi(userdata)) {
        return;
    }
    ui.setTooltip(ptr[0..len]);
}

pub export fn guava_wasm_host_audio_play(userdata: ?*anyopaque, entity_id_raw: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: @import("../scene/scene.zig").EntityId = @as(u64, entity_id_raw);
    const entity = ctx.world.getEntity(entity_id) orelse return 0;
    const audio_src = &(entity.audio_source orelse return 0);
    const audio_runtime = @import("../audio/mod.zig").get() catch return 0;
    const pos = ctx.world.worldTransform(entity_id) orelse entity.local_transform;
    _ = audio_runtime.playEntitySource(entity_id, pos.translation, audio_src) catch return 0;
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
    const audio_runtime = @import("../audio/mod.zig").get() catch return;
    if (audio_src._voice_handle) |voice_handle| {
        if (audio_runtime.isVoiceHandleActive(voice_handle)) {
            audio_runtime.setVoiceVolume(voice_handle, audio_src.volume);
        }
    }
}

// ── Physics WASM API ──

/// 射线检测。命中返回 1 并写入 8 个 f32 到 out_ptr：
/// [entity_id_as_f32, hit_x, hit_y, hit_z, normal_x, normal_y, normal_z, distance]
pub export fn guava_wasm_host_physics_raycast(
    userdata: ?*anyopaque,
    ox: f32,
    oy: f32,
    oz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
    max_dist: f32,
    out_ptr: [*]f32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const hit = ctx.physicsRaycast(.{ ox, oy, oz }, .{ dx, dy, dz }, max_dist) orelse return 0;
    out_ptr[0] = @floatFromInt(hit.entity_id);
    out_ptr[1] = hit.position[0];
    out_ptr[2] = hit.position[1];
    out_ptr[3] = hit.position[2];
    out_ptr[4] = hit.normal[0];
    out_ptr[5] = hit.normal[1];
    out_ptr[6] = hit.normal[2];
    out_ptr[7] = hit.distance;
    return 1;
}

/// AABB 重叠检测。返回命中数（最多 max_count）。
/// 每个命中写入 1 个 u32 entity_id 到 out_ptr。
pub export fn guava_wasm_host_physics_overlap_aabb(
    userdata: ?*anyopaque,
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,
    out_ptr: [*]u32,
    max_count: u32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const physics_mod = @import("../physics/system.zig");
    const AABB = @import("../math/aabb.zig").AABB;
    const query_bounds = AABB{ .min = .{ min_x, min_y, min_z }, .max = .{ max_x, max_y, max_z } };
    const hits = ctx.physicsOverlapAabb(query_bounds, .{}) catch return 0;
    defer ctx.allocator.free(hits);
    const count: u32 = @intCast(@min(hits.len, max_count));
    for (0..count) |i| {
        out_ptr[i] = @intCast(hits[i].entity_id);
    }
    _ = physics_mod;
    return count;
}

/// 球形重叠检测。返回命中数（最多 max_count）。
/// 内部转换为 AABB 查询。
pub export fn guava_wasm_host_physics_overlap_sphere(
    userdata: ?*anyopaque,
    cx: f32,
    cy: f32,
    cz: f32,
    radius: f32,
    out_ptr: [*]u32,
    max_count: u32,
) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const physics_mod = @import("../physics/system.zig");
    const hits = ctx.physicsOverlapBox(.{ cx, cy, cz }, .{ radius, radius, radius }, .{}) catch return 0;
    defer ctx.allocator.free(hits);
    const count: u32 = @intCast(@min(hits.len, max_count));
    for (0..count) |i| {
        out_ptr[i] = @intCast(hits[i].entity_id);
    }
    _ = physics_mod;
    return count;
}

// ── GameState / TimeScale WASM API ──

/// 获取当前 GameState（0=GameStart, 1=Playing, 2=Paused, 3=GameOver, 4=Quit）
pub export fn guava_wasm_host_get_game_state(userdata: ?*anyopaque) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    return ctx.game_state;
}

/// 设置 GameState
pub export fn guava_wasm_host_set_game_state(userdata: ?*anyopaque, state: u32) void {
    const ctx = activeContext(userdata) orelse return;
    if (ctx.game_state_ptr) |ptr| {
        ptr.* = state;
    }
}

/// 获取当前 time_scale
pub export fn guava_wasm_host_get_time_scale(userdata: ?*anyopaque) f32 {
    const ctx = activeContext(userdata) orelse return 1.0;
    return ctx.time_scale;
}

/// 设置 time_scale（0.0 冻结, 1.0 正常, 0.5 慢动作等）
pub export fn guava_wasm_host_set_time_scale(userdata: ?*anyopaque, scale: f32) void {
    const ctx = activeContext(userdata) orelse return;
    if (ctx.time_scale_ptr) |ptr| {
        ptr.* = @max(0.0, @min(10.0, scale));
    }
}

// ── Input WASM API ──

/// 检测指定按键是否正在按下（持续状态）
pub export fn guava_wasm_host_is_key_down(userdata: ?*anyopaque, key_code: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_code))) catch return 0;
    return if (input_state.isKeyDown(key)) @as(u32, 1) else @as(u32, 0);
}

/// 检测指定按键是否在本帧刚被按下
pub export fn guava_wasm_host_was_key_pressed(userdata: ?*anyopaque, key_code: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_code))) catch return 0;
    return if (input_state.wasKeyPressed(key)) @as(u32, 1) else @as(u32, 0);
}

/// 检测指定按键是否在本帧刚被释放
pub export fn guava_wasm_host_was_key_released(userdata: ?*anyopaque, key_code: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_code))) catch return 0;
    return if (input_state.wasKeyReleased(key)) @as(u32, 1) else @as(u32, 0);
}

/// 检测鼠标按钮是否按下
pub export fn guava_wasm_host_is_mouse_button_down(userdata: ?*anyopaque, button: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const mb = std.meta.intToEnum(input_mod.MouseButton, @as(u8, @intCast(button))) catch return 0;
    return if (input_state.isMouseDown(mb)) @as(u32, 1) else @as(u32, 0);
}

/// 获取帧 delta time
pub export fn guava_wasm_host_get_delta_time(userdata: ?*anyopaque) f32 {
    const ctx = activeContext(userdata) orelse return 0.0;
    return ctx.delta_time;
}

// ── Transform Getter WASM API ──

/// 获取实体的局部位移。将 3 个 f32 (x,y,z) 写入 out_ptr。成功返回 1。
pub export fn guava_wasm_host_get_local_translation(userdata: ?*anyopaque, entity_id_raw: u32, out_ptr: [*]f32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    const transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    out_ptr[0] = transform.translation[0];
    out_ptr[1] = transform.translation[1];
    out_ptr[2] = transform.translation[2];
    return 1;
}

/// 获取实体的局部旋转四元数。将 4 个 f32 (x,y,z,w) 写入 out_ptr。
pub export fn guava_wasm_host_get_local_rotation(userdata: ?*anyopaque, entity_id_raw: u32, out_ptr: [*]f32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    const transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    out_ptr[0] = transform.rotation[0];
    out_ptr[1] = transform.rotation[1];
    out_ptr[2] = transform.rotation[2];
    out_ptr[3] = transform.rotation[3];
    return 1;
}

/// 获取实体的局部缩放。将 3 个 f32 (x,y,z) 写入 out_ptr。
pub export fn guava_wasm_host_get_local_scale(userdata: ?*anyopaque, entity_id_raw: u32, out_ptr: [*]f32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    const transform = resolveLocalTransform(ctx, entity_id) orelse return 0;
    out_ptr[0] = transform.scale[0];
    out_ptr[1] = transform.scale[1];
    out_ptr[2] = transform.scale[2];
    return 1;
}

// ── Entity Spawn/Destroy WASM API ──

/// 创建一个新的空实体，作为脚本实体的子对象。返回新实体 ID（0 = 失败）。
pub export fn guava_wasm_host_spawn_entity(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: u32) u32 {
    const ctx = activeContext(userdata) orelse return 0;
    const name = name_ptr[0..name_len];
    const new_id = ctx.createChild(name) catch return 0;
    return @intCast(new_id);
}

/// 销毁指定实体。
pub export fn guava_wasm_host_destroy_entity(userdata: ?*anyopaque, entity_id_raw: u32) void {
    const ctx = activeContext(userdata) orelse return;
    const entity_id: types.EntityId = @intCast(entity_id_raw);
    ctx.destroyEntity(entity_id);
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

// ── Debug helpers (public, used by debug_session.zig) ────────────────

/// Get the WAMR exec_env from a script instance.
pub fn getExecEnv(instance: *types.ScriptInstance) ?c.wasm_exec_env_t {
    const state = getInstanceState(instance) orelse return null;
    return state.exec_env;
}

/// Get the WAMR module_inst from a script instance.
pub fn getModuleInst(instance: *types.ScriptInstance) ?c.wasm_module_inst_t {
    const state = getInstanceState(instance) orelse return null;
    return state.module_inst;
}

/// Dump the call stack to an allocated buffer.
pub fn dumpCallStackAlloc(allocator: std.mem.Allocator, instance: *types.ScriptInstance) ![]u8 {
    const state = getInstanceState(instance) orelse return allocator.alloc(u8, 0);
    if (state.exec_env == null) return allocator.alloc(u8, 0);

    const buf_size = c.wasm_runtime_get_call_stack_buf_size(state.exec_env);
    if (buf_size == 0) return allocator.alloc(u8, 0);

    const buf = try allocator.alloc(u8, buf_size);
    const written = c.wasm_runtime_dump_call_stack_to_buf(state.exec_env, buf.ptr, @intCast(buf.len));
    if (written == 0) {
        allocator.free(buf);
        return allocator.alloc(u8, 0);
    }

    return buf[0..written];
}

/// Read parameter count from a WASM instance (for variable inspection).
pub fn getParamCount(instance: *types.ScriptInstance) u32 {
    const state = getInstanceState(instance) orelse return 0;
    const func = state.param_count_fn orelse return 0;
    if (state.exec_env == null) return 0;
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{0};
    if (!c.wasm_runtime_call_wasm(state.exec_env, func, 0, &argv)) return 0;
    return argv[0];
}

/// Read a parameter name by index from a WASM instance.
pub fn getParamName(instance: *types.ScriptInstance, index: u32) []const u8 {
    const state = getInstanceState(instance) orelse return "";
    const ptr_fn = state.param_name_ptr_fn orelse return "";
    const len_fn = state.param_name_len_fn orelse return "";
    if (state.exec_env == null or state.module_inst == null) return "";

    c.wasm_runtime_clear_exception(state.module_inst);
    var ptr_argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, ptr_fn, 2, &ptr_argv)) return "";
    var len_argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, len_fn, 2, &len_argv)) return "";

    const app_offset = ptr_argv[0];
    const name_len = len_argv[0];
    if (name_len == 0) return "";
    if (!c.wasm_runtime_validate_app_addr(state.module_inst, app_offset, name_len)) return "";
    const native = c.wasm_runtime_addr_app_to_native(state.module_inst, app_offset) orelse return "";
    const bytes: [*]const u8 = @ptrCast(native);
    return bytes[0..name_len];
}

/// Parameter kind enum matching the reflection protocol.
pub const ParamKind = enum(u8) { float = 0, boolean = 1, integer = 2 };

/// Read a parameter's kind by index.
pub fn getParamKind(instance: *types.ScriptInstance, index: u32) ?ParamKind {
    const state = getInstanceState(instance) orelse return null;
    const func = state.param_kind_fn orelse return null;
    if (state.exec_env == null) return null;
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, func, 2, &argv)) return null;
    return std.meta.intToEnum(ParamKind, @as(u8, @intCast(argv[0]))) catch null;
}

/// Read a float parameter value by index.
pub fn getParamFloat(instance: *types.ScriptInstance, index: u32) ?f32 {
    const state = getInstanceState(instance) orelse return null;
    const func = state.param_get_f32_fn orelse return null;
    if (state.exec_env == null) return null;
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, func, 2, &argv)) return null;
    return @bitCast(argv[0]);
}

/// Read a boolean parameter value by index.
pub fn getParamBool(instance: *types.ScriptInstance, index: u32) ?bool {
    const state = getInstanceState(instance) orelse return null;
    const func = state.param_get_bool_fn orelse return null;
    if (state.exec_env == null) return null;
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, func, 2, &argv)) return null;
    return argv[0] != 0;
}

/// Read an integer parameter value by index.
pub fn getParamInt(instance: *types.ScriptInstance, index: u32) ?i32 {
    const state = getInstanceState(instance) orelse return null;
    const func = state.param_get_i32_fn orelse return null;
    if (state.exec_env == null) return null;
    c.wasm_runtime_clear_exception(state.module_inst);
    var argv = [_]u32{ 0, index };
    if (!c.wasm_runtime_call_wasm(state.exec_env, func, 2, &argv)) return null;
    return @bitCast(argv[0]);
}
