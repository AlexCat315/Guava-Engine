const std = @import("std");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const types = @import("./types.zig");

/// 实体类型别名
pub const EntityId = world_mod.EntityId;

/// 脚本执行上下文 - 脚本运行时可用的 API
pub const ScriptContext = struct {
    /// 关联的实体 ID
    entity: EntityId,
    /// 世界指针（用于查询）
    world: *world_mod.World,
    /// 脚本实例指针
    instance: *types.ScriptInstance,
    /// 分配器
    allocator: std.mem.Allocator,

    /// 获取实体的名称
    pub fn getName(self: *ScriptContext) []const u8 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].name;
        }
        return "";
    }

    /// 获取实体的 Transform
    pub fn getTransform(self: *ScriptContext) ?*components.Transform {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return &self.world.entities.items[idx].local_transform;
        }
        return null;
    }

    /// 获取实体的世界 Transform
    pub fn getWorldTransform(self: *ScriptContext) ?components.Transform {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].world_transform_cache;
        }
        return null;
    }

    /// 设置实体的位置
    pub fn setPosition(self: *ScriptContext, pos: components.Vec3) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.translation = pos;
            self.world.entities.items[idx].dirty = true;
        }
    }

    /// 设置实体的旋转（四元数）
    pub fn setRotation(self: *ScriptContext, rot: components.Quat) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.rotation = rot;
            self.world.entities.items[idx].dirty = true;
        }
    }

    /// 设置实体的缩放
    pub fn setScale(self: *ScriptContext, scale: components.Vec3) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.scale = scale;
            self.world.entities.items[idx].dirty = true;
        }
    }

    /// 获取实体的位置
    pub fn getPosition(self: *ScriptContext) ?components.Vec3 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.translation;
        }
        return null;
    }

    /// 获取实体的旋转
    pub fn getRotation(self: *ScriptContext) ?components.Quat {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.rotation;
        }
        return null;
    }

    /// 获取实体的缩放
    pub fn getScale(self: *ScriptContext) ?components.Vec3 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.scale;
        }
        return null;
    }

    /// 根据名称查找实体
    pub fn findEntityByName(self: *ScriptContext, name: []const u8) ?EntityId {
        for (self.world.entities.items) |entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity.id;
            }
        }
        return null;
    }

    /// 获取子实体数量
    pub fn getChildCount(self: *ScriptContext) usize {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].children.items.len;
        }
        return 0;
    }

    /// 获取子实体
    pub fn getChild(self: *ScriptContext, index: usize) ?EntityId {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            const children = &self.world.entities.items[idx].children;
            if (index < children.items.len) {
                return children.items[index];
            }
        }
        return null;
    }

    /// 获取父实体
    pub fn getParent(self: *ScriptContext) ?EntityId {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].parent;
        }
        return null;
    }

    /// 检查实体是否有指定组件
    pub fn hasComponent(self: *ScriptContext, comptime T: type) bool {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            const entity = &self.world.entities.items[idx];
            return entity.hasComponent(T);
        }
        return false;
    }

    /// 获取组件指针
    pub fn getComponent(self: *ScriptContext, comptime T: type) ?*T {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].getComponent(T);
        }
        return null;
    }

    /// 创建子实体
    pub fn createChild(self: *ScriptContext, name: []const u8) !EntityId {
        const desc = world_mod.EntityDesc{
            .name = name,
            .parent = self.entity,
        };
        return try self.world.createEntity(desc);
    }

    /// 销毁实体
    pub fn destroyEntity(self: *ScriptContext, target: EntityId) void {
        self.world.destroyEntity(target);
    }

    /// 打印日志
    pub fn log(self: *ScriptContext, message: []const u8) void {
        std.log.info("[Script:{d}] {s}", .{ self.entity, message });
    }

    /// 打印警告
    pub fn warn(self: *ScriptContext, message: []const u8) void {
        std.log.warn("[Script:{d}] {s}", .{ self.entity, message });
    }

    /// 打印错误
    pub fn error(self: *ScriptContext, message: []const u8) void {
        std.log.err("[Script:{d}] {s}", .{ self.entity, message });
    }

    /// 获取用户数据指针
    pub fn getUserData(self: *ScriptContext, comptime T: type) ?*T {
        return @as(?*T, @ptrCast(self.instance.user_data));
    }

    /// 设置用户数据指针
    pub fn setUserData(self: *ScriptContext, data: *anyopaque) void {
        self.instance.user_data = data;
    }
};

// 扩展 Entity 添加 hasComponent 和 getComponent 方法
pub fn entityHasComponent(entity: *world_mod.Entity, comptime T: type) bool {
    const type_name = @typeName(T);
    return if (comptime std.mem.eql(u8, type_name, "components.Transform")) true
    else if (comptime std.mem.eql(u8, type_name, "components.Camera")) entity.camera != null
    else if (comptime std.mem.eql(u8, type_name, "components.Mesh")) entity.mesh != null
    else if (comptime std.mem.eql(u8, type_name, "components.SkinnedMesh")) entity.skinned_mesh != null
    else if (comptime std.mem.eql(u8, type_name, "components.Animator")) entity.animator != null
    else if (comptime std.mem.eql(u8, type_name, "components.Rigidbody")) entity.rigidbody != null
    else if (comptime std.mem.eql(u8, type_name, "components.BoxCollider")) entity.box_collider != null
    else if (comptime std.mem.eql(u8, type_name, "components.SphereCollider")) entity.sphere_collider != null
    else if (comptime std.mem.eql(u8, type_name, "components.MeshCollider")) entity.mesh_collider != null
    else if (comptime std.mem.eql(u8, type_name, "components.Material")) entity.material != null
    else if (comptime std.mem.eql(u8, type_name, "components.Light")) entity.light != null
    else if (comptime std.mem.eql(u8, type_name, "components.Vfx")) entity.vfx != null
    else if (comptime std.mem.eql(u8, type_name, "script.types.Script")) entity.script != null
    else false;
}

pub fn entityGetComponent(entity: *world_mod.Entity, comptime T: type) ?*T {
    const type_name = @typeName(T);
    return if (comptime std.mem.eql(u8, type_name, "components.Transform"))
        &entity.local_transform
    else if (comptime std.mem.eql(u8, type_name, "components.Camera"))
        @ptrCast(entity.camera)
    else if (comptime std.mem.eql(u8, type_name, "components.Mesh"))
        @ptrCast(entity.mesh)
    else if (comptime std.mem.eql(u8, type_name, "components.SkinnedMesh"))
        @ptrCast(entity.skinned_mesh)
    else if (comptime std.mem.eql(u8, type_name, "components.Animator"))
        @ptrCast(entity.animator)
    else if (comptime std.mem.eql(u8, type_name, "components.Rigidbody"))
        @ptrCast(entity.rigidbody)
    else if (comptime std.mem.eql(u8, type_name, "components.BoxCollider"))
        @ptrCast(entity.box_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.SphereCollider"))
        @ptrCast(entity.sphere_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.MeshCollider"))
        @ptrCast(entity.mesh_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.Material"))
        @ptrCast(entity.material)
    else if (comptime std.mem.eql(u8, type_name, "components.Light"))
        @ptrCast(entity.light)
    else if (comptime std.mem.eql(u8, type_name, "components.Vfx"))
        @ptrCast(entity.vfx)
    else if (comptime std.mem.eql(u8, type_name, "script.types.Script"))
        @ptrCast(entity.script)
    else null;
}
