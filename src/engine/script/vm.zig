const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");

const log = std.log.scoped(.vm);

/// 虚拟机接口 - 支持多种脚本语言
pub const ScriptVM = struct {
    context: *anyopaque,
    /// 虚拟机类型
    vtable: *const VTable,

    pub const VTable = struct {
        /// 加载脚本
        load: *const fn (vm_context: *anyopaque, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void,
        /// 卸载脚本
        unload: *const fn (vm_context: *anyopaque) void,
        /// 创建实例
        createInstance: *const fn (vm_context: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance,
        /// 销毁实例
        destroyInstance: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance) void,
        /// 调用初始化
        callInit: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        /// 调用更新
        callUpdate: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void,
        /// 调用销毁
        callDestroy: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        /// 获取错误信息
        getError: *const fn (vm_context: *anyopaque) []const u8,
        /// 销毁具体 VM 实例
        destroy: *const fn (vm_context: *anyopaque, allocator: std.mem.Allocator) void,
    };

    /// 加载脚本
    pub fn load(self: *ScriptVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        return self.vtable.load(self.context, source, language);
    }

    /// 卸载脚本
    pub fn unload(self: *ScriptVM) void {
        self.vtable.unload(self.context);
    }

    /// 创建实例
    pub fn createInstance(self: *ScriptVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return self.vtable.createInstance(self.context, ctx);
    }

    /// 销毁实例
    pub fn destroyInstance(self: *ScriptVM, instance: *types.ScriptInstance) void {
        self.vtable.destroyInstance(self.context, instance);
    }

    /// 调用初始化
    pub fn callInit(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callInit(self.context, instance, ctx);
    }

    /// 调用更新
    pub fn callUpdate(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return self.vtable.callUpdate(self.context, instance, ctx, dt);
    }

    /// 调用销毁
    pub fn callDestroy(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callDestroy(self.context, instance, ctx);
    }

    /// 获取错误信息
    pub fn getError(self: *ScriptVM) []const u8 {
        return self.vtable.getError(self.context);
    }

    pub fn deinit(self: *ScriptVM, allocator: std.mem.Allocator) void {
        self.unload();
        self.vtable.destroy(self.context, allocator);
    }
};

/// Zig 原生虚拟机 - 直接编译执行 Zig 代码
pub const ZigVM = struct {
    /// 当前加载的脚本源码
    source: []const u8 = &.{},
    /// 编译后的模块
    compiled_module: ?*anyopaque = null,
    /// 错误信息
    error_msg: []u8 = &.{},
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZigVM {
        return .{
            .allocator = allocator,
        };
    }

    pub fn load(vm: *ZigVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        if (language != .zig) {
            return types.ScriptError.InvalidLanguage;
        }
        vm.source = source;
        // TODO: 使用 Zig 的 compile step 实现动态编译
        log.info("Zig script loaded: {d} bytes", .{source.len});
    }

    pub fn unload(vm: *ZigVM) void {
        vm.source = &.{};
        if (vm.compiled_module) |module| {
            // TODO: 释放编译的模块
            _ = module;
            vm.compiled_module = null;
        }
    }

    pub fn createInstance(vm: *ZigVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        const instance = try vm.allocator.create(types.ScriptInstance);
        instance.* = .{
            .id = 0, // 由 runtime 分配
            .entity_id = ctx.entity,
            .script_handle = undefined,
            .vtable = .{
                .onInit = null,
                .onUpdate = null,
                .onDestroy = null,
            },
            .state = .ready,
        };
        return instance;
    }

    pub fn destroyInstance(vm: *ZigVM, instance: *types.ScriptInstance) void {
        vm.allocator.destroy(instance);
    }

    pub fn callInit(vm: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        _ = vm;
        if (instance.vtable.onInit) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn callUpdate(vm: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        _ = vm;
        if (instance.vtable.onUpdate) |fn_ptr| {
            fn_ptr(ctx, dt);
        }
    }

    pub fn callDestroy(vm: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        _ = vm;
        if (instance.vtable.onDestroy) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn getError(vm: *ZigVM) []const u8 {
        return vm.error_msg;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(ZigVM, context_ptr);
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

/// C# 虚拟机存根 - 未来实现
pub const CSharpVM = struct {
    allocator: std.mem.Allocator,
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) CSharpVM {
        return .{ .allocator = allocator };
    }

    pub fn load(vm: *CSharpVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        _ = vm;
        _ = source;
        if (language != .csharp) {
            return types.ScriptError.InvalidLanguage;
        }
        // TODO: 未来通过 .NET 运行时或 IL2CPP 实现
        return types.ScriptError.NotFound;
    }

    pub fn getError(vm: *CSharpVM) []const u8 {
        return vm.error_msg;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(CSharpVM, context_ptr);
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

    fn unloadStub(_: *CSharpVM) void {}
    fn createInstanceStub(_: *CSharpVM, _: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return types.ScriptError.NotFound;
    }
    fn destroyInstanceStub(_: *CSharpVM, _: *types.ScriptInstance) void {}
    fn callInitStub(_: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {}
    fn callUpdateStub(_: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext, _: f32) types.ScriptError!void {}
    fn callDestroyStub(_: *CSharpVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {}
};

/// Lua 虚拟机存根 - 未来实现
pub const LuaVM = struct {
    allocator: std.mem.Allocator,
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) LuaVM {
        return .{ .allocator = allocator };
    }

    pub fn load(vm: *LuaVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        _ = vm;
        _ = source;
        if (language != .lua) {
            return types.ScriptError.InvalidLanguage;
        }
        // TODO: 未来通过 Lua 运行时实现
        return types.ScriptError.NotFound;
    }

    pub fn getError(vm: *LuaVM) []const u8 {
        return vm.error_msg;
    }

    fn destroyContext(context_ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const vm = castContext(LuaVM, context_ptr);
        allocator.destroy(vm);
    }

    pub const script_vm_vtable: ScriptVM.VTable = .{
        .load = luaLoadBridge,
        .unload = luaUnloadBridge,
        .createInstance = luaCreateInstanceBridge,
        .destroyInstance = luaDestroyInstanceBridge,
        .callInit = luaCallInitBridge,
        .callUpdate = luaCallUpdateBridge,
        .callDestroy = luaCallDestroyBridge,
        .getError = luaGetErrorBridge,
        .destroy = destroyContext,
    };

    fn unloadStub(_: *LuaVM) void {}
    fn createInstanceStub(_: *LuaVM, _: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return types.ScriptError.NotFound;
    }
    fn destroyInstanceStub(_: *LuaVM, _: *types.ScriptInstance) void {}
    fn callInitStub(_: *LuaVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {}
    fn callUpdateStub(_: *LuaVM, _: *types.ScriptInstance, _: *context.ScriptContext, _: f32) types.ScriptError!void {}
    fn callDestroyStub(_: *LuaVM, _: *types.ScriptInstance, _: *context.ScriptContext) types.ScriptError!void {}
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
        .lua => {
            const script_vm = try allocator.create(ScriptVM);
            errdefer allocator.destroy(script_vm);
            const vm = try allocator.create(LuaVM);
            errdefer allocator.destroy(vm);
            vm.* = LuaVM.init(allocator);
            script_vm.* = .{
                .context = vm,
                .vtable = &LuaVM.script_vm_vtable,
            };
            return script_vm;
        },
    }
}

fn castContext(comptime T: type, context_ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(context_ptr));
}

fn zigLoadBridge(context_ptr: *anyopaque, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
    return ZigVM.load(castContext(ZigVM, context_ptr), source, language);
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

fn csharpLoadBridge(context_ptr: *anyopaque, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
    return CSharpVM.load(castContext(CSharpVM, context_ptr), source, language);
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

fn luaLoadBridge(context_ptr: *anyopaque, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
    return LuaVM.load(castContext(LuaVM, context_ptr), source, language);
}

fn luaUnloadBridge(context_ptr: *anyopaque) void {
    LuaVM.unloadStub(castContext(LuaVM, context_ptr));
}

fn luaCreateInstanceBridge(context_ptr: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
    return LuaVM.createInstanceStub(castContext(LuaVM, context_ptr), ctx);
}

fn luaDestroyInstanceBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance) void {
    LuaVM.destroyInstanceStub(castContext(LuaVM, context_ptr), instance);
}

fn luaCallInitBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return LuaVM.callInitStub(castContext(LuaVM, context_ptr), instance, ctx);
}

fn luaCallUpdateBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
    return LuaVM.callUpdateStub(castContext(LuaVM, context_ptr), instance, ctx, dt);
}

fn luaCallDestroyBridge(context_ptr: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
    return LuaVM.callDestroyStub(castContext(LuaVM, context_ptr), instance, ctx);
}

fn luaGetErrorBridge(context_ptr: *anyopaque) []const u8 {
    return LuaVM.getError(castContext(LuaVM, context_ptr));
}
