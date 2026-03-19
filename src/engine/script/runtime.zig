const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");
const vm_mod = @import("./vm.zig");
const hot_reload_mod = @import("./hot_reload.zig");
const handles = @import("../assets/handles.zig");

const log = std.log.scoped(.script_runtime);

/// 脚本运行时 - 管理所有脚本实例
pub const ScriptRuntime = struct {
    /// 配置
    config: types.ScriptSystemConfig,
    /// 实例表
    instances: std.AutoHashMap(types.ScriptInstanceId, *types.ScriptInstance),
    /// 下一个实例 ID
    next_instance_id: types.ScriptInstanceId = 1,
    /// 每实体的脚本列表（entity_id -> script handles）
    entity_scripts: std.AutoHashMap(types.EntityId, std.ArrayList(types.ScriptInstanceId)),
    /// 按语言分组的 VM
    vms: std.AutoHashMap(types.ScriptLanguage, *vm_mod.ScriptVM),
    /// 热重载管理器
    hot_reload: ?hot_reload_mod.HotReloadManager,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 临时上下文（每帧复用）
    temp_context: ?*context.ScriptContext = null,

    pub fn init(allocator: std.mem.Allocator, config: types.ScriptSystemConfig) ScriptRuntime {
        return .{
            .config = config,
            .instances = std.AutoHashMap(types.ScriptInstanceId, *types.ScriptInstance).init(allocator),
            .entity_scripts = std.AutoHashMap(types.EntityId, std.ArrayList(types.ScriptInstanceId)).init(allocator),
            .vms = std.AutoHashMap(types.ScriptLanguage, *vm_mod.ScriptVM).init(allocator),
            .allocator = allocator,
            .hot_reload = if (config.enable_hot_reload)
                hot_reload_mod.HotReloadManager.init(allocator, undefined)
            else null,
        };
    }

    pub fn deinit(self: *ScriptRuntime) void {
        // 销毁所有实例
        var instances_iter = self.instances.valueIterator();
        while (instances_iter.next()) |instance| {
            self.destroyInstance(instance.*);
        }
        self.instances.deinit();

        // 销毁实体脚本列表
        var iter = self.entity_scripts.valueIterator();
        while (iter.next()) |list| {
            list.deinit();
        }
        self.entity_scripts.deinit();

        // 销毁 VM
        var vms_iter = self.vms.valueIterator();
        while (vms_iter.next()) |vm| {
            vm_mod.ScriptVM.unload(vm.*);
            self.allocator.destroy(vm.*);
        }
        self.vms.deinit();

        // 销毁热重载管理器
        if (self.hot_reload) |hr| {
            hr.deinit();
        }
    }

    /// 初始化 VM
    pub fn initVMs(self: *ScriptRuntime) !void {
        for (self.config.allowed_languages) |lang| {
            const vm = try vm_mod.createVM(lang, self.allocator);
            try self.vms.put(lang, vm);
        }

        // 初始化热重载管理器
        if (self.hot_reload) |*hr| {
            hr.runtime = self;
        }
    }

    /// 为实体创建脚本实例
    pub fn createScriptInstance(
        self: *ScriptRuntime,
        entity_id: types.EntityId,
        script_handle: handles.ScriptHandle,
    ) !*types.ScriptInstance {
        const instance_id = self.next_instance_id;
        self.next_instance_id += 1;

        // 创建实例
        const instance = try self.allocator.create(types.ScriptInstance);
        instance.* = .{
            .id = instance_id,
            .entity_id = entity_id,
            .script_handle = script_handle,
            .vtable = .{},
            .state = .ready,
        };

        try self.instances.put(instance_id, instance);

        // 添加到实体脚本列表
        var list = try self.entity_scripts.getOrPut(entity_id);
        if (!list.found_existing) {
            list.value_ptr.* = std.ArrayList(types.ScriptInstanceId).init(self.allocator);
        }
        try list.value_ptr.append(instance_id);

        return instance;
    }

    /// 销毁脚本实例
    pub fn destroyInstance(self: *ScriptRuntime, instance: *types.ScriptInstance) void {
        instance.state = .destroyed;

        // 从实例表中移除
        self.instances.remove(instance.id);

        // 从实体脚本列表中移除
        if (self.entity_scripts.get(instance.entity_id)) |list| {
            for (list.items, 0..) |id, i| {
                if (id == instance.id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }

        // 释放用户数据
        if (instance.user_data != null and instance.user_data_size > 0) {
            self.allocator.free(instance.user_data.?);
        }

        // 释放错误信息
        if (instance.last_error.len > 0) {
            self.allocator.free(instance.last_error);
        }

        self.allocator.destroy(instance);
    }

    /// 获取 VM
    pub fn getVM(self: *ScriptRuntime, language: types.ScriptLanguage) ?*vm_mod.ScriptVM {
        return self.vms.get(language);
    }

    /// 获取实体的所有脚本实例
    pub fn getEntityScripts(self: *ScriptRuntime, entity_id: types.EntityId) ?[]const types.ScriptInstanceId {
        return self.entity_scripts.get(entity_id);
    }

    /// 重新加载脚本
    pub fn reloadScript(self: *ScriptRuntime, handle: handles.ScriptHandle) !void {
        // TODO: 实现脚本重载
    }

    /// 调用所有脚本的 OnInit
    pub fn callInitAll(self: *ScriptRuntime, world: *anyopaque) void {
        // TODO: 遍历所有脚本实例并调用 OnInit
    }

    /// 调用所有脚本的 OnUpdate
    pub fn callUpdateAll(self: *ScriptRuntime, world: *anyopaque, dt: f32) void {
        // TODO: 遍历所有脚本实例并调用 OnUpdate
    }

    /// 调用所有脚本的 OnDestroy
    pub fn callDestroyAll(self: *ScriptRuntime, world: *anyopaque) void {
        // TODO: 遍历所有脚本实例并调用 OnDestroy
    }

    /// 检查热重载
    pub fn checkHotReload(self: *ScriptRuntime) void {
        if (self.hot_reload) |hr| {
            hr.checkForChanges();
        }
    }
};
