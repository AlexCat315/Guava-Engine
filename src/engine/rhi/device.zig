const std = @import("std");
const platform_mod = @import("../core/platform.zig");
const window_mod = @import("../platform/window.zig");
const sdl = @import("../platform/sdl.zig").c;
const types = @import("types.zig");

pub const Error = error{
    UnsupportedBackend,
    DeviceCreateFailed,
    WindowClaimFailed,
    FramesInFlightFailed,
    CommandBufferAcquireFailed,
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
    CommandBufferCancelFailed,
    CommandBufferSubmitFailed,
    OutOfMemory,
};

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

pub const Buffer = struct {
    raw: *sdl.SDL_GPUBuffer,
    desc: types.BufferDesc,
};

pub const TransferBuffer = struct {
    raw: *sdl.SDL_GPUTransferBuffer,
    desc: types.TransferBufferDesc,
};

pub const Texture = struct {
    raw: *sdl.SDL_GPUTexture,
    desc: types.TextureDesc,
};

pub const ShaderModule = struct {
    raw: *sdl.SDL_GPUShader,
    desc: ShaderModuleDesc,
};

pub const Sampler = struct {
    raw: *sdl.SDL_GPUSampler,
    desc: SamplerDesc,
};

pub const GraphicsPipelineDesc = struct {
    vertex_shader: *const ShaderModule,
    fragment_shader: *const ShaderModule,
    vertex_buffer_layouts: []const VertexBufferLayoutDesc,
    vertex_attributes: []const VertexAttributeDesc,
    color_format: ?types.TextureFormat = null,
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
    raw: *sdl.SDL_GPUGraphicsPipeline,
};

pub const BindGroup = struct {
    stage: types.ShaderStage,
    texture_sampler_bindings: []sdl.SDL_GPUTextureSamplerBinding,
    storage_buffers: []*sdl.SDL_GPUBuffer,
    storage_textures: []*sdl.SDL_GPUTexture,
    slot_offset: u32 = 0,
};

pub const Frame = struct {
    command_buffer: *sdl.SDL_GPUCommandBuffer,
    swapchain_texture: ?*sdl.SDL_GPUTexture,
    width: u32,
    height: u32,
};

pub const RenderPass = struct {
    raw: *sdl.SDL_GPURenderPass,
};

pub const CopyPass = struct {
    raw: *sdl.SDL_GPUCopyPass,
};

