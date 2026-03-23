const std = @import("std");

const metal_backend = @import("rhi/metal/metal_backend.zig");
const rhi = @import("rhi/rhi.zig");
const ssao_v2 = @import("render/ssao_compute_pass_v2.zig");

test "metal backend compute queue submission path" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();

    try cmd.encodeBeginComputePass(.{});
    try cmd.encodeDispatch(.{ .x = 1, .y = 1, .z = 1 });
    try cmd.encodeEndComputePass();

    try device.submitCommandBuffer(.compute, &cmd, .{});
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}

test "ssao compute pass v2 integration" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try ssao_v2.SSAOComputePassV2.dispatch(std.testing.allocator, &device, null, 3001, 8, 8);
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}
