const std = @import("std");
const rhi = @import("../rhi.zig");
const command_buffer = @import("../command_buffer.zig");
const queue_mod = @import("../queue.zig");

pub const MetalBackend = struct {
    allocator: std.mem.Allocator,
    next_swapchain_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) MetalBackend {
        return .{ .allocator = allocator };
    }

    pub fn createDevice(self: *MetalBackend) rhi.Device {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &device_vtable,
            .capabilities = .{
                .compute = true,
                .ray_tracing = true,
                .indirect_draw = true,
                .mesh_shaders = false,
                .texture_3d = true,
                .texture_cube_native = true,
                .max_queues = .{ 1, 1, 1 },
            },
        };
    }

    pub fn translateAndSubmit(self: *MetalBackend, queue_class: rhi.QueueClass, soft_buf: *const command_buffer.CommandBuffer) !void {
        _ = self;
        _ = queue_class;

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
                .pipeline_barrier => |_| {},
            }
        }
    }
};

fn submitQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.graphics, cmd);
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
        .graphics => .{ .class = .graphics, .ctx = ctx, .submit_fn = submitQueue },
        .compute => .{ .class = .compute, .ctx = ctx, .submit_fn = submitQueue },
        .transfer => .{ .class = .transfer, .ctx = ctx, .submit_fn = submitQueue },
    };
}

const device_vtable = rhi.DeviceVTable{
    .create_command_buffer = createCommandBuffer,
    .acquire_swapchain_image = acquireSwapchainImage,
    .submit_command_buffer = submitCommandBuffer,
    .present = present,
    .get_queue = getQueue,
};
