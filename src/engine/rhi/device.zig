/// New RHI adapter layer - implements old device.zig API using new rhi.Device + CommandBuffer
/// This maintains backward compatibility with all 24 render pass files while using the new RHI internally.
const std = @import("std");
const builtin = @import("builtin");
const platform_mod = @import("../core/platform.zig");
const window_mod = @import("../platform/window.zig");
const sdl = @import("../platform/sdl.zig").c;
const types = @import("types.zig");
const rhi = @import("rhi.zig");
const command_buffer = @import("command_buffer.zig");
const metal_device_mod = @import("metal/metal_device.zig");
const metal_backend_mod = @import("metal/metal_backend.zig");

// Combined error set that includes both old and new RHI errors
pub const Error = error{
    // Device errors
    UnsupportedBackend,
    UnsupportedFeature,
    DeviceCreateFailed,
    WindowClaimFailed,
    FramesInFlightFailed,
    // Buffer/Resource errors
    CommandBufferAcquireFailed,
    CommandBufferCancelFailed,
    CommandBufferSubmitFailed,
    SwapchainAcquireFailed,
    RenderPassBeginFailed,
    FenceAcquireFailed,
    TextureCreateFailed,
    BufferCreateFailed,
    TransferBufferCreateFailed,
    ShaderCreateFailed,
    SamplerCreateFailed,
    PipelineCreateFailed,
    TransferBufferMapFailed,
    CopyPassBeginFailed,
    ComputePassBeginFailed,
    ComputePipelineCreateFailed,
    // RHI-specific errors (can occur during operation)
    InvalidArgument,
    LayoutMismatch,
    SubmitFailed,
    PresentFailed,
    OutOfMemory,
    // CommandBuffer encoding errors
    InvalidOpcode,
    TruncatedStream,
};

// ============================================================================
// PUBLIC TYPE DEFINITIONS - Kept for backward compatibility
// ============================================================================

pub const ShaderModuleDesc = struct {
    code: []const u8,
    stage: types.ShaderStage,
    format: types.ShaderFormat = .spirv,
    entry_point: [:0]const u8 = "main",
    num_samplers: u32 = 0,
    num_storage_textures: u32 = 0,
    num_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
};

pub const SamplerDesc = struct {
    min_filter: types.SamplerFilter = .linear,
    mag_filter: types.SamplerFilter = .linear,
    mipmap_mode: types.SamplerMipmapMode = .linear,
    address_mode_u: types.SamplerAddressMode = .repeat,
    address_mode_v: types.SamplerAddressMode = .repeat,
    address_mode_w: types.SamplerAddressMode = .repeat,
    mip_lod_bias: f32 = 0.0,
    max_anisotropy: f32 = 1.0,
    compare_op: types.CompareOp = .always,
    min_lod: f32 = 0.0,
    max_lod: f32 = 0.0,
    enable_anisotropy: bool = false,
    enable_compare: bool = false,
};

pub const VertexBufferLayoutDesc = struct {
    slot: u32 = 0,
    stride: u32,
    input_rate: types.VertexInputRate = .per_vertex,
};

pub const VertexAttributeDesc = struct {
    location: u32,
    buffer_slot: u32,
    format: types.VertexElementFormat,
    offset: u32,
};

// NEW: Resource types now hold u32 IDs instead of SDL pointers
pub const Buffer = struct {
    id: u32,
    desc: types.BufferDesc,
};

pub const TransferBuffer = struct {
    id: u32,
    desc: types.TransferBufferDesc,
};

pub const Texture = struct {
    id: u32,
    desc: types.TextureDesc,
};

pub const ShaderModule = struct {
    id: u32,
    desc: ShaderModuleDesc,
};

pub const Sampler = struct {
    id: u32,
    desc: SamplerDesc,
};

pub const GraphicsPipelineDesc = struct {
    vertex_shader: *const ShaderModule,
    fragment_shader: *const ShaderModule,
    vertex_buffer_layouts: []const VertexBufferLayoutDesc,
    vertex_attributes: []const VertexAttributeDesc,
    color_format: ?types.TextureFormat = null,
    blend_state: ?types.ColorTargetBlendState = null,
    depth_format: ?types.TextureFormat = .d32_float,
    primitive_type: types.PrimitiveType = .triangle_list,
    fill_mode: types.FillMode = .fill,
    cull_mode: types.CullMode = .back,
    front_face: types.FrontFace = .counter_clockwise,
    depth_compare: types.CompareOp = .less_or_equal,
    depth_test: bool = true,
    depth_write: bool = true,
};

pub const TextureSamplerBinding = struct {
    texture: *const Texture,
    sampler: *const Sampler,
};

pub const BindGroupDesc = struct {
    stage: types.ShaderStage,
    texture_sampler_bindings: []const TextureSamplerBinding = &.{},
    storage_buffers: []const *const Buffer = &.{},
    storage_textures: []const *const Texture = &.{},
    slot_offset: u32 = 0,
};

pub const GraphicsPipeline = struct {
    id: u32,
};

pub const ComputePipeline = struct {
    id: u32,
};

pub const ComputePipelineDesc = struct {
    code: []const u8,
    entry_point: [:0]const u8 = "main",
    format: types.ShaderFormat = .spirv,
    num_samplers: u32 = 0,
    num_readonly_storage_textures: u32 = 0,
    num_readonly_storage_buffers: u32 = 0,
    num_readwrite_storage_textures: u32 = 0,
    num_readwrite_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
    threadcount_x: u32 = 1,
    threadcount_y: u32 = 1,
    threadcount_z: u32 = 1,
};

pub const ComputePass = struct {
    reserved: u32 = 0, // Marker only; no actual state needed
};

pub const BindGroup = struct {
    stage: types.ShaderStage,
    // Converted binding IDs from descriptor
    texture_sampler_slots: []const u32, // texture IDs
    texture_sampler_samplers: []const u32, // sampler IDs
    storage_buffer_ids: []const u32,
    storage_texture_ids: []const u32,
    slot_offset: u32 = 0,
    layout: ?rhi.BindingLayout = null,
    set: ?rhi.BindingSet = null,
};

