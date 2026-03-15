const std = @import("std");

pub const GraphicsAPI = enum {
    vulkan,
    metal,
    dx12,
};

pub const ShaderFormat = enum {
    spirv,
    dxil,
    msl,
};

pub const ShaderStage = enum {
    vertex,
    fragment,
};

pub const PrimitiveType = enum {
    triangle_list,
    triangle_strip,
    line_list,
    line_strip,
    point_list,
};

pub const FillMode = enum {
    fill,
    line,
};

pub const CullMode = enum {
    none,
    front,
    back,
};

pub const FrontFace = enum {
    counter_clockwise,
    clockwise,
};

pub const CompareOp = enum {
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,
};

pub const SamplerFilter = enum {
    nearest,
    linear,
};

pub const SamplerMipmapMode = enum {
    nearest,
    linear,
};

pub const SamplerAddressMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
};

pub const VertexInputRate = enum {
    per_vertex,
    per_instance,
};

pub const VertexElementFormat = enum {
    float2,
    float3,
    float4,
};

pub const IndexElementSize = enum {
    u16,
    u32,
};

pub const BackendSelectionPolicy = enum {
    explicit_order,
    platform_default,
};

pub const DeviceConfig = struct {
    preferred_backends: []const GraphicsAPI = &.{ .vulkan, .dx12, .metal },
    selection_policy: BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
    prefer_low_power: bool = false,
};

pub const TextureFormat = enum {
    unknown,
    bgra8_unorm,
    bgra8_unorm_srgb,
    d24_unorm,
    d24_unorm_s8_uint,
    d32_float,
};

pub const BufferUsage = struct {
    pub const vertex: u32 = 1 << 0;
    pub const index: u32 = 1 << 1;
    pub const indirect: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
};

pub const TextureUsage = struct {
    pub const sampler: u32 = 1 << 0;
    pub const color_target: u32 = 1 << 1;
    pub const depth_stencil_target: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
    pub const compute_storage_rw: u32 = 1 << 6;
};

pub const BufferDesc = struct {
    size: u32,
    usage: u32,
    label: ?[]const u8 = null,
};

pub const TransferBufferDesc = struct {
    size: u32,
    upload: bool = true,
    label: ?[]const u8 = null,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: u32,
    sample_count: u32 = 1,
    label: ?[]const u8 = null,
};

pub const ClearState = struct {
    color: [4]f32 = .{ 0.07, 0.08, 0.12, 1.0 },
    depth: f32 = 1.0,
    stencil: u8 = 0,
};

pub const RuntimeInfo = struct {
    backend: GraphicsAPI = .metal,
    drawable_width: u32 = 0,
    drawable_height: u32 = 0,
    swapchain_format: TextureFormat = .unknown,
    depth_format: TextureFormat = .d32_float,
    has_depth: bool = false,
    driver_name: [64]u8 = [_]u8{0} ** 64,
    device_name: [256]u8 = [_]u8{0} ** 256,
    driver_info: [256]u8 = [_]u8{0} ** 256,

    pub fn deviceName(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.device_name[0..], 0) orelse self.device_name.len;
        return self.device_name[0..end];
    }

    pub fn driverName(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.driver_name[0..], 0) orelse self.driver_name.len;
        return self.driver_name[0..end];
    }

    pub fn driverInfo(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.driver_info[0..], 0) orelse self.driver_info.len;
        return self.driver_info[0..end];
    }
};

pub fn graphicsApiName(api: GraphicsAPI) []const u8 {
    return switch (api) {
        .vulkan => "Vulkan",
        .metal => "Metal",
        .dx12 => "DirectX 12",
    };
}
