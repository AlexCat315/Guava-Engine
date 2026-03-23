const std = @import("std");
const rhi = @import("../rhi.zig");
const command_buffer = @import("../command_buffer.zig");
const queue_mod = @import("../queue.zig");

pub const MetalBackend = struct {
    allocator: std.mem.Allocator,
    next_swapchain_id: u32 = 1,
    next_buffer_id: u32 = 1,
    next_texture_id: u32 = 1,
    next_shader_module_id: u32 = 1,
    next_graphics_pipeline_id: u32 = 1,
    next_compute_pipeline_id: u32 = 1,
    next_sampler_id: u32 = 1,
    resource_state_bits: std.AutoHashMap(u32, u32),
    resource_owner_queue: std.AutoHashMap(u32, rhi.QueueClass),
    last_submit_queue: ?rhi.QueueClass = null,

    pub fn init(allocator: std.mem.Allocator) MetalBackend {
        return .{
            .allocator = allocator,
            .resource_state_bits = std.AutoHashMap(u32, u32).init(allocator),
            .resource_owner_queue = std.AutoHashMap(u32, rhi.QueueClass).init(allocator),
        };
    }

    pub fn deinit(self: *MetalBackend) void {
        self.resource_state_bits.deinit();
        self.resource_owner_queue.deinit();
        self.* = undefined;
    }

    pub fn createDevice(self: *MetalBackend) rhi.Device {
        return rhi.Device.initWithCache(
            @ptrCast(self),
            &device_vtable,
            .{
                .compute = true,
                .ray_tracing = true,
                .indirect_draw = true,
                .mesh_shaders = false,
                .texture_3d = true,
                .texture_cube_native = true,
                .max_queues = .{ 1, 1, 1 },
            },
            self.allocator,
        );
    }

    pub fn translateAndSubmit(self: *MetalBackend, queue_class: rhi.QueueClass, soft_buf: *const command_buffer.CommandBuffer) !void {
        self.last_submit_queue = queue_class;

        var decoder = soft_buf.decoder();
        while (try decoder.next()) |cmd| {
            switch (cmd) {
                .begin_render_pass => |_| {},
                .end_render_pass => {},
                .begin_compute_pass => |_| {},
                .end_compute_pass => {},
                .begin_copy_pass => |_| {},
                .end_copy_pass => {},
                .set_binding_set => |_| {},
                .draw_indexed => |_| {},
                .draw_indirect => |_| {},
                .dispatch => |_| {},
                .dispatch_indirect => |_| {},
                .pipeline_barrier => |b| {
                    const prev_state = self.resource_state_bits.get(b.resource_id) orelse 0;
                    if (prev_state != 0 and prev_state != b.src_state_bits) {
                        return error.SubmitFailed;
                    }
                    try self.resource_state_bits.put(b.resource_id, b.dst_state_bits);

                    const src_q: rhi.QueueClass = @enumFromInt(@as(u8, b.src_queue));
                    const dst_q: rhi.QueueClass = @enumFromInt(@as(u8, b.dst_queue));
                    const owner = self.resource_owner_queue.get(b.resource_id) orelse src_q;
                    if (owner != src_q) return error.SubmitFailed;
                    try self.resource_owner_queue.put(b.resource_id, dst_q);
                },
            }
        }
    }
};

fn createBuffer(ctx: *anyopaque, desc: rhi.BufferDesc) rhi.Error!rhi.Buffer {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_buffer_id;
    backend.next_buffer_id += 1;
    return .{ .id = id };
}

fn createTexture(ctx: *anyopaque, desc: rhi.TextureDesc) rhi.Error!rhi.Texture {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_texture_id;
    backend.next_texture_id += 1;
    return .{ .id = id };
}

fn destroyBuffer(ctx: *anyopaque, buffer: rhi.Buffer) void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    _ = backend.resource_state_bits.remove(buffer.id);
    _ = backend.resource_owner_queue.remove(buffer.id);
}

fn destroyTexture(ctx: *anyopaque, texture: rhi.Texture) void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    _ = backend.resource_state_bits.remove(texture.id);
    _ = backend.resource_owner_queue.remove(texture.id);
}

fn submitGraphicsQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.graphics, cmd);
}

fn submitComputeQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.compute, cmd);
}

fn submitTransferQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.transfer, cmd);
}