// NEW: Frame now holds swapchain_image ID instead of SDL command buffer
pub const Frame = struct {
    swapchain_image: rhi.SwapchainImage,
    command_buffer: command_buffer.CommandBuffer,
};

pub const RenderPass = struct {
    reserved: u32 = 0, // Marker only; render pass managed by command buffer
};

pub const CopyPass = struct {
    reserved: u32 = 0, // Marker only
};

pub const Fence = struct {
    reserved: u32 = 0, // STUB - not yet implemented in new RHI
};

pub const LoadOp = enum {
    load,
    clear,
    dont_care,
};

pub const StoreOp = enum {
    store,
    dont_care,
};

pub const ColorTarget = union(enum) {
    swapchain,
    texture: *const Texture,
};

pub const ColorAttachmentDesc = struct {
    target: ColorTarget = .swapchain,
    clear_color: [4]f32 = .{ 0.07, 0.08, 0.12, 1.0 },
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
};

pub const DepthAttachmentDesc = struct {
    texture: *const Texture,
    clear_depth: f32 = 1.0,
    clear_stencil: u8 = 0,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .dont_care,
    stencil_load_op: LoadOp = .dont_care,
    stencil_store_op: StoreOp = .dont_care,
};

pub const RenderPassDesc = struct {
    color: ColorAttachmentDesc = .{},
    depth: ?DepthAttachmentDesc = null,
};

