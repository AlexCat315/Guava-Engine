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
    LayoutMismatch,
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

pub const DepthStencilState = struct {
    depth_compare: rhi_types.CompareOp = .less,
    depth_write: bool = true,
};

pub const VertexAttribute = struct {
    location: u32,
    format: rhi_types.VertexElementFormat,
    offset: u32,
    buffer_index: u32 = 0,
};

pub const VertexBufferLayout = struct {
    stride: u32,
    step_rate: rhi_types.VertexInputRate = .per_vertex,
};

pub const VertexLayoutDesc = struct {
    attributes: []const VertexAttribute,
    buffer_layouts: []const VertexBufferLayout,
};

pub const GraphicsPipelineDesc = struct {
    layout: PipelineLayout,
    vertex: ShaderModule,
    fragment: ShaderModule,
    color_format: rhi_types.TextureFormat,
    depth_format: ?rhi_types.TextureFormat = .d32_float,
    primitive: rhi_types.PrimitiveType = .triangle_list,
    depth_stencil: ?DepthStencilState = .{},
    vertex_layout: ?VertexLayoutDesc = null,
    blend_state: ?rhi_types.ColorTargetBlendState = null,
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
    create_shader_module: *const fn (ctx: *anyopaque, desc: ShaderModuleDesc) Error!ShaderModule,
    create_graphics_pipeline: *const fn (ctx: *anyopaque, desc: GraphicsPipelineDesc) Error!GraphicsPipeline,
    create_compute_pipeline: *const fn (ctx: *anyopaque, desc: ComputePipelineDesc) Error!ComputePipeline,
    destroy_graphics_pipeline: *const fn (ctx: *anyopaque, pipeline: GraphicsPipeline) void,
    destroy_compute_pipeline: *const fn (ctx: *anyopaque, pipeline: ComputePipeline) void,
    create_sampler: *const fn (ctx: *anyopaque, desc: SamplerDesc) Error!Sampler,
    destroy_sampler: *const fn (ctx: *anyopaque, sampler: Sampler) void,
    upload_buffer_data: *const fn (ctx: *anyopaque, buffer: Buffer, offset: u64, data: []const u8) Error!void,
    upload_texture_data: ?*const fn (ctx: *anyopaque, texture: Texture, data: []const u8, width: u32, height: u32, bytes_per_row: u32) Error!void = null,
    read_texture_data: ?*const fn (ctx: *anyopaque, texture: Texture, width: u32, height: u32, bytes_per_row: u32, out_data: []u8) Error!void = null,
    register_binding_set: ?*const fn (ctx: *anyopaque, set_id: u32, layout_entries: []const BindingLayoutEntry, set_entries: []const BindingSetEntry) void = null,
};