pub const Fence = struct {
    raw: *sdl.SDL_GPUFence,
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

const DriverSpec = struct {
    api: types.GraphicsAPI,
    driver_name: [:0]const u8,
    shader_format: sdl.SDL_GPUShaderFormat,
};

pub const RhiDevice = struct {
    allocator: std.mem.Allocator,
    raw: *sdl.SDL_GPUDevice,
    window: *sdl.SDL_Window,
    api: types.GraphicsAPI,
    runtime_info: types.RuntimeInfo = .{},
    depth_texture: ?Texture = null,

    pub fn init(
        allocator: std.mem.Allocator,
        platform: platform_mod.Platform,
        window: *window_mod.Window,
        config: types.DeviceConfig,
    ) Error!RhiDevice {
        const selection = try createDevice(platform, config);
        errdefer sdl.SDL_DestroyGPUDevice(selection.raw);

        if (!sdl.SDL_ClaimWindowForGPUDevice(selection.raw, window.handle)) {
            std.log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{window_mod.lastError()});
            return error.WindowClaimFailed;
        }
        errdefer sdl.SDL_ReleaseWindowFromGPUDevice(selection.raw, window.handle);

        if (!sdl.SDL_SetGPUAllowedFramesInFlight(selection.raw, config.frames_in_flight)) {
            std.log.err("SDL_SetGPUAllowedFramesInFlight failed: {s}", .{window_mod.lastError()});
            return error.FramesInFlightFailed;
        }

        var device = RhiDevice{
            .allocator = allocator,
            .raw = selection.raw,
            .window = window.handle,
            .api = selection.api,
            .runtime_info = .{ .backend = selection.api },
        };
        device.refreshRuntimeInfo(window.drawable_width, window.drawable_height);
        try device.resize(window.drawable_width, window.drawable_height);
        return device;
    }

    pub fn deinit(self: *RhiDevice) void {
        if (self.depth_texture != null) {
            self.releaseDepthTexture();
        }

        _ = sdl.SDL_WaitForGPUIdle(self.raw);
        sdl.SDL_ReleaseWindowFromGPUDevice(self.raw, self.window);
        sdl.SDL_DestroyGPUDevice(self.raw);
    }

    pub fn runtimeInfo(self: *const RhiDevice) types.RuntimeInfo {
        return self.runtime_info;
    }

    pub fn depthTexture(self: *RhiDevice) ?*const Texture {
        if (self.depth_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn acquireCommandBuffer(self: *RhiDevice) ?*sdl.SDL_GPUCommandBuffer {
        return sdl.SDL_AcquireGPUCommandBuffer(self.raw);
    }

    pub fn submitCommandBuffer(_: *RhiDevice, command_buffer: *sdl.SDL_GPUCommandBuffer) bool {
        return sdl.SDL_SubmitGPUCommandBuffer(command_buffer);
    }

    pub fn waitForIdle(self: *RhiDevice) bool {
        return sdl.SDL_WaitForGPUIdle(self.raw);
    }

    pub fn beginFrame(self: *RhiDevice) Error!Frame {
        const command_buffer = sdl.SDL_AcquireGPUCommandBuffer(self.raw) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferAcquireFailed;
        };

        var swapchain_texture: ?*sdl.SDL_GPUTexture = null;
        var width: c_uint = 0;
        var height: c_uint = 0;
        if (!sdl.SDL_WaitAndAcquireGPUSwapchainTexture(
            command_buffer,
            self.window,
            &swapchain_texture,
            &width,
            &height,
        )) {
            _ = sdl.SDL_CancelGPUCommandBuffer(command_buffer);
            std.log.err("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}", .{window_mod.lastError()});
            return error.SwapchainAcquireFailed;
        }

        const drawable_width: u32 = @intCast(width);
        const drawable_height: u32 = @intCast(height);
        try self.resize(drawable_width, drawable_height);

        return .{
            .command_buffer = command_buffer,
            .swapchain_texture = swapchain_texture,
            .width = drawable_width,
            .height = drawable_height,
        };
    }

    pub fn cancelFrame(_: *RhiDevice, frame: Frame) Error!void {
        if (!sdl.SDL_CancelGPUCommandBuffer(frame.command_buffer)) {
            std.log.err("SDL_CancelGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferCancelFailed;
        }
    }

    pub fn submitFrame(_: *RhiDevice, frame: Frame) Error!void {
        if (!sdl.SDL_SubmitGPUCommandBuffer(frame.command_buffer)) {
            std.log.err("SDL_SubmitGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferSubmitFailed;
        }
    }

    pub fn submitFrameAndAcquireFence(_: *RhiDevice, frame: Frame) Error!Fence {
        const fence = sdl.SDL_SubmitGPUCommandBufferAndAcquireFence(frame.command_buffer) orelse {
            std.log.err("SDL_SubmitGPUCommandBufferAndAcquireFence failed: {s}", .{window_mod.lastError()});
            return error.FenceAcquireFailed;
        };

        return .{ .raw = fence };
    }

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

    pub fn beginRenderPassWithDesc(_: *RhiDevice, frame: Frame, desc: RenderPassDesc) Error!RenderPass {
        var color_target = std.mem.zeroes(sdl.SDL_GPUColorTargetInfo);
        color_target.texture = switch (desc.color.target) {
            .swapchain => frame.swapchain_texture orelse return error.RenderPassBeginFailed,
            .texture => |texture| texture.raw,
        };
        color_target.clear_color = .{
            .r = desc.color.clear_color[0],
            .g = desc.color.clear_color[1],
            .b = desc.color.clear_color[2],
            .a = desc.color.clear_color[3],
        };
        color_target.load_op = loadOpToSdl(desc.color.load_op);
        color_target.store_op = storeOpToSdl(desc.color.store_op);

        var depth_target = std.mem.zeroes(sdl.SDL_GPUDepthStencilTargetInfo);
        var depth_target_ptr: ?*const sdl.SDL_GPUDepthStencilTargetInfo = null;
        if (desc.depth) |depth_desc| {
            depth_target.texture = depth_desc.texture.raw;
            depth_target.clear_depth = depth_desc.clear_depth;
            depth_target.clear_stencil = depth_desc.clear_stencil;
            depth_target.load_op = loadOpToSdl(depth_desc.load_op);
            depth_target.store_op = storeOpToSdl(depth_desc.store_op);
            depth_target.stencil_load_op = loadOpToSdl(depth_desc.stencil_load_op);
            depth_target.stencil_store_op = storeOpToSdl(depth_desc.stencil_store_op);
            depth_target_ptr = &depth_target;
        }

        const render_pass = sdl.SDL_BeginGPURenderPass(frame.command_buffer, &color_target, 1, depth_target_ptr) orelse {
            std.log.err("SDL_BeginGPURenderPass failed: {s}", .{window_mod.lastError()});
            return error.RenderPassBeginFailed;
        };

        return .{ .raw = render_pass };
    }

    pub fn endRenderPass(_: *RhiDevice, pass: RenderPass) void {
        sdl.SDL_EndGPURenderPass(pass.raw);
    }

    pub fn beginCopyPass(_: *RhiDevice, frame: Frame) Error!CopyPass {
        const copy_pass = sdl.SDL_BeginGPUCopyPass(frame.command_buffer) orelse {
            std.log.err("SDL_BeginGPUCopyPass failed: {s}", .{window_mod.lastError()});
            return error.CopyPassBeginFailed;
        };

        return .{ .raw = copy_pass };
    }

    pub fn endCopyPass(_: *RhiDevice, pass: CopyPass) void {
        sdl.SDL_EndGPUCopyPass(pass.raw);
    }

    pub fn clearAndPresent(self: *RhiDevice, frame: Frame, clear: types.ClearState) Error!void {
        if (frame.swapchain_texture == null) {
            return self.cancelFrame(frame);
        }

        const pass = try self.beginRenderPass(frame, clear);
        self.endRenderPass(pass);
        try self.submitFrame(frame);
    }

    pub fn resize(self: *RhiDevice, width: u32, height: u32) Error!void {
        self.runtime_info.drawable_width = width;
        self.runtime_info.drawable_height = height;

        if (width == 0 or height == 0) {
            if (self.depth_texture != null) {
                self.releaseDepthTexture();
            }
            self.runtime_info.has_depth = false;
            return;
        }

        if (self.depth_texture) |depth_texture| {
            if (depth_texture.desc.width == width and depth_texture.desc.height == height) {
                self.runtime_info.has_depth = true;
                return;
            }
        }

        if (self.depth_texture != null) {
            self.releaseDepthTexture();
        }

        self.depth_texture = try self.createTexture(.{
            .width = width,
            .height = height,
            .format = .d32_float,
            .usage = types.TextureUsage.depth_stencil_target,
        });
        self.runtime_info.has_depth = true;
    }

    pub fn createBuffer(self: *RhiDevice, desc: types.BufferDesc) Error!Buffer {
        var create_info = std.mem.zeroes(sdl.SDL_GPUBufferCreateInfo);
        create_info.usage = bufferUsageToSdl(desc.usage);
        create_info.size = desc.size;

        const buffer = sdl.SDL_CreateGPUBuffer(self.raw, &create_info);
        if (buffer == null) {
            std.log.err("SDL_CreateGPUBuffer failed: {s}", .{window_mod.lastError()});
            return error.BufferCreateFailed;
        }

        return .{
            .raw = buffer.?,
            .desc = desc,
        };
    }

    pub fn releaseBuffer(self: *RhiDevice, buffer: *Buffer) void {
        sdl.SDL_ReleaseGPUBuffer(self.raw, buffer.raw);
        buffer.* = undefined;
    }

    pub fn createTransferBuffer(self: *RhiDevice, desc: types.TransferBufferDesc) Error!TransferBuffer {
        var create_info = std.mem.zeroes(sdl.SDL_GPUTransferBufferCreateInfo);
        create_info.usage = if (desc.upload) sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD else sdl.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        create_info.size = desc.size;

        const transfer_buffer = sdl.SDL_CreateGPUTransferBuffer(self.raw, &create_info);
        if (transfer_buffer == null) {
            std.log.err("SDL_CreateGPUTransferBuffer failed: {s}", .{window_mod.lastError()});
            return error.TransferBufferCreateFailed;
        }

        return .{
            .raw = transfer_buffer.?,
            .desc = desc,
        };
    }

    pub fn releaseTransferBuffer(self: *RhiDevice, transfer_buffer: *TransferBuffer) void {
        sdl.SDL_ReleaseGPUTransferBuffer(self.raw, transfer_buffer.raw);
        transfer_buffer.* = undefined;
    }

    pub fn isFenceSignaled(self: *RhiDevice, fence: *const Fence) bool {
        return sdl.SDL_QueryGPUFence(self.raw, fence.raw);
    }

    pub fn releaseFence(self: *RhiDevice, fence: *Fence) void {
        sdl.SDL_ReleaseGPUFence(self.raw, fence.raw);
        fence.* = undefined;
    }

    pub fn createTexture(self: *RhiDevice, desc: types.TextureDesc) Error!Texture {
        var create_info = std.mem.zeroes(sdl.SDL_GPUTextureCreateInfo);
        create_info.type = sdl.SDL_GPU_TEXTURETYPE_2D;
        create_info.format = textureFormatToSdl(desc.format);
        create_info.usage = textureUsageToSdl(desc.usage);
        create_info.width = desc.width;
        create_info.height = desc.height;
        create_info.layer_count_or_depth = 1;
        create_info.num_levels = 1;
        create_info.sample_count = sampleCountToSdl(desc.sample_count);

        const texture = sdl.SDL_CreateGPUTexture(self.raw, &create_info);
        if (texture == null) {
            std.log.err("SDL_CreateGPUTexture failed: {s}", .{window_mod.lastError()});
            return error.TextureCreateFailed;
        }

        return .{
            .raw = texture.?,
            .desc = desc,
        };
    }

    pub fn releaseTexture(self: *RhiDevice, texture: *Texture) void {
        sdl.SDL_ReleaseGPUTexture(self.raw, texture.raw);
        texture.* = undefined;
    }

    pub fn createShaderModule(self: *RhiDevice, desc: ShaderModuleDesc) Error!ShaderModule {
        var create_info = std.mem.zeroes(sdl.SDL_GPUShaderCreateInfo);
        create_info.code_size = desc.code.len;
        create_info.code = desc.code.ptr;
        create_info.entrypoint = desc.entry_point.ptr;
        create_info.format = shaderFormatToSdl(desc.format);
        create_info.stage = shaderStageToSdl(desc.stage);
        create_info.num_samplers = desc.num_samplers;
        create_info.num_storage_textures = desc.num_storage_textures;
        create_info.num_storage_buffers = desc.num_storage_buffers;
        create_info.num_uniform_buffers = desc.num_uniform_buffers;

        const shader = sdl.SDL_CreateGPUShader(self.raw, &create_info);
        if (shader == null) {
            std.log.err("SDL_CreateGPUShader failed: {s}", .{window_mod.lastError()});
            return error.ShaderCreateFailed;
        }

        return .{
            .raw = shader.?,
            .desc = desc,
        };
    }

    pub fn releaseShaderModule(self: *RhiDevice, shader: *ShaderModule) void {
        sdl.SDL_ReleaseGPUShader(self.raw, shader.raw);
        shader.* = undefined;
    }

    pub fn createSampler(self: *RhiDevice, desc: SamplerDesc) Error!Sampler {
        var create_info = std.mem.zeroes(sdl.SDL_GPUSamplerCreateInfo);
        create_info.min_filter = samplerFilterToSdl(desc.min_filter);
        create_info.mag_filter = samplerFilterToSdl(desc.mag_filter);
        create_info.mipmap_mode = samplerMipmapModeToSdl(desc.mipmap_mode);
        create_info.address_mode_u = samplerAddressModeToSdl(desc.address_mode_u);
        create_info.address_mode_v = samplerAddressModeToSdl(desc.address_mode_v);
        create_info.address_mode_w = samplerAddressModeToSdl(desc.address_mode_w);
        create_info.mip_lod_bias = desc.mip_lod_bias;
        create_info.max_anisotropy = desc.max_anisotropy;
        create_info.compare_op = compareOpToSdl(desc.compare_op);
        create_info.min_lod = desc.min_lod;
        create_info.max_lod = desc.max_lod;
        create_info.enable_anisotropy = desc.enable_anisotropy;
        create_info.enable_compare = desc.enable_compare;

        const sampler = sdl.SDL_CreateGPUSampler(self.raw, &create_info);
        if (sampler == null) {
            std.log.err("SDL_CreateGPUSampler failed: {s}", .{window_mod.lastError()});
            return error.SamplerCreateFailed;
        }

        return .{
            .raw = sampler.?,
            .desc = desc,
        };
    }

    pub fn releaseSampler(self: *RhiDevice, sampler: *Sampler) void {
        sdl.SDL_ReleaseGPUSampler(self.raw, sampler.raw);
        sampler.* = undefined;
    }

    pub fn createGraphicsPipeline(self: *RhiDevice, desc: GraphicsPipelineDesc) Error!GraphicsPipeline {
        const vertex_layouts = self.allocator.alloc(sdl.SDL_GPUVertexBufferDescription, desc.vertex_buffer_layouts.len) catch {
            return error.OutOfMemory;
        };
        defer self.allocator.free(vertex_layouts);

        for (desc.vertex_buffer_layouts, 0..) |layout, index| {
            vertex_layouts[index] = .{
                .slot = layout.slot,
                .pitch = layout.stride,
                .input_rate = vertexInputRateToSdl(layout.input_rate),
                .instance_step_rate = 0,
            };
        }

        const vertex_attributes = self.allocator.alloc(sdl.SDL_GPUVertexAttribute, desc.vertex_attributes.len) catch {
            return error.OutOfMemory;
        };
        defer self.allocator.free(vertex_attributes);

        for (desc.vertex_attributes, 0..) |attribute, index| {
            vertex_attributes[index] = .{
                .location = attribute.location,
                .buffer_slot = attribute.buffer_slot,
                .format = vertexElementFormatToSdl(attribute.format),
                .offset = attribute.offset,
            };
        }

        var color_target = std.mem.zeroes(sdl.SDL_GPUColorTargetDescription);
        var create_info = std.mem.zeroes(sdl.SDL_GPUGraphicsPipelineCreateInfo);
        create_info.vertex_shader = desc.vertex_shader.raw;
        create_info.fragment_shader = desc.fragment_shader.raw;
        create_info.vertex_input_state.vertex_buffer_descriptions = if (vertex_layouts.len == 0) null else vertex_layouts.ptr;
        create_info.vertex_input_state.num_vertex_buffers = @intCast(vertex_layouts.len);
        create_info.vertex_input_state.vertex_attributes = if (vertex_attributes.len == 0) null else vertex_attributes.ptr;
        create_info.vertex_input_state.num_vertex_attributes = @intCast(vertex_attributes.len);
        create_info.primitive_type = primitiveTypeToSdl(desc.primitive_type);
        create_info.rasterizer_state.fill_mode = fillModeToSdl(desc.fill_mode);
        create_info.rasterizer_state.cull_mode = cullModeToSdl(desc.cull_mode);
        create_info.rasterizer_state.front_face = frontFaceToSdl(desc.front_face);
        create_info.rasterizer_state.enable_depth_clip = true;
        create_info.multisample_state.sample_count = sdl.SDL_GPU_SAMPLECOUNT_1;
        create_info.depth_stencil_state.compare_op = compareOpToSdl(desc.depth_compare);
        create_info.depth_stencil_state.enable_depth_test = desc.depth_test;
        create_info.depth_stencil_state.enable_depth_write = desc.depth_write;

        if (desc.color_format) |color_format| {
            color_target.format = textureFormatToSdl(color_format);
            create_info.target_info.color_target_descriptions = &color_target;
            create_info.target_info.num_color_targets = 1;
        } else {
            create_info.target_info.color_target_descriptions = null;
            create_info.target_info.num_color_targets = 0;
        }
        if (desc.depth_format) |depth_format| {
            create_info.target_info.depth_stencil_format = textureFormatToSdl(depth_format);
            create_info.target_info.has_depth_stencil_target = depth_format != .unknown;
        }

        const pipeline = sdl.SDL_CreateGPUGraphicsPipeline(self.raw, &create_info);
        if (pipeline == null) {
            std.log.err("SDL_CreateGPUGraphicsPipeline failed: {s}", .{window_mod.lastError()});
            return error.PipelineCreateFailed;
        }

        return .{
            .raw = pipeline.?,
        };
    }

    pub fn releaseGraphicsPipeline(self: *RhiDevice, pipeline: *GraphicsPipeline) void {
        sdl.SDL_ReleaseGPUGraphicsPipeline(self.raw, pipeline.raw);
        pipeline.* = undefined;
    }

    pub fn createBindGroup(self: *RhiDevice, desc: BindGroupDesc) Error!BindGroup {
        const texture_sampler_bindings = self.allocator.alloc(sdl.SDL_GPUTextureSamplerBinding, desc.texture_sampler_bindings.len) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(texture_sampler_bindings);

        for (desc.texture_sampler_bindings, 0..) |binding, index| {
            texture_sampler_bindings[index] = .{
                .texture = binding.texture.raw,
                .sampler = binding.sampler.raw,
            };
        }

        const storage_buffers = self.allocator.alloc(*sdl.SDL_GPUBuffer, desc.storage_buffers.len) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(storage_buffers);

        for (desc.storage_buffers, 0..) |buffer, index| {
            storage_buffers[index] = buffer.raw;
        }

        const storage_textures = self.allocator.alloc(*sdl.SDL_GPUTexture, desc.storage_textures.len) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(storage_textures);

        for (desc.storage_textures, 0..) |texture, index| {
            storage_textures[index] = texture.raw;
        }

        return .{
            .stage = desc.stage,
            .texture_sampler_bindings = texture_sampler_bindings,
            .storage_buffers = storage_buffers,
            .storage_textures = storage_textures,
            .slot_offset = desc.slot_offset,
        };
    }

    pub fn releaseBindGroup(self: *RhiDevice, bind_group: *BindGroup) void {
        self.allocator.free(bind_group.texture_sampler_bindings);
        self.allocator.free(bind_group.storage_buffers);
        self.allocator.free(bind_group.storage_textures);
        bind_group.* = undefined;
    }

    pub fn bindGraphicsPipeline(_: *RhiDevice, pass: RenderPass, pipeline: *const GraphicsPipeline) void {
        sdl.SDL_BindGPUGraphicsPipeline(pass.raw, pipeline.raw);
    }

    pub fn bindVertexBuffer(_: *RhiDevice, pass: RenderPass, slot: u32, buffer: *const Buffer, offset: u32) void {
        var binding = sdl.SDL_GPUBufferBinding{
            .buffer = buffer.raw,
            .offset = offset,
        };
        sdl.SDL_BindGPUVertexBuffers(pass.raw, slot, &binding, 1);
    }

    pub fn bindIndexBuffer(_: *RhiDevice, pass: RenderPass, buffer: *const Buffer, index_size: types.IndexElementSize, offset: u32) void {
        var binding = sdl.SDL_GPUBufferBinding{
            .buffer = buffer.raw,
            .offset = offset,
        };
        sdl.SDL_BindGPUIndexBuffer(pass.raw, &binding, indexElementSizeToSdl(index_size));
    }

    pub fn bindGroup(_: *RhiDevice, pass: RenderPass, bind_group: *const BindGroup) void {
        switch (bind_group.stage) {
            .vertex => {
                if (bind_group.texture_sampler_bindings.len > 0) {
                    sdl.SDL_BindGPUVertexSamplers(pass.raw, bind_group.slot_offset, bind_group.texture_sampler_bindings.ptr, @intCast(bind_group.texture_sampler_bindings.len));
                }
                if (bind_group.storage_textures.len > 0) {
                    sdl.SDL_BindGPUVertexStorageTextures(pass.raw, bind_group.slot_offset, bind_group.storage_textures.ptr, @intCast(bind_group.storage_textures.len));
                }
                if (bind_group.storage_buffers.len > 0) {
                    sdl.SDL_BindGPUVertexStorageBuffers(pass.raw, bind_group.slot_offset, bind_group.storage_buffers.ptr, @intCast(bind_group.storage_buffers.len));
                }
            },
            .fragment => {
                if (bind_group.texture_sampler_bindings.len > 0) {
                    sdl.SDL_BindGPUFragmentSamplers(pass.raw, bind_group.slot_offset, bind_group.texture_sampler_bindings.ptr, @intCast(bind_group.texture_sampler_bindings.len));
                }
                if (bind_group.storage_textures.len > 0) {
                    sdl.SDL_BindGPUFragmentStorageTextures(pass.raw, bind_group.slot_offset, bind_group.storage_textures.ptr, @intCast(bind_group.storage_textures.len));
                }
                if (bind_group.storage_buffers.len > 0) {
                    sdl.SDL_BindGPUFragmentStorageBuffers(pass.raw, bind_group.slot_offset, bind_group.storage_buffers.ptr, @intCast(bind_group.storage_buffers.len));
                }
            },
        }
    }

    pub fn pushVertexUniformData(_: *RhiDevice, frame: Frame, slot: u32, data: []const u8) void {
        sdl.SDL_PushGPUVertexUniformData(frame.command_buffer, slot, data.ptr, @intCast(data.len));
    }

    pub fn pushFragmentUniformData(_: *RhiDevice, frame: Frame, slot: u32, data: []const u8) void {
        sdl.SDL_PushGPUFragmentUniformData(frame.command_buffer, slot, data.ptr, @intCast(data.len));
    }

    pub fn drawPrimitives(_: *RhiDevice, pass: RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        sdl.SDL_DrawGPUPrimitives(pass.raw, vertex_count, instance_count, first_vertex, first_instance);
    }

    pub fn drawIndexedPrimitives(_: *RhiDevice, pass: RenderPass, index_count: u32, instance_count: u32, first_index: u32, vertex_offset: i32, first_instance: u32) void {
        sdl.SDL_DrawGPUIndexedPrimitives(pass.raw, index_count, instance_count, first_index, vertex_offset, first_instance);
    }

    pub fn uploadBufferData(self: *RhiDevice, buffer: *const Buffer, data: []const u8) Error!void {
        var transfer_buffer = try self.createTransferBuffer(.{
            .size = @intCast(data.len),
            .upload = true,
        });
        defer self.releaseTransferBuffer(&transfer_buffer);

        const mapped = sdl.SDL_MapGPUTransferBuffer(self.raw, transfer_buffer.raw, false) orelse {
            std.log.err("SDL_MapGPUTransferBuffer failed: {s}", .{window_mod.lastError()});
            return error.TransferBufferMapFailed;
        };
        const bytes: [*]u8 = @ptrCast(mapped);
        @memcpy(bytes[0..data.len], data);
        sdl.SDL_UnmapGPUTransferBuffer(self.raw, transfer_buffer.raw);

        const command_buffer = sdl.SDL_AcquireGPUCommandBuffer(self.raw) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferAcquireFailed;
        };
        errdefer _ = sdl.SDL_CancelGPUCommandBuffer(command_buffer);

        const copy_pass = sdl.SDL_BeginGPUCopyPass(command_buffer) orelse {
            std.log.err("SDL_BeginGPUCopyPass failed: {s}", .{window_mod.lastError()});
            return error.CopyPassBeginFailed;
        };

        var source = sdl.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer_buffer.raw,
            .offset = 0,
        };
        var destination = sdl.SDL_GPUBufferRegion{
            .buffer = buffer.raw,
            .offset = 0,
            .size = @intCast(data.len),
        };
        sdl.SDL_UploadToGPUBuffer(copy_pass, &source, &destination, false);
        sdl.SDL_EndGPUCopyPass(copy_pass);

        if (!sdl.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            std.log.err("SDL_SubmitGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferSubmitFailed;
        }

        _ = sdl.SDL_WaitForGPUIdle(self.raw);
    }

    pub fn uploadTextureData(
        self: *RhiDevice,
        texture: *const Texture,
        data: []const u8,
        pixels_per_row: u32,
        rows_per_layer: u32,
    ) Error!void {
        var transfer_buffer = try self.createTransferBuffer(.{
            .size = @intCast(data.len),
            .upload = true,
        });
        defer self.releaseTransferBuffer(&transfer_buffer);

        const mapped = sdl.SDL_MapGPUTransferBuffer(self.raw, transfer_buffer.raw, false) orelse {
            std.log.err("SDL_MapGPUTransferBuffer failed: {s}", .{window_mod.lastError()});
            return error.TransferBufferMapFailed;
        };
        const bytes: [*]u8 = @ptrCast(mapped);
        @memcpy(bytes[0..data.len], data);
        sdl.SDL_UnmapGPUTransferBuffer(self.raw, transfer_buffer.raw);

        const command_buffer = sdl.SDL_AcquireGPUCommandBuffer(self.raw) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferAcquireFailed;
        };
        errdefer _ = sdl.SDL_CancelGPUCommandBuffer(command_buffer);

        const copy_pass = sdl.SDL_BeginGPUCopyPass(command_buffer) orelse {
            std.log.err("SDL_BeginGPUCopyPass failed: {s}", .{window_mod.lastError()});
            return error.CopyPassBeginFailed;
        };

        var source = sdl.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer.raw,
            .offset = 0,
            .pixels_per_row = pixels_per_row,
            .rows_per_layer = rows_per_layer,
        };
        var destination = sdl.SDL_GPUTextureRegion{
            .texture = texture.raw,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = texture.desc.width,
            .h = texture.desc.height,
            .d = 1,
        };
        sdl.SDL_UploadToGPUTexture(copy_pass, &source, &destination, false);
        sdl.SDL_EndGPUCopyPass(copy_pass);

        if (!sdl.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            std.log.err("SDL_SubmitGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferSubmitFailed;
        }

        _ = sdl.SDL_WaitForGPUIdle(self.raw);
    }

    pub fn downloadTexturePixel(
        _: *RhiDevice,
        pass: CopyPass,
        texture: *const Texture,
        transfer_buffer: *const TransferBuffer,
        x: u32,
        y: u32,
    ) void {
        var source = sdl.SDL_GPUTextureRegion{
            .texture = texture.raw,
            .mip_level = 0,
            .layer = 0,
            .x = x,
            .y = y,
            .z = 0,
            .w = 1,
            .h = 1,
            .d = 1,
        };
        var destination = sdl.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer.raw,
            .offset = 0,
            .pixels_per_row = 1,
            .rows_per_layer = 1,
        };
        sdl.SDL_DownloadFromGPUTexture(pass.raw, &source, &destination);
    }

    pub fn readTransferBufferBytes(
        self: *RhiDevice,
        transfer_buffer: *const TransferBuffer,
        destination: []u8,
    ) Error!void {
        std.debug.assert(destination.len <= transfer_buffer.desc.size);

        const mapped = sdl.SDL_MapGPUTransferBuffer(self.raw, transfer_buffer.raw, false) orelse {
            std.log.err("SDL_MapGPUTransferBuffer failed: {s}", .{window_mod.lastError()});
            return error.TransferBufferMapFailed;
        };
        defer sdl.SDL_UnmapGPUTransferBuffer(self.raw, transfer_buffer.raw);

        const bytes: [*]u8 = @ptrCast(mapped);
        @memcpy(destination, bytes[0..destination.len]);
    }

    pub fn readTexturePixel(self: *RhiDevice, texture: *const Texture, x: u32, y: u32) Error![4]u8 {
        var transfer_buffer = try self.createTransferBuffer(.{
            .size = 4,
            .upload = false,
        });
        defer self.releaseTransferBuffer(&transfer_buffer);

        const command_buffer = sdl.SDL_AcquireGPUCommandBuffer(self.raw) orelse {
            std.log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferAcquireFailed;
        };
        errdefer _ = sdl.SDL_CancelGPUCommandBuffer(command_buffer);

        const copy_pass = try self.beginCopyPass(.{
            .command_buffer = command_buffer,
            .swapchain_texture = null,
            .width = 0,
            .height = 0,
        });
        self.downloadTexturePixel(copy_pass, texture, &transfer_buffer, x, y);
        self.endCopyPass(copy_pass);

        if (!sdl.SDL_SubmitGPUCommandBuffer(command_buffer)) {
            std.log.err("SDL_SubmitGPUCommandBuffer failed: {s}", .{window_mod.lastError()});
            return error.CommandBufferSubmitFailed;
        }

        _ = sdl.SDL_WaitForGPUIdle(self.raw);

        var pixel: [4]u8 = undefined;
        try self.readTransferBufferBytes(&transfer_buffer, pixel[0..]);
        return pixel;
    }

    fn releaseDepthTexture(self: *RhiDevice) void {
        if (self.depth_texture) |depth_texture| {
            var copy = depth_texture;
            self.releaseTexture(&copy);
        }
        self.depth_texture = null;
    }

    fn refreshRuntimeInfo(self: *RhiDevice, drawable_width: u32, drawable_height: u32) void {
        self.runtime_info.drawable_width = drawable_width;
        self.runtime_info.drawable_height = drawable_height;
        self.runtime_info.swapchain_format = textureFormatFromSdl(sdl.SDL_GetGPUSwapchainTextureFormat(self.raw, self.window));
        self.runtime_info.depth_format = .d32_float;

        const driver_name = sdl.SDL_GetGPUDeviceDriver(self.raw);
        copyCString(self.runtime_info.driver_name[0..], driver_name);

        const props = sdl.SDL_GetGPUDeviceProperties(self.raw);
        const device_name = sdl.SDL_GetStringProperty(props, sdl.SDL_PROP_GPU_DEVICE_NAME_STRING, "");
        const driver_info = sdl.SDL_GetStringProperty(props, sdl.SDL_PROP_GPU_DEVICE_DRIVER_INFO_STRING, "");
        copyCString(self.runtime_info.device_name[0..], device_name);
        copyCString(self.runtime_info.driver_info[0..], driver_info);
    }
};

