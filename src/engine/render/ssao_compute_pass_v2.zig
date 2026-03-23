const std = @import("std");
const rhi = @import("../rhi/rhi.zig");
const render_graph = @import("render_graph.zig");
const metal_backend = @import("../rhi/metal/metal_backend.zig");

pub const SSAOComputePassV2 = struct {
    pub fn dispatchRhiV2(
        allocator: std.mem.Allocator,
        device: *const rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        output_resource_id: u32,
        group_x: u32,
        group_y: u32,
    ) !void {
        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        try cmd.encodeBeginComputePass(.{});
        try cmd.encodeDispatch(.{ .x = group_x, .y = group_y, .z = 1 });
        try cmd.encodeEndComputePass();

        try cmd.encodePipelineBarrier(.{
            .resource_id = output_resource_id,
            .src_state_bits = (rhi.ResourceStates{ .unordered_access = true }).asBits(),
            .dst_state_bits = (rhi.ResourceStates{ .shader_resource = true }).asBits(),
            .src_queue = @intCast(@intFromEnum(rhi.QueueClass.compute)),
            .dst_queue = @intCast(@intFromEnum(rhi.QueueClass.graphics)),
        });

        try device.submitCommandBuffer(.compute, &cmd, .{});
    }
};

test "ssao compute pass v2 submits on compute queue" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    try SSAOComputePassV2.dispatchRhiV2(std.testing.allocator, &device, null, 501, 16, 9);
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}