pub const Device = struct {
    ctx: *anyopaque,
    vtable: *const DeviceVTable,
    capabilities: Capabilities,
    pipeline_layout_cache: binding_cache.PipelineLayoutCache,
    binding_set_cache: binding_cache.BindingSetCache,
    binding_layout_descs: std.AutoHashMap(u32, []BindingLayoutEntry),
    pipeline_layout_sets: std.AutoHashMap(u32, []u32),
    binding_set_layouts: std.AutoHashMap(u32, u32),
    next_binding_layout_id: u32 = 1,
    prev_frame_stats: binding_cache.BindingSetCacheStats = .{},

    pub fn initWithCache(ctx: *anyopaque, vtable: *const DeviceVTable, capabilities: Capabilities, allocator: std.mem.Allocator) Device {
        return .{
            .ctx = ctx,
            .vtable = vtable,
            .capabilities = capabilities,
            .pipeline_layout_cache = binding_cache.PipelineLayoutCache.init(allocator),
            .binding_set_cache = binding_cache.BindingSetCache.init(allocator),
            .binding_layout_descs = std.AutoHashMap(u32, []BindingLayoutEntry).init(allocator),
            .pipeline_layout_sets = std.AutoHashMap(u32, []u32).init(allocator),
            .binding_set_layouts = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *Device) void {
        var layout_it = self.binding_layout_descs.iterator();
        while (layout_it.next()) |entry| {
            self.pipeline_layout_cache.allocator.free(entry.value_ptr.*);
        }

        var pl_it = self.pipeline_layout_sets.iterator();
        while (pl_it.next()) |entry| {
            self.pipeline_layout_cache.allocator.free(entry.value_ptr.*);
        }

        self.binding_set_layouts.deinit();
        self.pipeline_layout_sets.deinit();
        self.binding_layout_descs.deinit();
        self.binding_set_cache.deinit();
        self.pipeline_layout_cache.deinit();
    }

    pub fn createBindingLayout(self: *Device, desc: BindingLayoutDesc) Error!BindingLayout {
        if (desc.entries.len == 0) return error.InvalidArgument;

        const id = self.next_binding_layout_id;
        self.next_binding_layout_id += 1;

        const copied = self.pipeline_layout_cache.allocator.dupe(BindingLayoutEntry, desc.entries) catch return error.OutOfMemory;
        self.binding_layout_descs.put(id, copied) catch return error.OutOfMemory;

        return .{ .id = id };
    }

    pub fn createBindingSetCached(self: *Device, layout: BindingLayout, desc: BindingSetDesc) Error!BindingSet {
        const layout_entries = self.binding_layout_descs.get(layout.id) orelse return error.InvalidArgument;
        try self.validateBindingSetDesc(layout_entries, desc);

        const key_hash = hashBindingSet(layout.id, desc.entries);
        if (self.binding_set_cache.getByHash(key_hash)) |id| {
            return .{ .id = id };
        }

        const id = self.binding_set_cache.nextSyntheticId();
        self.binding_set_cache.putByHash(key_hash, id) catch return error.OutOfMemory;
        self.binding_set_layouts.put(id, layout.id) catch return error.OutOfMemory;

        // Notify backend so it can map set_id → real GPU resources
        if (self.vtable.register_binding_set) |reg_fn| {
            reg_fn(self.ctx, id, layout_entries, desc.entries);
        }

        return .{ .id = id };
    }

    pub fn validateBindingSetForPipelineSlot(self: *const Device, pipeline_layout: PipelineLayout, slot: u32, binding_set: BindingSet) Error!void {
        const layout_ids = self.pipeline_layout_sets.get(pipeline_layout.id) orelse return error.InvalidArgument;
        if (slot >= layout_ids.len) return error.LayoutMismatch;

        const expected_layout_id = layout_ids[slot];
        const actual_layout_id = self.binding_set_layouts.get(binding_set.id) orelse return error.InvalidArgument;
        if (expected_layout_id != actual_layout_id) return error.LayoutMismatch;
    }

    pub fn bindingSetCacheStats(self: *const Device) binding_cache.BindingSetCacheStats {
        return self.binding_set_cache.stats;
    }

    pub fn resetBindingSetCacheStats(self: *Device) void {
        self.binding_set_cache.resetStats();
        self.prev_frame_stats = .{};
    }

    /// Snapshot current stats as the previous frame baseline and return the delta.
    pub fn snapshotFrameStats(self: *Device) binding_cache.BindingSetCacheStats {
        const current = self.binding_set_cache.stats;
        const d = current.delta(self.prev_frame_stats);
        self.prev_frame_stats = current;
        return d;
    }

    pub fn bindingSetCacheEntryCount(self: *const Device) u32 {
        return self.binding_set_cache.entryCount();
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

    pub fn createShaderModule(self: *const Device, desc: ShaderModuleDesc) Error!ShaderModule {
        return self.vtable.create_shader_module(self.ctx, desc);
    }

    pub fn createGraphicsPipeline(self: *const Device, desc: GraphicsPipelineDesc) Error!GraphicsPipeline {
        return self.vtable.create_graphics_pipeline(self.ctx, desc);
    }

    pub fn createComputePipeline(self: *const Device, desc: ComputePipelineDesc) Error!ComputePipeline {
        return self.vtable.create_compute_pipeline(self.ctx, desc);
    }

    pub fn destroyGraphicsPipeline(self: *const Device, pipeline: GraphicsPipeline) void {
        self.vtable.destroy_graphics_pipeline(self.ctx, pipeline);
    }

    pub fn destroyComputePipeline(self: *const Device, pipeline: ComputePipeline) void {
        self.vtable.destroy_compute_pipeline(self.ctx, pipeline);
    }

    pub fn createSampler(self: *const Device, desc: SamplerDesc) Error!Sampler {
        return self.vtable.create_sampler(self.ctx, desc);
    }

    pub fn destroySampler(self: *const Device, sampler: Sampler) void {
        self.vtable.destroy_sampler(self.ctx, sampler);
    }

    pub fn uploadBufferData(self: *const Device, buffer: Buffer, offset: u64, data: []const u8) Error!void {
        return self.vtable.upload_buffer_data(self.ctx, buffer, offset, data);
    }

    pub fn uploadTextureData(self: *const Device, texture: Texture, data: []const u8, width: u32, height: u32, bytes_per_row: u32) Error!void {
        const func = self.vtable.upload_texture_data orelse return error.UnsupportedFeature;
        return func(self.ctx, texture, data, width, height, bytes_per_row);
    }

    pub fn readTextureData(self: *const Device, texture: Texture, width: u32, height: u32, bytes_per_row: u32, out_data: []u8) Error!void {
        const func = self.vtable.read_texture_data orelse return error.UnsupportedFeature;
        return func(self.ctx, texture, width, height, bytes_per_row, out_data);
    }

    pub fn resolvePipelineLayout(
        self: *Device,
        binding_layouts: []const BindingLayout,
    ) Error!PipelineLayout {
        if (binding_layouts.len == 0) return error.InvalidArgument;

        var ids = std.ArrayList(u32).empty;
        defer ids.deinit(self.pipeline_layout_cache.allocator);
        for (binding_layouts) |layout| {
            if (!self.binding_layout_descs.contains(layout.id)) return error.InvalidArgument;
            ids.append(self.pipeline_layout_cache.allocator, layout.id) catch return error.OutOfMemory;
        }

        if (self.pipeline_layout_cache.get(ids.items)) |id| {
            return .{ .id = id };
        }

        const id = self.pipeline_layout_cache.nextSyntheticId();
        try self.pipeline_layout_cache.put(ids.items, id);
        const copied_layout_ids = self.pipeline_layout_cache.allocator.dupe(u32, ids.items) catch return error.OutOfMemory;
        self.pipeline_layout_sets.put(id, copied_layout_ids) catch return error.OutOfMemory;
        return .{ .id = id };
    }

    fn validateBindingSetDesc(self: *const Device, layout_entries: []const BindingLayoutEntry, desc: BindingSetDesc) Error!void {
        _ = self;
        if (desc.entries.len != layout_entries.len) return error.LayoutMismatch;

        for (layout_entries) |layout_entry| {
            const binding_entry = findBindingEntry(desc.entries, layout_entry.slot) orelse return error.LayoutMismatch;
            if (!resourceMatchesBindingType(binding_entry.resource, layout_entry.binding_type)) {
                return error.LayoutMismatch;
            }
        }
    }
};

fn findBindingEntry(entries: []const BindingSetEntry, slot: u32) ?BindingSetEntry {
    for (entries) |entry| {
        if (entry.slot == slot) return entry;
    }
    return null;
}

fn resourceMatchesBindingType(resource: BindingResource, binding_type: BindingType) bool {
    return switch (resource) {
        .sampler => binding_type == .sampler,
        .texture => binding_type == .texture,
        .storage_texture => binding_type == .storage_texture,
        .uniform_buffer => binding_type == .uniform_buffer,
        .storage_buffer => binding_type == .storage_buffer,
        .accel_structure => binding_type == .accel_structure,
    };
}

fn hashBindingSet(layout_id: u32, entries: []const BindingSetEntry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&layout_id));
    for (entries) |entry| {
        h.update(std.mem.asBytes(&entry.slot));
        const tag: u8 = @intFromEnum(std.meta.activeTag(entry.resource));
        h.update(std.mem.asBytes(&tag));
        const rid: u32 = switch (entry.resource) {
            .sampler => |r| r.id,
            .texture => |r| r.id,
            .storage_texture => |r| r.id,
            .uniform_buffer => |r| r.id,
            .storage_buffer => |r| r.id,
            .accel_structure => |r| r.id,
        };
        h.update(std.mem.asBytes(&rid));
    }
    return h.final();
}

pub const CommandBuffer = command_buffer.CommandBuffer;
pub const CommandDecoder = command_buffer.Decoder;
pub const OpCode = command_buffer.OpCode;
pub const StateTracker = state_tracker.StateTracker;

test "binding set cache returns stable id for same layout/resources" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });

    const tex = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(tex);

    const set_a = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });
    const set_b = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });

    try std.testing.expectEqual(set_a.id, set_b.id);
}

test "pipeline layout binding slot validation catches mismatched layout" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout_a = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });
    const layout_b = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .uniform_buffer,
            .stage = .fragment,
        }},
    });

    const pipeline_layout = try device.resolvePipelineLayout(&.{layout_a});
    const buf = try device.createBuffer(.{
        .size = 64,
        .usage = .{ .uniform = true },
    });
    defer device.destroyBuffer(buf);

    const bad_set = try device.createBindingSetCached(layout_b, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = buf } }},
    });

    try std.testing.expectError(error.LayoutMismatch, device.validateBindingSetForPipelineSlot(pipeline_layout, 0, bad_set));
}