fn createDevice(platform: platform_mod.Platform, config: types.DeviceConfig) Error!struct {
    raw: *sdl.SDL_GPUDevice,
    api: types.GraphicsAPI,
} {
    const candidates = candidateOrder(platform, config.preferred_backends, config.selection_policy);
    for (candidates) |api| {
        const spec = driverSpec(api);
        const props = try createDeviceProperties(spec, config);
        defer sdl.SDL_DestroyProperties(props);

        if (!sdl.SDL_GPUSupportsProperties(props)) {
            continue;
        }

        const raw = sdl.SDL_CreateGPUDeviceWithProperties(props);
        if (raw != null) {
            return .{
                .raw = raw.?,
                .api = api,
            };
        }

        std.log.warn("Unable to create {s} GPU device: {s}", .{ spec.driver_name, window_mod.lastError() });
    }

    return error.UnsupportedBackend;
}

fn createDeviceProperties(spec: DriverSpec, config: types.DeviceConfig) Error!sdl.SDL_PropertiesID {
    const props = sdl.SDL_CreateProperties();
    if (props == 0) {
        std.log.err("SDL_CreateProperties failed: {s}", .{window_mod.lastError()});
        return error.DeviceCreateFailed;
    }

    _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, config.enable_validation);
    _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_PREFERLOWPOWER_BOOLEAN, config.prefer_low_power);
    _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_VERBOSE_BOOLEAN, true);
    _ = sdl.SDL_SetStringProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_NAME_STRING, spec.driver_name.ptr);

    switch (spec.api) {
        .vulkan => {
            _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
            _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_VULKAN_REQUIRE_HARDWARE_ACCELERATION_BOOLEAN, true);
        },
        .metal => {
            _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true);
        },
        .dx12 => {
            _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_DXIL_BOOLEAN, true);
        },
    }

    return props;
}

