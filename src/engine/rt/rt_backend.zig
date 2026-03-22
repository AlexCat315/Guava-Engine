//! RT 后端公共类型定义
//!
//! 定义光线追踪后端共用的数据结构，保证 Zig ↔ C/ObjC++ 的内存布局一致。
//! 各平台后端 (Metal / Vulkan / DX12) 均实现相同接口：
//!   init() -> ?Self
//!   isSupported(*const Self) -> bool
//!   buildAccelerationStructure(*Self, []const RtTriangle) -> bool
//!   traceRays(*Self, *const RtParams, []u8) -> bool
//!   deinit(*Self) -> void

const builtin = @import("builtin");

pub const MetalRtBackend = @import("rt_metal.zig").MetalRtBackend;

/// 后端类型标识
pub const RtBackendType = enum {
    metal,
    vulkan,
    dx12,
    cpu,
};

/// 编译期根据目标平台自动选择的硬件 RT 后端。
/// macOS → Metal RT, Windows → (未来) Vulkan/DX12 RT, Linux → (未来) Vulkan RT。
/// 目前仅 macOS Metal 已实现；其他平台返回 null (回退到 CPU 路径追踪)。
pub const HardwareRtBackend = switch (builtin.os.tag) {
    .macos => MetalRtBackend,
    // TODO: .windows => VulkanRtBackend 或 Dx12RtBackend,
    // TODO: .linux   => VulkanRtBackend,
    else => MetalRtBackend, // stub — init() always returns null
};

/// 返回当前编译目标的 RT 后端名称 (用于 UI 显示)。
pub fn backendName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "Metal RT",
        .windows => "Vulkan RT", // 占位
        .linux => "Vulkan RT", // 占位
        else => "CPU",
    };
}

/// 光追三角形 — 与 C 桥接层 GuavaRTTriangle 完全对齐 (extern struct)。
pub const RtTriangle = extern struct {
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
    n0: [3]f32,
    n1: [3]f32,
    n2: [3]f32,
    albedo: [3]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
};

/// 光追渲染参数 — 与 C 桥接层 GuavaRTParams 完全对齐 (extern struct)。
pub const RtParams = extern struct {
    inv_view_projection: [16]f32,
    camera_origin: [3]f32,
    _pad0: f32 = 0,
    light_direction: [3]f32,
    _pad1: f32 = 0,
    width: u32,
    height: u32,
    samples: u32,
    bounces: u32,
};