/// Binding state tracker for avoiding redundant bindings
pub const BindGroupState = struct {
    last_bound_group: ?u64 = null,
    last_bound_pipeline: ?u64 = null,
    bound_vertex_buffers: [8]?u32 = .{null} ** 8,
    bound_index_buffer: ?u32 = null,

    pub fn reset(self: *BindGroupState) void {
        self.last_bound_group = null;
        self.last_bound_pipeline = null;
        self.bound_vertex_buffers = .{null} ** 8;
        self.bound_index_buffer = null;
    }
};
// NEW: Main device struct - now wraps rhi.Device instead of SDL
pub const RhiDevice = struct {
    allocator: std.mem.Allocator,
    device: *rhi.Device,
    api: types.GraphicsAPI = .metal,
    runtime_info: types.RuntimeInfo = .{},

    depth_texture: ?Texture = null,
    depth_textures: [3]?Texture = .{ null, null, null },
    current_depth_index: u32 = 0,
    frames_in_flight: u32 = 2,

    perf_stats: types.PerformanceStats = .{},
    bind_state: BindGroupState = .{},
    // Current frame state
    current_frame: ?Frame = null,
    default_binding_layout: ?rhi.BindingLayout = null,
    default_pipeline_layout: ?rhi.PipelineLayout = null,
    owned_device: bool = false,
    owned_metal_device: ?*metal_device_mod.MetalDevice = null,
    owned_mock_backend: ?*metal_backend_mod.MetalBackend = null,
    sdl_metal_view: sdl.SDL_MetalView = null,

    pub fn init(
        allocator: std.mem.Allocator,
        platform: platform_mod.Platform,
        window: *window_mod.Window,
        config: types.DeviceConfig,
    ) Error!RhiDevice {
        _ = platform;
        if (builtin.os.tag == .macos) {
            const md_ptr = allocator.create(metal_device_mod.MetalDevice) catch return error.OutOfMemory;
            errdefer allocator.destroy(md_ptr);

            const md = metal_device_mod.MetalDevice.init(allocator) orelse return error.DeviceCreateFailed;
            md_ptr.* = md;
            errdefer md_ptr.deinit();

            var metal_view: sdl.SDL_MetalView = null;
            metal_view = sdl.SDL_Metal_CreateView(window.handle);
            if (metal_view) |view| {
                if (sdl.SDL_Metal_GetLayer(view)) |layer| {
                    md_ptr.setLayer(layer);
                }
            }

            const dev_ptr = allocator.create(rhi.Device) catch return error.OutOfMemory;
            errdefer allocator.destroy(dev_ptr);
            dev_ptr.* = md_ptr.createDevice();

            var out = RhiDevice{
                .allocator = allocator,
                .device = dev_ptr,
                .api = .metal,
                .runtime_info = .{
                    .backend = .metal,
                    .drawable_width = window.drawable_width,
                    .drawable_height = window.drawable_height,
                    .swapchain_format = .bgra8_unorm_srgb,
                    .depth_format = .d32_float,
                    .has_depth = true,
                },
                .owned_device = true,
                .owned_metal_device = md_ptr,
                .sdl_metal_view = metal_view,
            };
            out.setFramesInFlight(config.frames_in_flight);
            copyCStringSlice(out.runtime_info.device_name[0..], md_ptr.getDeviceName());
            copyCStringSlice(out.runtime_info.driver_name[0..], "Metal");
            copyCStringSlice(out.runtime_info.driver_info[0..], "Guava Metal RHI");
            return out;
        }

        const backend_ptr = allocator.create(metal_backend_mod.MetalBackend) catch return error.OutOfMemory;
        errdefer allocator.destroy(backend_ptr);
        backend_ptr.* = metal_backend_mod.MetalBackend.init(allocator);
        errdefer backend_ptr.deinit();

        const dev_ptr = allocator.create(rhi.Device) catch return error.OutOfMemory;
        errdefer allocator.destroy(dev_ptr);
        dev_ptr.* = backend_ptr.createDevice();

        var out = RhiDevice{
            .allocator = allocator,
            .device = dev_ptr,
            .api = .metal,
            .runtime_info = .{
                .backend = .metal,
                .drawable_width = window.drawable_width,
                .drawable_height = window.drawable_height,
                .swapchain_format = .bgra8_unorm_srgb,
                .depth_format = .d32_float,
                .has_depth = true,
            },
            .owned_device = true,
            .owned_mock_backend = backend_ptr,
        };
        out.setFramesInFlight(config.frames_in_flight);
        copyCStringSlice(out.runtime_info.device_name[0..], "Mock Metal Device");
        copyCStringSlice(out.runtime_info.driver_name[0..], "Mock");
        copyCStringSlice(out.runtime_info.driver_info[0..], "Guava Mock RHI");
        return out;
    }

    pub fn initWithDevice(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
    ) RhiDevice {
        return .{
            .allocator = allocator,
            .device = device,
            .owned_device = false,
        };
    }

    pub fn deinit(self: *RhiDevice) void {
        self.releaseAllDepthTextures();
        if (self.owned_device) {
            self.device.deinit();
            self.allocator.destroy(self.device);

            if (self.owned_metal_device) |md| {
                md.deinit();
                self.allocator.destroy(md);
            }
            if (self.sdl_metal_view != null) {
                sdl.SDL_Metal_DestroyView(self.sdl_metal_view);
            }
            if (self.owned_mock_backend) |mb| {
                mb.deinit();
                self.allocator.destroy(mb);
            }
        }
        self.* = undefined;
    }

    // ────────────────────────────────────────────────────────────────────
    // Performance statistics (stub - kept for compatibility)
    // ────────────────────────────────────────────────────────────────────

    pub fn performanceStats(self: *const RhiDevice) types.PerformanceStats {
        return self.perf_stats;
    }

    pub fn recordFrame(self: *RhiDevice, frame_time_ns: u64) void {
        self.perf_stats.recordFrame(frame_time_ns);
    }

    pub fn recordDrawCalls(self: *RhiDevice, draw_calls: u64, triangles: u64, vertices: u64, instanced: u64) void {
        self.perf_stats.draw_calls += draw_calls;
        self.perf_stats.triangles_drawn += triangles;
        self.perf_stats.vertices_drawn += vertices;
        self.perf_stats.instanced_draws += instanced;
    }

    pub fn recordBindings(
        self: *RhiDevice,
        pipelines: u64,
        bind_groups: u64,
        vertex_buffers: u64,
        index_buffers: u64,
        samplers: u64,
    ) void {
        self.perf_stats.pipeline_binds += pipelines;
        self.perf_stats.bind_group_binds += bind_groups;
        self.perf_stats.vertex_buffer_binds += vertex_buffers;
        self.perf_stats.index_buffer_binds += index_buffers;
        self.perf_stats.sampler_binds += samplers;
    }

    pub fn recordTransfer(self: *RhiDevice, texture_uploads: u64, buffer_uploads: u64, bytes: u64) void {
        self.perf_stats.texture_uploads += texture_uploads;
        self.perf_stats.buffer_uploads += buffer_uploads;
        self.perf_stats.bytes_uploaded += bytes;
    }

    pub fn recordRedundantBindsAvoided(
        self: *RhiDevice,
        pipelines: u64,
        bind_groups: u64,
        vertex_buffers: u64,
        index_buffers: u64,
    ) void {
        self.perf_stats.redundant_pipeline_binds_avoided += pipelines;
        self.perf_stats.redundant_bind_group_binds_avoided += bind_groups;
        self.perf_stats.redundant_vertex_buffer_binds_avoided += vertex_buffers;
        self.perf_stats.redundant_index_buffer_binds_avoided += index_buffers;
    }

    pub fn resetPerformanceStats(self: *RhiDevice) void {
        self.perf_stats.reset();
    }

    // ────────────────────────────────────────────────────────────────────
    // Binding state tracking
    // ────────────────────────────────────────────────────────────────────

    pub fn bindingState(self: *RhiDevice) *BindGroupState {
        return &self.bind_state;
    }

    pub fn resetBindingState(self: *RhiDevice) void {
        self.bind_state.reset();
    }

    pub fn depthTexture(self: *RhiDevice) ?*const Texture {
        if (self.depth_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn depthTextureForFrame(self: *RhiDevice) ?*const Texture {
        const idx = self.current_depth_index;
        if (self.depth_textures[idx]) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn advanceFrame(self: *RhiDevice) void {
        self.current_depth_index = (self.current_depth_index + 1) % self.frames_in_flight;
    }

    pub fn frameIndex(self: *const RhiDevice) u32 {
        return self.current_depth_index;
    }

    pub fn setFramesInFlight(self: *RhiDevice, frames: u32) void {
        self.frames_in_flight = @min(frames, 3);
        if (self.frames_in_flight < 2) self.frames_in_flight = 2;
    }

    pub fn runtimeInfo(self: *const RhiDevice) types.RuntimeInfo {
        return self.runtime_info;
    }

    pub fn activeCommandBuffer(self: *RhiDevice) ?*command_buffer.CommandBuffer {
        if (self.current_frame) |*frame| {
            return &frame.command_buffer;
        }
        return null;
    }

    pub fn waitForIdle(self: *RhiDevice) bool {
        _ = self;
        // Not implemented in new RHI - stub
        return true;
    }

    // ────────────────────────────────────────────────────────────────────
    // Frame management
    // ────────────────────────────────────────────────────────────────────
    pub fn acquireCommandBuffer(self: *RhiDevice) Error!*command_buffer.CommandBuffer {
        // Old API for acquiring command buffers independently - used for offscreen operations
        // In Phase 2 adapter, return standalone CommandBuffer via allocation
        const ptr = try self.allocator.create(command_buffer.CommandBuffer);
        ptr.* = try self.device.createCommandBuffer(self.allocator);
        return ptr;
    }

    pub fn releaseCommandBuffer(self: *RhiDevice, cmd_buffer: *command_buffer.CommandBuffer) void {
        cmd_buffer.deinit();
        self.allocator.destroy(cmd_buffer);
    }

    pub fn beginFrame(self: *RhiDevice) Error!Frame {
        const swapchain_image = try self.device.acquireSwapchainImage();
        const cmd = try self.device.createCommandBuffer(self.allocator);
        try self.resize(swapchain_image.width, swapchain_image.height);
        const frame: Frame = .{
            .swapchain_image = swapchain_image,
            .command_buffer = cmd,
        };
        self.current_frame = frame;
        return frame;
    }

    pub fn cancelFrame(self: *RhiDevice, frame: Frame) Error!void {
        const active = self.current_frame orelse frame;
        var cmd_mut = active.command_buffer;
        cmd_mut.deinit();
        self.current_frame = null;
    }

    pub fn submitFrame(self: *RhiDevice, frame: Frame) Error!void {
        const active = self.current_frame orelse frame;
        try self.device.submitCommandBuffer(.graphics, &active.command_buffer, .{});
        const swapchain_image = active.swapchain_image;
        try self.device.present(swapchain_image);
        var cmd_mut = active.command_buffer;
        cmd_mut.deinit();
        self.advanceFrame();
        self.depth_texture = self.depth_textures[self.current_depth_index];
        self.current_frame = null;
    }

    pub fn submitFrameAndAcquireFence(self: *RhiDevice, frame: Frame) Error!Fence {
        const active = self.current_frame orelse frame;
        try self.device.submitCommandBuffer(.graphics, &active.command_buffer, .{});
        const swapchain_image = active.swapchain_image;
        try self.device.present(swapchain_image);
        var cmd_mut = active.command_buffer;
        cmd_mut.deinit();
        self.advanceFrame();
        self.depth_texture = self.depth_textures[self.current_depth_index];
        self.current_frame = null;
        return .{}; // STUB - fence not yet implemented
    }

    pub fn clearAndPresent(self: *RhiDevice, frame: Frame, clear: types.ClearState) Error!void {
        if (frame.swapchain_image.id == 0) {
            return self.cancelFrame(frame);
        }
        const pass = try self.beginRenderPass(frame, clear);
        self.endRenderPass(pass);
        try self.submitFrame(frame);
    }

    // ────────────────────────────────────────────────────────────────────
    // Render pass
    // ────────────────────────────────────────────────────────────────────

    pub fn beginRenderPass(self: *RhiDevice, frame: Frame, clear: types.ClearState) Error!RenderPass {
        return self.beginRenderPassWithDesc(frame, .{
            .color = .{
                .target = .swapchain,
                .clear_color = clear.color,
                .load_op = .clear,
                .store_op = .store,
            },
            .depth = if (self.depthTexture()) |texture|
                .{
                    .texture = texture,
                    .clear_depth = clear.depth,
                    .clear_stencil = clear.stencil,
                    .load_op = .clear,
                    .store_op = .dont_care,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                }
            else
                null,
        });
    }

    pub fn beginRenderPassWithDesc(self: *RhiDevice, frame: Frame, desc: RenderPassDesc) Error!RenderPass {
        if (self.current_frame == null) {
            self.current_frame = frame;
        }
        var cmd_mut = &self.current_frame.?.command_buffer;

        const color_id = switch (desc.color.target) {
            .swapchain => self.current_frame.?.swapchain_image.id,
            .texture => |texture| texture.id,
        };

        const depth_id = if (desc.depth) |d| d.texture.id else 0;

        var clear_mask: u32 = 0;
        if (desc.color.load_op == .clear) clear_mask |= 0x1;
        if (desc.depth) |d| {
            if (d.load_op == .clear) clear_mask |= 0x2;
        }

        cmd_mut.encodeBeginRenderPass(.{
            .color_target_id = color_id,
            .depth_target_id = depth_id,
            .clear_mask = clear_mask,
            .clear_r = desc.color.clear_color[0],
            .clear_g = desc.color.clear_color[1],
            .clear_b = desc.color.clear_color[2],
            .clear_a = desc.color.clear_color[3],
            .clear_depth = if (desc.depth) |d| d.clear_depth else 1.0,
        }) catch |err| {
            return switch (err) {
                error.InvalidOpcode => error.RenderPassBeginFailed,
                error.OutOfMemory => error.OutOfMemory,
                error.TruncatedStream => error.RenderPassBeginFailed,
            };
        };

        return .{};
    }

    pub fn endRenderPass(self: *RhiDevice, pass: RenderPass) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeEndRenderPass() catch {};
        }
        _ = pass;
    }

    pub fn beginCopyPass(self: *RhiDevice, frame: Frame) Error!CopyPass {
        _ = frame;
        _ = self;
        return .{};
    }

    pub fn endCopyPass(self: *RhiDevice, pass: CopyPass) void {
        _ = self;
        _ = pass;
    }

    // ────────────────────────────────────────────────────────────────────
    // Compute pass
    // ────────────────────────────────────────────────────────────────────
    pub fn beginComputePass(
        self: *RhiDevice,
        frame: Frame,
        rw_storage_textures: []const *const Texture,
        rw_storage_buffers: []const *const Buffer,
    ) Error!ComputePass {
        if (self.current_frame == null) {
            self.current_frame = frame;
        }
        if (self.current_frame) |*active| {
            active.command_buffer.encodeBeginComputePass(.{}) catch return error.CommandBufferAcquireFailed;
        }
        _ = rw_storage_textures;
        _ = rw_storage_buffers;
        return .{};
    }

    pub fn endComputePass(self: *RhiDevice, pass: ComputePass) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeEndComputePass() catch {};
        }
        _ = pass;
    }

    pub fn bindComputePipeline(self: *RhiDevice, pass: ComputePass, pipeline: *const ComputePipeline) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetPipeline(.{ .pipeline_id = pipeline.id }) catch {};
        }
        _ = pass;
    }

    pub fn bindComputeSamplers(self: *RhiDevice, pass: ComputePass, first_slot: u32, bindings: []const TextureSamplerBinding) void {
        _ = pass;
        if (self.current_frame == null) return;
        var layout_entries = std.ArrayList(rhi.BindingLayoutEntry).empty;
        defer layout_entries.deinit(self.allocator);
        var set_entries = std.ArrayList(rhi.BindingSetEntry).empty;
        defer set_entries.deinit(self.allocator);

        for (bindings, 0..) |binding, i| {
            const base_slot = first_slot + @as(u32, @intCast(i * 2));
            const tex_slot = base_slot;
            const samp_slot = base_slot + 1;
            layout_entries.append(self.allocator, .{ .slot = tex_slot, .binding_type = .texture, .stage = .compute }) catch return;
            set_entries.append(self.allocator, .{ .slot = tex_slot, .resource = .{ .texture = .{ .id = binding.texture.id } } }) catch return;
            layout_entries.append(self.allocator, .{ .slot = samp_slot, .binding_type = .sampler, .stage = .compute }) catch return;
            set_entries.append(self.allocator, .{ .slot = samp_slot, .resource = .{ .sampler = .{ .id = binding.sampler.id } } }) catch return;
        }

        if (layout_entries.items.len == 0) return;
        const layout = self.device.createBindingLayout(.{ .entries = layout_entries.items, .label = "compute_samplers" }) catch return;
        const set = self.device.createBindingSetCached(layout, .{ .entries = set_entries.items, .label = "compute_samplers" }) catch return;
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetBindingSet(.{ .slot = first_slot, .set_id = set.id }) catch {};
        }
    }

    pub fn bindComputeStorageTextures(self: *RhiDevice, pass: ComputePass, first_slot: u32, textures: []const *const Texture) void {
        _ = pass;
        if (self.current_frame == null) return;
        var layout_entries = std.ArrayList(rhi.BindingLayoutEntry).empty;
        defer layout_entries.deinit(self.allocator);
        var set_entries = std.ArrayList(rhi.BindingSetEntry).empty;
        defer set_entries.deinit(self.allocator);

        for (textures, 0..) |tex, i| {
            const slot = first_slot + @as(u32, @intCast(i));
            layout_entries.append(self.allocator, .{ .slot = slot, .binding_type = .storage_texture, .stage = .compute }) catch return;
            set_entries.append(self.allocator, .{ .slot = slot, .resource = .{ .storage_texture = .{ .id = tex.id } } }) catch return;
        }

        if (layout_entries.items.len == 0) return;
        const layout = self.device.createBindingLayout(.{ .entries = layout_entries.items, .label = "compute_storage_tex" }) catch return;
        const set = self.device.createBindingSetCached(layout, .{ .entries = set_entries.items, .label = "compute_storage_tex" }) catch return;
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetBindingSet(.{ .slot = first_slot, .set_id = set.id }) catch {};
        }
    }

    pub fn bindComputeStorageBuffers(self: *RhiDevice, pass: ComputePass, first_slot: u32, buffers: []const *const Buffer) void {
        _ = pass;
        if (self.current_frame == null) return;
        var layout_entries = std.ArrayList(rhi.BindingLayoutEntry).empty;
        defer layout_entries.deinit(self.allocator);
        var set_entries = std.ArrayList(rhi.BindingSetEntry).empty;
        defer set_entries.deinit(self.allocator);

        for (buffers, 0..) |buf, i| {
            const slot = first_slot + @as(u32, @intCast(i));
            layout_entries.append(self.allocator, .{ .slot = slot, .binding_type = .storage_buffer, .stage = .compute }) catch return;
            set_entries.append(self.allocator, .{ .slot = slot, .resource = .{ .storage_buffer = .{ .id = buf.id } } }) catch return;
        }

        if (layout_entries.items.len == 0) return;
        const layout = self.device.createBindingLayout(.{ .entries = layout_entries.items, .label = "compute_storage_buf" }) catch return;
        const set = self.device.createBindingSetCached(layout, .{ .entries = set_entries.items, .label = "compute_storage_buf" }) catch return;
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetBindingSet(.{ .slot = first_slot, .set_id = set.id }) catch {};
        }
    }

    pub fn dispatchCompute(self: *RhiDevice, pass: ComputePass, groupcount_x: u32, groupcount_y: u32, groupcount_z: u32) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeDispatch(.{ .x = groupcount_x, .y = groupcount_y, .z = groupcount_z }) catch {};
        }
        _ = pass;
    }

    pub fn pushComputeUniformData(self: *RhiDevice, frame: Frame, slot: u32, data: []const u8) void {
        _ = frame;
        if (self.current_frame) |*active| {
            active.command_buffer.encodePushUniform(2, @intCast(slot), data) catch {};
        }
    }

    pub fn blitTexture(self: *RhiDevice, frame: Frame, src: *const Texture, dst: *const Texture) void {
        _ = self;
        _ = frame;
        _ = src;
        _ = dst;
    }

    // ────────────────────────────────────────────────────────────────────
    // Resource creation / destruction
    // ────────────────────────────────────────────────────────────────────

    pub fn createBuffer(self: *RhiDevice, desc: types.BufferDesc) Error!Buffer {
        const rhi_desc = rhi.BufferDesc{
            .size = desc.size,
            .usage = @bitCast(desc.usage),
            .label = desc.label,
        };
        const buf = try self.device.createBuffer(rhi_desc);
        return .{
            .id = buf.id,
            .desc = desc,
        };
    }

    pub fn releaseBuffer(self: *RhiDevice, buffer: *Buffer) void {
        self.device.vtable.destroy_buffer(self.device.ctx, .{ .id = buffer.id });
        buffer.* = undefined;
    }

    pub fn createTransferBuffer(self: *RhiDevice, desc: types.TransferBufferDesc) Error!TransferBuffer {
        const usage = rhi.BufferUsageFlags{
            .transfer_src = desc.upload,
            .transfer_dst = !desc.upload,
            .storage_read = true,
            .storage_write = true,
        };
        const buf = try self.device.createBuffer(.{
            .size = desc.size,
            .usage = usage,
            .label = desc.label,
        });
        return .{ .id = buf.id, .desc = desc };
    }

    pub fn releaseTransferBuffer(self: *RhiDevice, transfer_buffer: *TransferBuffer) void {
        self.device.destroyBuffer(.{ .id = transfer_buffer.id });
        transfer_buffer.* = undefined;
    }

    pub fn createTexture(self: *RhiDevice, desc: types.TextureDesc) Error!Texture {
        const rhi_desc = rhi.TextureDesc{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .usage = @bitCast(desc.usage),
            .sample_count = desc.sample_count,
            .label = desc.label,
        };
        const tex = try self.device.createTexture(rhi_desc);
        return .{
            .id = tex.id,
            .desc = desc,
        };
    }

    pub fn releaseTexture(self: *RhiDevice, texture: *Texture) void {
        self.device.vtable.destroy_texture(self.device.ctx, .{ .id = texture.id });
        texture.* = undefined;
    }

    pub fn createShaderModule(self: *RhiDevice, desc: ShaderModuleDesc) Error!ShaderModule {
        const rhi_desc = rhi.ShaderModuleDesc{
            .stage = desc.stage,
            .format = desc.format,
            .code = desc.code,
            .entry_point = desc.entry_point,
        };
        const shader = try self.device.createShaderModule(rhi_desc);
        return .{
            .id = shader.id,
            .desc = desc,
        };
    }

    pub fn releaseShaderModule(self: *RhiDevice, shader: *ShaderModule) void {
        _ = self;
        _ = shader;
    }

    pub fn createSampler(self: *RhiDevice, desc: SamplerDesc) Error!Sampler {
        const rhi_desc = rhi.SamplerDesc{
            .min_filter = desc.min_filter,
            .mag_filter = desc.mag_filter,
            .mipmap_mode = desc.mipmap_mode,
            .address_mode_u = desc.address_mode_u,
            .address_mode_v = desc.address_mode_v,
            .address_mode_w = desc.address_mode_w,
            .enable_compare = desc.enable_compare,
            .compare_op = desc.compare_op,
        };
        const sampler = try self.device.createSampler(rhi_desc);
        return .{
            .id = sampler.id,
            .desc = desc,
        };
    }

    pub fn releaseSampler(self: *RhiDevice, sampler: *Sampler) void {
        self.device.vtable.destroy_sampler(self.device.ctx, .{ .id = sampler.id });
        sampler.* = undefined;
    }

    pub fn createGraphicsPipeline(self: *RhiDevice, desc: GraphicsPipelineDesc) Error!GraphicsPipeline {
        const layout = try self.ensureDefaultPipelineLayout();

        var attrs = std.ArrayList(rhi.VertexAttribute).empty;
        defer attrs.deinit(self.allocator);
        for (desc.vertex_attributes) |a| {
            attrs.append(self.allocator, .{
                .location = a.location,
                .format = a.format,
                .offset = a.offset,
                .buffer_index = a.buffer_slot,
            }) catch return error.OutOfMemory;
        }

        var buffer_layouts = std.ArrayList(rhi.VertexBufferLayout).empty;
        defer buffer_layouts.deinit(self.allocator);
        for (desc.vertex_buffer_layouts) |l| {
            buffer_layouts.append(self.allocator, .{
                .stride = l.stride,
                .step_rate = l.input_rate,
            }) catch return error.OutOfMemory;
        }

        const pipeline = try self.device.createGraphicsPipeline(.{
            .layout = layout,
            .vertex = .{ .id = desc.vertex_shader.id },
            .fragment = .{ .id = desc.fragment_shader.id },
            .color_format = desc.color_format orelse self.runtime_info.swapchain_format,
            .depth_format = desc.depth_format,
            .primitive = desc.primitive_type,
            .depth_stencil = if (desc.depth_test)
                .{ .depth_compare = desc.depth_compare, .depth_write = desc.depth_write }
            else
                null,
            .vertex_layout = if (attrs.items.len > 0 or buffer_layouts.items.len > 0)
                .{ .attributes = attrs.items, .buffer_layouts = buffer_layouts.items }
            else
                null,
            .blend_state = desc.blend_state,
        });
        return .{ .id = pipeline.id };
    }

    pub fn releaseGraphicsPipeline(self: *RhiDevice, pipeline: *GraphicsPipeline) void {
        self.device.vtable.destroy_graphics_pipeline(self.device.ctx, .{ .id = pipeline.id });
        pipeline.* = undefined;
    }

    pub fn createComputePipeline(self: *RhiDevice, desc: ComputePipelineDesc) Error!ComputePipeline {
        const layout = try self.ensureDefaultPipelineLayout();
        const shader = try self.device.createShaderModule(.{
            .stage = .compute,
            .format = desc.format,
            .code = desc.code,
            .entry_point = desc.entry_point,
        });
        const pipeline = try self.device.createComputePipeline(.{
            .layout = layout,
            .shader = shader,
        });
        return .{ .id = pipeline.id };
    }

    pub fn releaseComputePipeline(self: *RhiDevice, pipeline: *ComputePipeline) void {
        self.device.vtable.destroy_compute_pipeline(self.device.ctx, .{ .id = pipeline.id });
        pipeline.* = undefined;
    }

    pub fn createBindGroup(self: *RhiDevice, desc: BindGroupDesc) Error!BindGroup {
        var layout_entries = std.ArrayList(rhi.BindingLayoutEntry).empty;
        defer layout_entries.deinit(self.allocator);
        var set_entries = std.ArrayList(rhi.BindingSetEntry).empty;
        defer set_entries.deinit(self.allocator);

        for (desc.texture_sampler_bindings, 0..) |binding, i| {
            // Interleave texture/sampler at consecutive slots for layout validation.
            // Metal apply-side remaps: texture slot N → Metal texture index N/2,
            // sampler slot N → Metal sampler index N/2, since Metal has independent
            // index spaces and spirv-cross maps GLSL binding K to texture(K)+sampler(K).
            const base_slot = desc.slot_offset + @as(u32, @intCast(i * 2));
            const tex_slot = base_slot;
            const samp_slot = base_slot + 1;
            layout_entries.append(self.allocator, .{ .slot = tex_slot, .binding_type = .texture, .stage = desc.stage }) catch return error.OutOfMemory;
            set_entries.append(self.allocator, .{ .slot = tex_slot, .resource = .{ .texture = .{ .id = binding.texture.id } } }) catch return error.OutOfMemory;

            layout_entries.append(self.allocator, .{ .slot = samp_slot, .binding_type = .sampler, .stage = desc.stage }) catch return error.OutOfMemory;
            set_entries.append(self.allocator, .{ .slot = samp_slot, .resource = .{ .sampler = .{ .id = binding.sampler.id } } }) catch return error.OutOfMemory;
        }

        var next_slot = desc.slot_offset + (@as(u32, @intCast(desc.texture_sampler_bindings.len)) * 2);
        for (desc.storage_buffers) |buffer| {
            layout_entries.append(self.allocator, .{ .slot = next_slot, .binding_type = .storage_buffer, .stage = desc.stage }) catch return error.OutOfMemory;
            set_entries.append(self.allocator, .{ .slot = next_slot, .resource = .{ .storage_buffer = .{ .id = buffer.id } } }) catch return error.OutOfMemory;
            next_slot += 1;
        }
        for (desc.storage_textures) |texture| {
            layout_entries.append(self.allocator, .{ .slot = next_slot, .binding_type = .storage_texture, .stage = desc.stage }) catch return error.OutOfMemory;
            set_entries.append(self.allocator, .{ .slot = next_slot, .resource = .{ .storage_texture = .{ .id = texture.id } } }) catch return error.OutOfMemory;
            next_slot += 1;
        }

        if (layout_entries.items.len == 0) {
            return .{
                .stage = desc.stage,
                .texture_sampler_slots = &.{},
                .texture_sampler_samplers = &.{},
                .storage_buffer_ids = &.{},
                .storage_texture_ids = &.{},
                .slot_offset = desc.slot_offset,
            };
        }

        const layout = try self.device.createBindingLayout(.{ .entries = layout_entries.items, .label = "legacy_bind_group_layout" });
        const set = try self.device.createBindingSetCached(layout, .{ .entries = set_entries.items, .label = "legacy_bind_group" });

        return .{
            .stage = desc.stage,
            .texture_sampler_slots = &.{},
            .texture_sampler_samplers = &.{},
            .storage_buffer_ids = &.{},
            .storage_texture_ids = &.{},
            .slot_offset = desc.slot_offset,
            .layout = layout,
            .set = set,
        };
    }

    pub fn releaseBindGroup(self: *RhiDevice, bind_group: *BindGroup) void {
        _ = self;
        _ = bind_group;
    }

    // ────────────────────────────────────────────────────────────────────
    // Pipeline binding
    // ────────────────────────────────────────────────────────────────────

    pub fn bindGraphicsPipeline(self: *RhiDevice, pass: RenderPass, pipeline: *const GraphicsPipeline) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetPipeline(.{ .pipeline_id = pipeline.id }) catch {};
        }
        _ = pass;
    }

    pub fn bindVertexBuffer(self: *RhiDevice, pass: RenderPass, slot: u32, buffer: *const Buffer, offset: u32) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeSetVertexBuffer(.{ .slot = slot, .buffer_id = buffer.id, .offset = offset }) catch {};
        }
        _ = pass;
    }

    pub fn bindIndexBuffer(self: *RhiDevice, pass: RenderPass, buffer: *const Buffer, index_size: types.IndexElementSize, offset: u32) void {
        if (self.current_frame) |*frame| {
            const fmt: u32 = switch (index_size) {
                .u16 => 0,
                .u32 => 1,
            };
            frame.command_buffer.encodeSetIndexBuffer(.{ .buffer_id = buffer.id, .offset = offset, .format = fmt }) catch {};
        }
        _ = pass;
    }

    pub fn bindGroup(self: *RhiDevice, pass: RenderPass, bind_group: *const BindGroup) void {
        if (self.current_frame) |*frame| {
            if (bind_group.set) |set| {
                frame.command_buffer.encodeSetBindingSet(.{ .slot = bind_group.slot_offset, .set_id = set.id }) catch {};
            }
        }
        _ = pass;
    }

    pub fn pushVertexUniformData(self: *RhiDevice, frame: Frame, slot: u32, data: []const u8) void {
        _ = frame;
        if (self.current_frame) |*active| {
            active.command_buffer.encodePushUniform(0, @intCast(slot), data) catch {};
        }
    }

    pub fn pushFragmentUniformData(self: *RhiDevice, frame: Frame, slot: u32, data: []const u8) void {
        _ = frame;
        if (self.current_frame) |*active| {
            active.command_buffer.encodePushUniform(1, @intCast(slot), data) catch {};
        }
    }

    pub fn drawPrimitives(self: *RhiDevice, pass: RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeDraw(.{
                .vertex_count = vertex_count,
                .instance_count = instance_count,
                .first_vertex = first_vertex,
                .first_instance = first_instance,
            }) catch {};
        }
        _ = pass;
    }

    pub fn drawIndexedPrimitives(self: *RhiDevice, pass: RenderPass, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        if (self.current_frame) |*frame| {
            frame.command_buffer.encodeDrawIndexed(.{
                .index_count = index_count,
                .instance_count = instance_count,
                .first_index = first_index,
                .vertex_offset = vertex_offset,
                .first_instance = first_instance,
            }) catch {};
        }
        _ = pass;
    }

    // ────────────────────────────────────────────────────────────────────
    // Data upload / download
    // ────────────────────────────────────────────────────────────────────

    pub fn uploadBufferData(self: *RhiDevice, buffer: *const Buffer, data: []const u8) Error!void {
        try self.device.uploadBufferData(.{ .id = buffer.id }, 0, data);
    }

    pub fn uploadTextureData(
        self: *RhiDevice,
        texture: *const Texture,
        data: []const u8,
        pixels_per_row: u32,
        rows_per_layer: u32,
    ) Error!void {
        _ = rows_per_layer;
        const width = texture.desc.width;
        const height = texture.desc.height;
        const bytes_per_row = pixels_per_row * texture.desc.format.bytesPerPixel();
        try self.device.uploadTextureData(.{ .id = texture.id }, data, width, height, bytes_per_row);
    }

    pub fn readTextureData(self: *RhiDevice, texture: *const Texture, bytes_per_row: u32, destination: []u8) Error!void {
        const width = texture.desc.width;
        const height = texture.desc.height;
        try self.device.readTextureData(.{ .id = texture.id }, width, height, bytes_per_row, destination);
    }

    pub fn downloadTexturePixel(_: *RhiDevice, pass: CopyPass, texture: *const Texture, transfer_buffer: *const TransferBuffer, x: u32, y: u32) void {
        _ = pass;
        _ = texture;
        _ = transfer_buffer;
        _ = x;
        _ = y;
    }

    pub fn downloadTexturePixelToOffset(_: *RhiDevice, pass: CopyPass, texture: *const Texture, transfer_buffer: *const TransferBuffer, offset: u32, x: u32, y: u32) void {
        _ = pass;
        _ = texture;
        _ = transfer_buffer;
        _ = offset;
        _ = x;
        _ = y;
    }

    pub fn readTransferBufferBytes(self: *RhiDevice, transfer_buffer: *const TransferBuffer, destination: []u8) Error!void {
        _ = self;
        _ = transfer_buffer;
        _ = destination;
        return error.TransferBufferMapFailed;
    }

    pub fn readTransferBufferBytesAt(self: *RhiDevice, transfer_buffer: *const TransferBuffer, offset: u32, destination: []u8) Error!void {
        _ = self;
        _ = transfer_buffer;
        _ = offset;
        _ = destination;
        return error.TransferBufferMapFailed;
    }

    pub fn readTexturePixel(self: *RhiDevice, texture: *const Texture, x: u32, y: u32) Error![4]u8 {
        var all: [4]u8 = .{ 0, 0, 0, 0 };
        if (x >= texture.desc.width or y >= texture.desc.height) return error.InvalidArgument;

        const row_bytes = texture.desc.width * 4;
        const needed = row_bytes * texture.desc.height;
        const temp = try self.allocator.alloc(u8, needed);
        defer self.allocator.free(temp);

        try self.readTextureData(texture, row_bytes, temp);
        const off = (y * row_bytes) + (x * 4);
        all[0] = temp[off + 0];
        all[1] = temp[off + 1];
        all[2] = temp[off + 2];
        all[3] = temp[off + 3];
        return all;
    }

    pub fn isFenceSignaled(self: *RhiDevice, fence: *const Fence) bool {
        _ = self;
        _ = fence;
        return true; // STUB
    }

    pub fn releaseFence(self: *RhiDevice, fence: *Fence) void {
        _ = self;
        _ = fence;
    }

    fn releaseDepthTexture(self: *RhiDevice) void {
        if (self.depth_texture) |*depth_texture| {
            self.releaseTexture(depth_texture);
        }
        self.depth_texture = null;
    }

    fn releaseAllDepthTextures(self: *RhiDevice) void {
        for (0..self.depth_textures.len) |i| {
            if (self.depth_textures[i]) |*depth_texture| {
                self.releaseTexture(depth_texture);
                self.depth_textures[i] = null;
            }
        }
        self.depth_texture = null;
    }

    pub fn resize(self: *RhiDevice, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) {
            self.releaseAllDepthTextures();
            return;
        }

        // Check if existing textures match required size
        var all_match = true;
        for (0..self.frames_in_flight) |i| {
            if (self.depth_textures[i]) |depth_texture| {
                if (depth_texture.desc.width != width or depth_texture.desc.height != height) {
                    all_match = false;
                    break;
                }
            } else {
                all_match = false;
                break;
            }
        }

        if (all_match) {
            self.depth_texture = self.depth_textures[self.current_depth_index];
            return;
        }

        // Release all and recreate with multi-buffering
        self.releaseAllDepthTextures();

        for (0..self.frames_in_flight) |i| {
            self.depth_textures[i] = try self.createTexture(.{
                .width = width,
                .height = height,
                .format = .d32_float,
                .usage = types.TextureUsage.depth_stencil_target,
            });
        }

        self.depth_texture = self.depth_textures[self.current_depth_index];
    }

    pub fn bindGroupOptimized(
        self: *RhiDevice,
        pass: RenderPass,
        bind_group: *const BindGroup,
        state: *BindGroupState,
    ) void {
        self.bindGroup(pass, bind_group);
        _ = state;
    }

    pub fn bindGraphicsPipelineOptimized(
        self: *RhiDevice,
        pass: RenderPass,
        pipeline: *const GraphicsPipeline,
        state: *BindGroupState,
    ) void {
        self.bindGraphicsPipeline(pass, pipeline);
        _ = state;
    }

    pub fn bindVertexBufferOptimized(
        self: *RhiDevice,
        pass: RenderPass,
        slot: u32,
        buffer: *const Buffer,
        offset: u32,
        state: *BindGroupState,
    ) void {
        self.bindVertexBuffer(pass, slot, buffer, offset);
        _ = state;
    }

    pub fn bindIndexBufferOptimized(
        self: *RhiDevice,
        pass: RenderPass,
        buffer: *const Buffer,
        index_size: types.IndexElementSize,
        offset: u32,
        state: *BindGroupState,
    ) void {
        self.bindIndexBuffer(pass, buffer, index_size, offset);
        _ = state;
    }

    fn ensureDefaultPipelineLayout(self: *RhiDevice) Error!rhi.PipelineLayout {
        if (self.default_pipeline_layout) |layout| return layout;

        const layout = if (self.default_binding_layout) |existing| blk: {
            break :blk existing;
        } else blk_new: {
            const binding_layout = try self.device.createBindingLayout(.{
                .entries = &.{.{ .slot = 0, .binding_type = .uniform_buffer, .stage = .vertex }},
                .label = "legacy_default_binding_layout",
            });
            self.default_binding_layout = binding_layout;
            break :blk_new binding_layout;
        };

        const pipeline_layout = try self.device.resolvePipelineLayout(&.{layout});
        self.default_pipeline_layout = pipeline_layout;
        return pipeline_layout;
    }
};

fn copyCStringSlice(dest: []u8, src: []const u8) void {
    if (dest.len == 0) return;
    const n = @min(dest.len - 1, src.len);
    if (n > 0) {
        @memcpy(dest[0..n], src[0..n]);
    }
    dest[n] = 0;
    if (n + 1 < dest.len) {
        @memset(dest[n + 1 ..], 0);
    }
}
