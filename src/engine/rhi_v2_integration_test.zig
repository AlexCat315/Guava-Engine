const std = @import("std");

const metal_backend = @import("rhi/metal/metal_backend.zig");
const rhi = @import("rhi/rhi.zig");
const binding_cache = @import("rhi/binding_cache.zig");
const ssao_v2 = @import("render/ssao_compute_pass_v2.zig");
const fullscreen_post_v2 = @import("render/fullscreen_post_pass_v2.zig");
const render_graph = @import("render/render_graph.zig");

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

    try ssao_v2.SSAOComputePassV2.dispatchRhiV2(std.testing.allocator, &device, null, 3001, 8, 8);
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}

test "fullscreen post pass v2 submits on graphics queue" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try fullscreen_post_v2.FullscreenPostPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        4001,
        4002,
    );

    try std.testing.expectEqual(rhi.QueueClass.graphics, backend.last_submit_queue.?);
}

test "binding set cache tracks hit and miss stats" {
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

    // First call: miss
    _ = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });
    const s1 = device.bindingSetCacheStats();
    try std.testing.expectEqual(@as(u64, 0), s1.hits);
    try std.testing.expectEqual(@as(u64, 1), s1.misses);

    // Second call: hit (same layout + resources)
    _ = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });
    const s2 = device.bindingSetCacheStats();
    try std.testing.expectEqual(@as(u64, 1), s2.hits);
    try std.testing.expectEqual(@as(u64, 1), s2.misses);
    try std.testing.expect(s2.hitRate() > 0.49);

    // Reset
    device.resetBindingSetCacheStats();
    const s3 = device.bindingSetCacheStats();
    try std.testing.expectEqual(@as(u64, 0), s3.hits);
    try std.testing.expectEqual(@as(u64, 0), s3.misses);
}

test "render graph slot-layout constraint validation passes with matching layout" {
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
    _ = try device.resolvePipelineLayout(&.{layout});

    var graph = render_graph.RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addResource(.{ .name = "Color", .kind = .scene_color });
    try graph.addPass(.{
        .name = "PostFX",
        .kind = .post_process,
        .binding_constraints = &.{.{ .slot = 0, .expected_layout_id = layout.id }},
    });
    try graph.compile();

    const errors = try graph.validateSlotLayoutConstraints(std.testing.allocator, &device);
    defer std.testing.allocator.free(errors);
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "render graph slot-layout constraint validation catches missing layout" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    var graph = render_graph.RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addResource(.{ .name = "Color", .kind = .scene_color });
    try graph.addPass(.{
        .name = "BadPass",
        .kind = .post_process,
        .binding_constraints = &.{.{ .slot = 0, .expected_layout_id = 9999 }},
    });
    try graph.compile();

    const errors = try graph.validateSlotLayoutConstraints(std.testing.allocator, &device);
    defer std.testing.allocator.free(errors);
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("BadPass", errors[0].pass_name);
}