fn candidateOrder(
    platform: platform_mod.Platform,
    preferred: []const types.GraphicsAPI,
    policy: types.BackendSelectionPolicy,
) []const types.GraphicsAPI {
    if (policy == .explicit_order and preferred.len > 0) {
        return preferred;
    }

    return switch (platform) {
        .windows => &.{ .dx12, .vulkan, .metal },
        .macos, .ios => &.{ .vulkan, .metal, .dx12 },
        .linux, .android => &.{ .vulkan, .dx12, .metal },
        .unknown => if (preferred.len > 0) preferred else &.{ .vulkan, .dx12, .metal },
    };
}

fn driverSpec(api: types.GraphicsAPI) DriverSpec {
    return switch (api) {
        .vulkan => .{
            .api = .vulkan,
            .driver_name = "vulkan",
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_SPIRV,
        },
        .metal => .{
            .api = .metal,
            .driver_name = "metal",
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_MSL,
        },
        .dx12 => .{
            .api = .dx12,
            .driver_name = "direct3d12",
            .shader_format = sdl.SDL_GPU_SHADERFORMAT_DXIL,
        },
    };
}

fn bufferUsageToSdl(usage: u32) sdl.SDL_GPUBufferUsageFlags {
    var result: u32 = 0;
    if ((usage & types.BufferUsage.vertex) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_VERTEX;
    }
    if ((usage & types.BufferUsage.index) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_INDEX;
    }
    if ((usage & types.BufferUsage.indirect) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_INDIRECT;
    }
    if ((usage & types.BufferUsage.graphics_storage_read) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ;
    }
    if ((usage & types.BufferUsage.compute_storage_read) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ;
    }
    if ((usage & types.BufferUsage.compute_storage_write) != 0) {
        result |= sdl.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE;
    }
    return result;
}