fn createCommandBuffer(ctx: *anyopaque, allocator: std.mem.Allocator) rhi.Error!command_buffer.CommandBuffer {
    _ = ctx;
    return command_buffer.CommandBuffer.init(allocator);
}

fn acquireSwapchainImage(ctx: *anyopaque) rhi.Error!rhi.SwapchainImage {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_swapchain_id;
    backend.next_swapchain_id += 1;
    return .{ .id = id, .width = 1280, .height = 720 };
}

fn submitCommandBuffer(
    ctx: *anyopaque,
    queue_class: rhi.QueueClass,
    cmd: *const command_buffer.CommandBuffer,
    desc: rhi.SubmitDesc,
) rhi.Error!void {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    backend.translateAndSubmit(queue_class, cmd) catch return error.SubmitFailed;
}

fn present(ctx: *anyopaque, image: rhi.SwapchainImage) rhi.Error!void {
    _ = ctx;
    _ = image;
}

fn getQueue(ctx: *anyopaque, class: rhi.QueueClass) rhi.Error!rhi.Queue {
    _ = @as(*MetalBackend, @ptrCast(@alignCast(ctx)));
    return switch (class) {
        .graphics => .{ .class = .graphics, .ctx = ctx, .submit_fn = submitGraphicsQueue },
        .compute => .{ .class = .compute, .ctx = ctx, .submit_fn = submitComputeQueue },
        .transfer => .{ .class = .transfer, .ctx = ctx, .submit_fn = submitTransferQueue },
    };
}

fn createShaderModule(ctx: *anyopaque, desc: rhi.ShaderModuleDesc) rhi.Error!rhi.ShaderModule {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_shader_module_id;
    backend.next_shader_module_id += 1;
    return .{ .id = id };
}

fn createGraphicsPipeline(ctx: *anyopaque, desc: rhi.GraphicsPipelineDesc) rhi.Error!rhi.GraphicsPipeline {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_graphics_pipeline_id;
    backend.next_graphics_pipeline_id += 1;
    return .{ .id = id };
}

fn createComputePipeline(ctx: *anyopaque, desc: rhi.ComputePipelineDesc) rhi.Error!rhi.ComputePipeline {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_compute_pipeline_id;
    backend.next_compute_pipeline_id += 1;
    return .{ .id = id };
}

fn destroyGraphicsPipeline(ctx: *anyopaque, pipeline: rhi.GraphicsPipeline) void {
    _ = ctx;
    _ = pipeline;
}

fn destroyComputePipeline(ctx: *anyopaque, pipeline: rhi.ComputePipeline) void {
    _ = ctx;
    _ = pipeline;
}

fn createSampler(ctx: *anyopaque, desc: rhi.SamplerDesc) rhi.Error!rhi.Sampler {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_sampler_id;
    backend.next_sampler_id += 1;
    return .{ .id = id };
}

fn destroySampler(ctx: *anyopaque, sampler: rhi.Sampler) void {
    _ = ctx;
    _ = sampler;
}

fn uploadBufferData(ctx: *anyopaque, buffer: rhi.Buffer, offset: u64, data: []const u8) rhi.Error!void {
    _ = ctx;
    _ = buffer;
    _ = offset;
    _ = data;
}

const device_vtable = rhi.DeviceVTable{
    .create_buffer = createBuffer,
    .create_texture = createTexture,
    .destroy_buffer = destroyBuffer,
    .destroy_texture = destroyTexture,
    .create_command_buffer = createCommandBuffer,
    .acquire_swapchain_image = acquireSwapchainImage,
    .submit_command_buffer = submitCommandBuffer,
    .present = present,
    .get_queue = getQueue,
    .create_shader_module = createShaderModule,
    .create_graphics_pipeline = createGraphicsPipeline,
    .create_compute_pipeline = createComputePipeline,
    .destroy_graphics_pipeline = destroyGraphicsPipeline,
    .destroy_compute_pipeline = destroyComputePipeline,
    .create_sampler = createSampler,
    .destroy_sampler = destroySampler,
    .upload_buffer_data = uploadBufferData,
};

test "metal backend handles compute queue barrier ownership transfer" {
    var backend = MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();

    try cmd.encodePipelineBarrier(.{
        .resource_id = 99,
        .src_state_bits = 0,
        .dst_state_bits = 1,
        .src_queue = @intCast(@intFromEnum(rhi.QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(rhi.QueueClass.graphics)),
    });

    try device.submitCommandBuffer(.compute, &cmd, .{});
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}
