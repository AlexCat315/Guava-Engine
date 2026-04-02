//! Guava Engine 脚本 API
//!
//! 用户脚本通过 @import("guava") 获取此模块。
//! 提供实体操作、输入查询、物理、日志等引擎 API。
//!
//! 用法示例：
//!   const guava = @import("guava");
//!
//!   export fn guava_on_update(dt: f32) callconv(.c) void {
//!       var pos = guava.getPosition();
//!       if (guava.isKeyDown(.w)) pos[2] -= 5.0 * dt;
//!       guava.setPosition(pos);
//!   }

const std = @import("std");

// ---------------------------------------------------------------------------
// Host API 函数表（C ABI，与引擎侧定义完全一致）
// ---------------------------------------------------------------------------

pub const HostApi = extern struct {
    // Logging
    log_fn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    // Entity
    get_entity_id: *const fn (?*anyopaque) callconv(.c) u64,
    find_entity_by_name: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u64,
    spawn_entity: *const fn (?*anyopaque) callconv(.c) u64,
    destroy_entity: *const fn (?*anyopaque, u64) callconv(.c) void,
    // Transform
    get_position: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_position: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,
    get_rotation: *const fn (?*anyopaque, *f32, *f32, *f32, *f32) callconv(.c) void,
    set_rotation: *const fn (?*anyopaque, f32, f32, f32, f32) callconv(.c) void,
    get_scale: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_scale: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,
    // Input
    is_key_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_released: *const fn (?*anyopaque, u32) callconv(.c) u32,
    is_mouse_button_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_mouse_position: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    // Time
    get_delta_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_time: *const fn (?*anyopaque) callconv(.c) f32,
    // Scene
    load_scene: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
};

// ---------------------------------------------------------------------------
// 模块级别状态（每次回调前由引擎通过 guava_bind 设置）
// ---------------------------------------------------------------------------

var api: *const HostApi = undefined;
var ctx: ?*anyopaque = null;
var bound_entity: u64 = 0;

/// 引擎在每次回调前调用此函数注入 API 与上下文
export fn guava_bind(host_api: *const HostApi, host_ctx: ?*anyopaque, entity_id: u64) callconv(.c) void {
    api = host_api;
    ctx = host_ctx;
    bound_entity = entity_id;
}

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

pub const Vec3 = [3]f32;
pub const Quat = [4]f32;

pub const Key = enum(u32) {
    w = 0,
    a = 1,
    s = 2,
    d = 3,
    b = 4,
    i = 5,
    m = 6,
    q = 7,
    e = 8,
    f = 9,
    g = 10,
    r = 11,
    t = 12,
    n = 13,
    tab = 14,
    delete = 15,
    backspace = 16,
    one = 17,
    two = 18,
    three = 19,
    l = 20,
    o = 21,
    p = 22,
    x = 23,
    y = 24,
    z = 25,
    period = 26,
    shift = 27,
    ctrl = 28,
    alt = 29,
    space = 30,
    escape = 31,
    up = 32,
    down = 33,
    left = 34,
    right = 35,
    f1 = 36,
    f2 = 37,
    f3 = 38,
    f4 = 39,
    f5 = 40,
    f6 = 41,
    f7 = 42,
    f8 = 43,
    f9 = 44,
    f10 = 45,
    f11 = 46,
    f12 = 47,
};

pub const MouseButton = enum(u32) {
    left = 0,
    right = 1,
    middle = 2,
};

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

/// 当前脚本绑定的实体 ID
pub fn entityId() u64 {
    return bound_entity;
}

/// 打印日志
pub fn log(msg: []const u8) void {
    api.log_fn(ctx, msg.ptr, msg.len);
}

/// 通过名称查找实体，未找到返回 0
pub fn findEntityByName(name: []const u8) u64 {
    return api.find_entity_by_name(ctx, name.ptr, name.len);
}

/// 创建新实体，返回实体 ID
pub fn spawnEntity() u64 {
    return api.spawn_entity(ctx);
}

/// 销毁实体
pub fn destroyEntity(id: u64) void {
    api.destroy_entity(ctx, id);
}

/// 获取当前实体（或指定实体）的本地位置
pub fn getPosition() Vec3 {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api.get_position(ctx, &x, &y, &z);
    return .{ x, y, z };
}

/// 设置当前实体的本地位置
pub fn setPosition(pos: Vec3) void {
    api.set_position(ctx, pos[0], pos[1], pos[2]);
}

/// 获取当前实体的旋转（四元数 xyzw）
pub fn getRotation() Quat {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    var w: f32 = 1;
    api.get_rotation(ctx, &x, &y, &z, &w);
    return .{ x, y, z, w };
}

/// 设置当前实体的旋转（四元数 xyzw）
pub fn setRotation(rot: Quat) void {
    api.set_rotation(ctx, rot[0], rot[1], rot[2], rot[3]);
}

/// 获取当前实体的缩放
pub fn getScale() Vec3 {
    var x: f32 = 1;
    var y: f32 = 1;
    var z: f32 = 1;
    api.get_scale(ctx, &x, &y, &z);
    return .{ x, y, z };
}

/// 设置当前实体的缩放
pub fn setScale(scale: Vec3) void {
    api.set_scale(ctx, scale[0], scale[1], scale[2]);
}

/// 查询按键是否当前按下
pub fn isKeyDown(key: Key) bool {
    return api.is_key_down(ctx, @intFromEnum(key)) != 0;
}

/// 查询按键是否刚按下（本帧边沿）
pub fn wasKeyPressed(key: Key) bool {
    return api.was_key_pressed(ctx, @intFromEnum(key)) != 0;
}

/// 查询按键是否刚释放（本帧边沿）
pub fn wasKeyReleased(key: Key) bool {
    return api.was_key_released(ctx, @intFromEnum(key)) != 0;
}

/// 查询鼠标按钮是否按下
pub fn isMouseButtonDown(button: MouseButton) bool {
    return api.is_mouse_button_down(ctx, @intFromEnum(button)) != 0;
}

/// 获取鼠标位置
pub fn getMousePosition() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    api.get_mouse_position(ctx, &x, &y);
    return .{ x, y };
}

/// 获取帧间隔时间（秒）
pub fn deltaTime() f32 {
    return api.get_delta_time(ctx);
}

/// 获取游戏运行总时间（秒）
pub fn time() f32 {
    return api.get_time(ctx);
}

/// 加载场景
pub fn loadScene(path: []const u8) void {
    api.load_scene(ctx, path.ptr, path.len);
}