fn textureUsageToSdl(usage: u32) sdl.SDL_GPUTextureUsageFlags {
    var result: u32 = 0;
    if ((usage & types.TextureUsage.sampler) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    }
    if ((usage & types.TextureUsage.color_target) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    }
    if ((usage & types.TextureUsage.depth_stencil_target) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
    }
    if ((usage & types.TextureUsage.graphics_storage_read) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ;
    }
    if ((usage & types.TextureUsage.compute_storage_read) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ;
    }
    if ((usage & types.TextureUsage.compute_storage_write) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE;
    }
    if ((usage & types.TextureUsage.compute_storage_rw) != 0) {
        result |= sdl.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE;
    }
    return result;
}

fn loadOpToSdl(op: LoadOp) sdl.SDL_GPULoadOp {
    return switch (op) {
        .load => sdl.SDL_GPU_LOADOP_LOAD,
        .clear => sdl.SDL_GPU_LOADOP_CLEAR,
        .dont_care => sdl.SDL_GPU_LOADOP_DONT_CARE,
    };
}

fn storeOpToSdl(op: StoreOp) sdl.SDL_GPUStoreOp {
    return switch (op) {
        .store => sdl.SDL_GPU_STOREOP_STORE,
        .dont_care => sdl.SDL_GPU_STOREOP_DONT_CARE,
    };
}

