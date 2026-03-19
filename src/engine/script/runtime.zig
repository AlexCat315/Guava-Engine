const std = @import("std");
const types = @import("./types.zig");
const context = @import("./context.zig");
const vm_mod = @import("./vm.zig");
const hot_reload_mod = @import("./hot_reload.zig");
const handles = @import("../assets/handles.zig");
const world_mod = @import("../scene/world.zig");

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
    /// 当前绑定的世界
    world: ?*world_mod.World = null,
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
            else
                null,
        };
    }

    pub fn deinit(self: *ScriptRuntime) void {
        var instances_to_destroy = std.ArrayList(*types.ScriptInstance).empty;
        defer instances_to_destroy.deinit(self.allocator);

        // 销毁所有实例
        var instances_iter = self.instances.valueIterator();
        while (instances_iter.next()) |instance| {
            instances_to_destroy.append(self.allocator, instance.*) catch |err| {
                log.err("Failed to queue instance for destruction: {}", .{err});
                break;
            };
        }
        for (instances_to_destroy.items) |instance| {
            if (self.instances.contains(instance.id)) {
                self.destroyInstance(instance);
            }
        }
        self.instances.deinit();

        // 销毁实体脚本列表
        var iter = self.entity_scripts.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.entity_scripts.deinit();

        // 销毁 VM
        var vms_iter = self.vms.valueIterator();
        while (vms_iter.next()) |vm| {
            const script_vm = vm.*;
            script_vm.deinit(self.allocator);
            self.allocator.destroy(script_vm);
        }
        self.vms.deinit();

        // 销毁热重载管理器
        if (self.hot_reload) |*hr| {
            hr.deinit();
        }
    }

    pub fn bindWorld(self: *ScriptRuntime, world: *world_mod.World) void {
        self.world = world;
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
            list.value_ptr.* = .empty;
        }
        try list.value_ptr.append(self.allocator, instance_id);

        return instance;
    }

    fn registerInstance(
        self: *ScriptRuntime,
        entity_id: types.EntityId,
        instance: *types.ScriptInstance,
    ) !void {
        try self.instances.put(instance.id, instance);

        var list = try self.entity_scripts.getOrPut(entity_id);
        if (!list.found_existing) {
            list.value_ptr.* = .empty;
        }
        try list.value_ptr.append(self.allocator, instance.id);
    }

    /// 销毁脚本实例
    pub fn destroyInstance(self: *ScriptRuntime, instance: *types.ScriptInstance) void {
        instance.state = .destroyed;

        // 从实例表中移除
        _ = self.instances.remove(instance.id);

        // 从实体脚本列表中移除
        if (self.entity_scripts.getPtr(instance.entity_id)) |list| {
            for (list.items, 0..) |id, i| {
                if (id == instance.id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.entity_scripts.remove(instance.entity_id);
            }
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
        const list = self.entity_scripts.getPtr(entity_id) orelse return null;
        return list.items;
    }

    /// 重新加载脚本
    pub fn reloadScript(self: *ScriptRuntime, handle: handles.ScriptHandle) !void {
        const world = self.world orelse return types.ScriptError.NotFound;
        const resource = world.resources.script(handle) orelse return types.ScriptError.NotFound;
        const vm = self.getVM(resource.language) orelse return types.ScriptError.InvalidLanguage;

        try vm.load(resource.source, resource.language);

        for (world.entities.items) |*entity| {
            if (entity.script) |*script| {
                if (script.script_handle != handle) {
                    continue;
                }

                if (script.instance_id) |instance_id| {
                    if (self.instances.get(instance_id)) |instance| {
                        var ctx = context.ScriptContext{
                            .entity = entity.id,
                            .world = world,
                            .instance = instance,
                            .allocator = self.allocator,
                        };
                        vm.callDestroy(instance, &ctx) catch |err| {
                            log.err("Script destroy during reload failed: {}", .{err});
                        };
                        self.destroyInstance(instance);
                    }
                    script.instance_id = null;
                }
            }
        }
    }

    /// 调用所有脚本的 OnInit
    pub fn callInitAll(self: *ScriptRuntime, world: *anyopaque) void {
        const world_ptr = @as(*world_mod.World, @ptrCast(@alignCast(world)));

        // 遍历所有实体，为每个新脚本创建实例并调用 OnInit
        for (world_ptr.entities.items) |*entity| {
            if (entity.script) |*script| {
                if (!script.enabled) continue;
                if (script.instance_id == null and script.script_handle != null) {
                    const script_language: types.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
                    const script_resource = world_ptr.resources.script(script.script_handle.?) orelse {
                        log.err("Script handle {} not found for entity {}", .{ script.script_handle.?, entity.id });
                        continue;
                    };

                    // 创建脚本实例
                    if (self.getVM(script_language)) |vm| {
                        vm.load(script_resource.source, script_resource.language) catch |err| {
                            log.err("Failed to load script for entity {}: {}", .{ entity.id, err });
                            continue;
                        };

                        var ctx = context.ScriptContext{
                            .entity = entity.id,
                            .world = world_ptr,
                            .instance = undefined, // 将填充
                            .allocator = self.allocator,
                        };

                        const instance = vm.createInstance(&ctx) catch |err| {
                            std.log.err("Failed to create script instance: {}", .{err});
                            continue;
                        };

                        instance.id = self.next_instance_id;
                        self.next_instance_id += 1;
                        instance.entity_id = entity.id;
                        instance.script_handle = script.script_handle.?;
                        ctx.instance = instance;

                        self.registerInstance(entity.id, instance) catch |err| {
                            std.log.err("Failed to register script instance: {}", .{err});
                            vm.destroyInstance(instance);
                            continue;
                        };

                        script.instance_id = instance.id;

                        // 调用 OnInit（处理错误）
                        vm.callInit(instance, &ctx) catch |err| {
                            std.log.err("Script init error: {}", .{err});
                            instance.state = .failed;
                        };
                    }
                }
            }
        }
    }

    /// 调用所有脚本的 OnDestroy
    pub fn callDestroyAll(self: *ScriptRuntime, world: *anyopaque) void {
        const world_ptr = @as(*world_mod.World, @ptrCast(@alignCast(world)));
        var to_destroy = std.ArrayList(*types.ScriptInstance).empty;
        defer to_destroy.deinit(self.allocator);

        var iter = self.instances.valueIterator();
        while (iter.next()) |instance| {
            to_destroy.append(self.allocator, instance.*) catch |err| {
                log.err("Failed to queue script instance for shutdown: {}", .{err});
                return;
            };
        }

        for (to_destroy.items) |instance| {
            var script_language: types.ScriptLanguage = .zig;
            if (world_ptr.getEntity(instance.entity_id)) |entity| {
                if (entity.script) |*script| {
                    script_language = @enumFromInt(@intFromEnum(script.language));
                    script.instance_id = null;
                }
            }

            if (self.getVM(script_language)) |vm| {
                var ctx = context.ScriptContext{
                    .entity = instance.entity_id,
                    .world = world_ptr,
                    .instance = instance,
                    .allocator = self.allocator,
                };
                vm.callDestroy(instance, &ctx) catch |err| {
                    log.err("Script destroy error: {}", .{err});
                };
            }

            self.destroyInstance(instance);
        }
    }

    /// 检查热重载
    pub fn checkHotReload(self: *ScriptRuntime) void {
        if (self.hot_reload) |*hr| {
            hr.checkForChanges();
            hr.processPendingReload();
        }
    }
};
