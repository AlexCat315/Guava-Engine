const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");

const log = std.log.scoped(.vm);

/// 虚拟机接口 - 支持多种脚本语言
pub const ScriptVM = struct {
    /// 虚拟机类型
    vtable: *const VTable,

    pub const VTable = struct {
        /// 加载脚本
        load: fn (vm: *ScriptVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void,
        /// 卸载脚本
        unload: fn (vm: *ScriptVM) void,
        /// 创建实例
        createInstance: fn (vm: *ScriptVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance,
        /// 销毁实例
        destroyInstance: fn (vm: *ScriptVM, instance: *types.ScriptInstance) void,
        /// 调用初始化
        callInit: fn (vm: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        /// 调用更新
        callUpdate: fn (vm: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void,
        /// 调用销毁
        callDestroy: fn (vm: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        /// 获取错误信息
        getError: fn (vm: *ScriptVM) []const u8,
    };

    /// 加载脚本
    pub fn load(self: *ScriptVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        return self.vtable.load(self, source, language);
    }

    /// 卸载脚本
    pub fn unload(self: *ScriptVM) void {
        self.vtable.unload(self);
    }

    /// 创建实例
    pub fn createInstance(self: *ScriptVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return self.vtable.createInstance(self, ctx);
    }

    /// 销毁实例
    pub fn destroyInstance(self: *ScriptVM, instance: *types.ScriptInstance) void {
        self.vtable.destroyInstance(self, instance);
    }

    /// 调用初始化
    pub fn callInit(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callInit(self, instance, ctx);
    }

    /// 调用更新
    pub fn callUpdate(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return self.vtable.callUpdate(self, instance, ctx, dt);
    }

    /// 调用销毁
    pub fn callDestroy(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callDestroy(self, instance, ctx);
    }

    /// 获取错误信息
    pub fn getError(self: *ScriptVM) []const u8 {
        return self.vtable.getError(self);
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
        if (instance.vtable.onInit) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn callUpdate(vm: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        if (instance.vtable.onUpdate) |fn_ptr| {
            fn_ptr(ctx, dt);
        }
    }

    pub fn callDestroy(vm: *ZigVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        if (instance.vtable.onDestroy) |fn_ptr| {
            fn_ptr(ctx);
        }
    }

    pub fn getError(vm: *ZigVM) []const u8 {
        return vm.error_msg;
    }

    /// 获取 Zig VM 的 VTable
    pub fn vtable() ScriptVM.VTable {
        return .{
            .load = @ptrCast(&load),
            .unload = @ptrCast(&unload),
            .createInstance = @ptrCast(&createInstance),
            .destroyInstance = @ptrCast(&destroyInstance),
            .callInit = @ptrCast(&callInit),
            .callUpdate = @ptrCast(&callUpdate),
            .callDestroy = @ptrCast(&callDestroy),
            .getError = @ptrCast(&getError),
        };
    }
};

/// C# 虚拟机存根 - 未来实现
pub const CSharpVM = struct {
    allocator: std.mem.Allocator,
    error_msg: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) CSharpVM {
        return .{ .allocator = allocator };
    }

    pub fn load(vm: *CSharpVM, source: []const u8, language: types.ScriptLanguage) types.ScriptError!void {
        if (language != .csharp) {
            return types.ScriptError.InvalidLanguage;
        }
        // TODO: 未来通过 .NET 运行时或 IL2CPP 实现
        return types.ScriptError.NotFound;
    }

    pub fn getError(vm: *CSharpVM) []const u8 {
        return vm.error_msg;
    }

    pub fn vtable() ScriptVM.VTable {
        return .{
            .load = @ptrCast(&load),
            .unload = @ptrCast(&unloadStub),
            .createInstance = @ptrCast(&createInstanceStub),
            .destroyInstance = @ptrCast(&destroyInstanceStub),
            .callInit = @ptrCast(&callInitStub),
            .callUpdate = @ptrCast(&callUpdateStub),
            .callDestroy = @ptrCast(&callDestroyStub),
            .getError = @ptrCast(&getError),
        };
    }

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
        if (language != .lua) {
            return types.ScriptError.InvalidLanguage;
        }
        // TODO: 未来通过 Lua 运行时实现
        return types.ScriptError.NotFound;
    }

    pub fn getError(vm: *LuaVM) []const u8 {
        return vm.error_msg;
    }

    pub fn vtable() ScriptVM.VTable {
        return .{
            .load = @ptrCast(&load),
            .unload = @ptrCast(&unloadStub),
            .createInstance = @ptrCast(&createInstanceStub),
            .destroyInstance = @ptrCast(&destroyInstanceStub),
            .callInit = @ptrCast(&callInitStub),
            .callUpdate = @ptrCast(&callUpdateStub),
            .callDestroy = @ptrCast(&callDestroyStub),
            .getError = @ptrCast(&getError),
        };
    }

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
            const vm = try allocator.create(ZigVM);
            vm.* = ZigVM.init(allocator);
            const script_vm = try allocator.create(ScriptVM);
            script_vm.* = .{
                .vtable = &vm.vtable(),
            };
            return script_vm;
        },
        .csharp => {
            return types.ScriptError.NotFound; // 尚未实现
        },
        .lua => {
            return types.ScriptError.NotFound; // 尚未实现
        },
    }
}