fn textureFormatToSdl(format: types.TextureFormat) sdl.SDL_GPUTextureFormat {
    return switch (format) {
        .bgra8_unorm => sdl.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => sdl.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB,
        .d24_unorm => sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM,
        .d24_unorm_s8_uint => sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT,
        .d32_float => sdl.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        .unknown => sdl.SDL_GPU_TEXTUREFORMAT_INVALID,
    };
}

fn textureFormatFromSdl(format: sdl.SDL_GPUTextureFormat) types.TextureFormat {
    return switch (format) {
        sdl.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM => .bgra8_unorm,
        sdl.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB => .bgra8_unorm_srgb,
        sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM => .d24_unorm,
        sdl.SDL_GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT => .d24_unorm_s8_uint,
        sdl.SDL_GPU_TEXTUREFORMAT_D32_FLOAT => .d32_float,
        else => .unknown,
    };
}

fn shaderFormatToSdl(format: types.ShaderFormat) sdl.SDL_GPUShaderFormat {
    return switch (format) {
        .spirv => sdl.SDL_GPU_SHADERFORMAT_SPIRV,
        .dxil => sdl.SDL_GPU_SHADERFORMAT_DXIL,
        .msl => sdl.SDL_GPU_SHADERFORMAT_MSL,
    };
}

