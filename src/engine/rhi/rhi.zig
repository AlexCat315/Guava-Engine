const std = @import("std");
const command_buffer = @import("command_buffer.zig");
const queue_mod = @import("queue.zig");
const state_tracker = @import("state_tracker.zig");
const binding_cache = @import("binding_cache.zig");
const rhi_types = @import("types.zig");

pub const Error = error{
    UnsupportedBackend,
    UnsupportedFeature,
    InvalidArgument,
    OutOfMemory,
    SwapchainAcquireFailed,
    SubmitFailed,
    PresentFailed,
};

pub const QueueClass = queue_mod.QueueClass;
pub const Queue = queue_mod.Queue;
pub const SubmitDesc = queue_mod.SubmitDesc;
pub const TimelineSemaphore = queue_mod.TimelineSemaphore;

pub const ResourceStates = state_tracker.ResourceStates;
pub const Barrier = state_tracker.Barrier;
pub const ResourceRef = state_tracker.ResourceRef;

pub const Buffer = struct { id: u32 };
pub const Texture = struct { id: u32 };
pub const Sampler = struct { id: u32 };
pub const ShaderModule = struct { id: u32 };
pub const BindingLayout = struct { id: u32 };
pub const BindingSet = struct { id: u32 };
pub const PipelineLayout = struct { id: u32 };
pub const GraphicsPipeline = struct { id: u32 };
pub const ComputePipeline = struct { id: u32 };
pub const AccelStructure = struct { id: u32 };
pub const SwapchainImage = struct { id: u32, width: u32, height: u32 };

pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsageFlags,
    label: ?[]const u8 = null,
};

pub const BufferUsageFlags = packed struct(u32) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage_read: bool = false,
    storage_write: bool = false,
    indirect: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u24 = 0,

    pub fn bits(self: BufferUsageFlags) u32 {
        return @bitCast(self);
    }
};

pub const TextureDimension = enum {
    d2,
    d3,
    cube,
    array,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
    layers: u32 = 1,
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
    format: rhi_types.TextureFormat,
    usage: TextureUsageFlags,
    dimension: TextureDimension = .d2,
    label: ?[]const u8 = null,
};

pub const TextureUsageFlags = packed struct(u32) {
    sampled: bool = false,
    color_target: bool = false,
    depth_stencil_target: bool = false,
    storage_read: bool = false,
    storage_write: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    present: bool = false,
    _padding: u24 = 0,

    pub fn bits(self: TextureUsageFlags) u32 {
        return @bitCast(self);
    }
};

pub const SamplerDesc = struct {
    min_filter: rhi_types.SamplerFilter = .linear,
    mag_filter: rhi_types.SamplerFilter = .linear,
    mipmap_mode: rhi_types.SamplerMipmapMode = .linear,
    address_mode_u: rhi_types.SamplerAddressMode = .repeat,
    address_mode_v: rhi_types.SamplerAddressMode = .repeat,
    address_mode_w: rhi_types.SamplerAddressMode = .repeat,
};

pub const ShaderModuleDesc = struct {
    stage: rhi_types.ShaderStage,
    format: rhi_types.ShaderFormat,
    code: []const u8,
    entry_point: [:0]const u8 = "main",
};

pub const BindingType = enum {
    sampler,
    texture,
    storage_texture,
    uniform_buffer,
    storage_buffer,
    accel_structure,
};

pub const BindingLayoutEntry = struct {
    slot: u32,
    binding_type: BindingType,
    stage: rhi_types.ShaderStage,
    array_size: u32 = 1,
};

pub const BindingLayoutDesc = struct {
    entries: []const BindingLayoutEntry,
    label: ?[]const u8 = null,
};

pub const BindingResource = union(enum) {
    sampler: Sampler,
    texture: Texture,
    storage_texture: Texture,
    uniform_buffer: Buffer,
    storage_buffer: Buffer,
    accel_structure: AccelStructure,
};

pub const BindingSetEntry = struct {
    slot: u32,
    resource: BindingResource,
};

pub const BindingSetDesc = struct {
    entries: []const BindingSetEntry,
    label: ?[]const u8 = null,
};

pub const PipelineLayoutDesc = struct {
    set_layouts: []const BindingLayout,
    label: ?[]const u8 = null,
};

pub const GraphicsPipelineDesc = struct {
    layout: PipelineLayout,
    vertex: ShaderModule,
    fragment: ShaderModule,
    color_format: rhi_types.TextureFormat,
    depth_format: ?rhi_types.TextureFormat = .d32_float,
    primitive: rhi_types.PrimitiveType = .triangle_list,
};