fn shaderStageToSdl(stage: types.ShaderStage) sdl.SDL_GPUShaderStage {
    return switch (stage) {
        .vertex => sdl.SDL_GPU_SHADERSTAGE_VERTEX,
        .fragment => sdl.SDL_GPU_SHADERSTAGE_FRAGMENT,
    };
}

fn samplerFilterToSdl(filter: types.SamplerFilter) sdl.SDL_GPUFilter {
    return switch (filter) {
        .nearest => sdl.SDL_GPU_FILTER_NEAREST,
        .linear => sdl.SDL_GPU_FILTER_LINEAR,
    };
}

fn samplerMipmapModeToSdl(mode: types.SamplerMipmapMode) sdl.SDL_GPUSamplerMipmapMode {
    return switch (mode) {
        .nearest => sdl.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .linear => sdl.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
    };
}

fn samplerAddressModeToSdl(mode: types.SamplerAddressMode) sdl.SDL_GPUSamplerAddressMode {
    return switch (mode) {
        .repeat => sdl.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
        .mirrored_repeat => sdl.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT,
        .clamp_to_edge => sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    };
}

fn vertexInputRateToSdl(rate: types.VertexInputRate) sdl.SDL_GPUVertexInputRate {
    return switch (rate) {
        .per_vertex => sdl.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .per_instance => sdl.SDL_GPU_VERTEXINPUTRATE_INSTANCE,
    };
}

fn vertexElementFormatToSdl(format: types.VertexElementFormat) sdl.SDL_GPUVertexElementFormat {
    return switch (format) {
        .float2 => sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
        .float3 => sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
        .float4 => sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
    };
}

fn primitiveTypeToSdl(primitive: types.PrimitiveType) sdl.SDL_GPUPrimitiveType {
    return switch (primitive) {
        .triangle_list => sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .triangle_strip => sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
        .line_list => sdl.SDL_GPU_PRIMITIVETYPE_LINELIST,
        .line_strip => sdl.SDL_GPU_PRIMITIVETYPE_LINESTRIP,
        .point_list => sdl.SDL_GPU_PRIMITIVETYPE_POINTLIST,
    };
}

fn fillModeToSdl(mode: types.FillMode) sdl.SDL_GPUFillMode {
    return switch (mode) {
        .fill => sdl.SDL_GPU_FILLMODE_FILL,
        .line => sdl.SDL_GPU_FILLMODE_LINE,
    };
}

fn cullModeToSdl(mode: types.CullMode) sdl.SDL_GPUCullMode {
    return switch (mode) {
        .none => sdl.SDL_GPU_CULLMODE_NONE,
        .front => sdl.SDL_GPU_CULLMODE_FRONT,
        .back => sdl.SDL_GPU_CULLMODE_BACK,
    };
}

fn frontFaceToSdl(front_face: types.FrontFace) sdl.SDL_GPUFrontFace {
    return switch (front_face) {
        .counter_clockwise => sdl.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        .clockwise => sdl.SDL_GPU_FRONTFACE_CLOCKWISE,
    };
}

fn compareOpToSdl(compare: types.CompareOp) sdl.SDL_GPUCompareOp {
    return switch (compare) {
        .never => sdl.SDL_GPU_COMPAREOP_NEVER,
        .less => sdl.SDL_GPU_COMPAREOP_LESS,
        .equal => sdl.SDL_GPU_COMPAREOP_EQUAL,
        .less_or_equal => sdl.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
        .greater => sdl.SDL_GPU_COMPAREOP_GREATER,
        .not_equal => sdl.SDL_GPU_COMPAREOP_NOT_EQUAL,
        .greater_or_equal => sdl.SDL_GPU_COMPAREOP_GREATER_OR_EQUAL,
        .always => sdl.SDL_GPU_COMPAREOP_ALWAYS,
    };
}

fn indexElementSizeToSdl(index_size: types.IndexElementSize) sdl.SDL_GPUIndexElementSize {
    return switch (index_size) {
        .u16 => sdl.SDL_GPU_INDEXELEMENTSIZE_16BIT,
        .u32 => sdl.SDL_GPU_INDEXELEMENTSIZE_32BIT,
    };
}

fn sampleCountToSdl(sample_count: u32) sdl.SDL_GPUSampleCount {
    return switch (sample_count) {
        1 => sdl.SDL_GPU_SAMPLECOUNT_1,
        2 => sdl.SDL_GPU_SAMPLECOUNT_2,
        4 => sdl.SDL_GPU_SAMPLECOUNT_4,
        8 => sdl.SDL_GPU_SAMPLECOUNT_8,
        else => sdl.SDL_GPU_SAMPLECOUNT_1,
    };
}

fn copyCString(buffer: []u8, source: ?[*:0]const u8) void {
    @memset(buffer, 0);
    if (source == null or buffer.len == 0) {
        return;
    }

    const slice = std.mem.sliceTo(source.?, 0);
    const len = @min(buffer.len - 1, slice.len);
    @memcpy(buffer[0..len], slice[0..len]);
}