pub const ComputePipelineDesc = struct {
    layout: PipelineLayout,
    shader: ShaderModule,
};

pub const DrawIndexedArgs = struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

pub const BarrierDesc = struct {
    barriers: []const Barrier,
};

pub const RenderPassDesc = struct {
    color_target: ?Texture = null,
    depth_target: ?Texture = null,
};

pub const AccelStructureDesc = struct {
    max_geometry_count: u32,
    label: ?[]const u8 = null,
};

pub const RtPipelineState = struct {
    id: u32,
};

pub const Capabilities = struct {
    compute: bool,
    ray_tracing: bool,
    indirect_draw: bool,
    mesh_shaders: bool,
    texture_3d: bool,
    texture_cube_native: bool,
    max_queues: [3]u8,
};

pub const DeviceVTable = struct {
    create_buffer: *const fn (ctx: *anyopaque, desc: BufferDesc) Error!Buffer,
    create_texture: *const fn (ctx: *anyopaque, desc: TextureDesc) Error!Texture,
    destroy_buffer: *const fn (ctx: *anyopaque, buffer: Buffer) void,
    destroy_texture: *const fn (ctx: *anyopaque, texture: Texture) void,
    create_command_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Error!command_buffer.CommandBuffer,
    acquire_swapchain_image: *const fn (ctx: *anyopaque) Error!SwapchainImage,
    submit_command_buffer: *const fn (ctx: *anyopaque, queue: QueueClass, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) Error!void,
    present: *const fn (ctx: *anyopaque, image: SwapchainImage) Error!void,
    get_queue: *const fn (ctx: *anyopaque, class: QueueClass) Error!Queue,
};

pub const Device = struct {
    ctx: *anyopaque,
    vtable: *const DeviceVTable,
    capabilities: Capabilities,
    pipeline_layout_cache: binding_cache.PipelineLayoutCache,

    pub fn initWithCache(ctx: *anyopaque, vtable: *const DeviceVTable, capabilities: Capabilities, allocator: std.mem.Allocator) Device {
        return .{
            .ctx = ctx,
            .vtable = vtable,
            .capabilities = capabilities,
            .pipeline_layout_cache = binding_cache.PipelineLayoutCache.init(allocator),
        };
    }

    pub fn deinit(self: *Device) void {
        self.pipeline_layout_cache.deinit();
    }

    pub fn createBuffer(self: *const Device, desc: BufferDesc) Error!Buffer {
        return self.vtable.create_buffer(self.ctx, desc);
    }

    pub fn createTexture(self: *const Device, desc: TextureDesc) Error!Texture {
        return self.vtable.create_texture(self.ctx, desc);
    }

    pub fn destroyBuffer(self: *const Device, buffer: Buffer) void {
        self.vtable.destroy_buffer(self.ctx, buffer);
    }

    pub fn destroyTexture(self: *const Device, texture: Texture) void {
        self.vtable.destroy_texture(self.ctx, texture);
    }

    pub fn createCommandBuffer(self: *const Device, allocator: std.mem.Allocator) Error!command_buffer.CommandBuffer {
        return self.vtable.create_command_buffer(self.ctx, allocator);
    }

    pub fn acquireSwapchainImage(self: *const Device) Error!SwapchainImage {
        return self.vtable.acquire_swapchain_image(self.ctx);
    }

    pub fn submitCommandBuffer(self: *const Device, queue_class: QueueClass, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) Error!void {
        return self.vtable.submit_command_buffer(self.ctx, queue_class, cmd, desc);
    }

    pub fn present(self: *const Device, image: SwapchainImage) Error!void {
        return self.vtable.present(self.ctx, image);
    }

    pub fn getQueue(self: *const Device, class: QueueClass) Error!Queue {
        return self.vtable.get_queue(self.ctx, class);
    }

    pub fn resolvePipelineLayout(
        self: *Device,
        binding_layouts: []const BindingLayout,
    ) Error!PipelineLayout {
        var ids = std.ArrayList(u32).init(self.pipeline_layout_cache.allocator);
        defer ids.deinit();
        for (binding_layouts) |layout| {
            try ids.append(layout.id);
        }

        if (self.pipeline_layout_cache.get(ids.items)) |id| {
            return .{ .id = id };
        }

        const id = self.pipeline_layout_cache.nextSyntheticId();
        try self.pipeline_layout_cache.put(ids.items, id);
        return .{ .id = id };
    }
};

pub const CommandBuffer = command_buffer.CommandBuffer;
pub const CommandDecoder = command_buffer.Decoder;
pub const OpCode = command_buffer.OpCode;
pub const StateTracker = state_tracker.StateTracker;
