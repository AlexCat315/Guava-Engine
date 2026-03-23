const std = @import("std");

const metal_backend = @import("rhi/metal/metal_backend.zig");
const rhi = @import("rhi/rhi.zig");
const binding_cache = @import("rhi/binding_cache.zig");
const command_buffer = @import("rhi/command_buffer.zig");
const ssao_v2 = @import("render/ssao_compute_pass_v2.zig");
const fullscreen_post_v2 = @import("render/fullscreen_post_pass_v2.zig");
const bloom_pass_v2 = @import("render/bloom_pass_v2.zig");
const tonemap_pass_v2 = @import("render/tonemap_pass_v2.zig");
const contact_shadow_v2 = @import("render/contact_shadow_pass_v2.zig");
const dof_pass_v2 = @import("render/dof_pass_v2.zig");
const ssr_pass_v2 = @import("render/ssr_pass_v2.zig");
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

test "bloom pass v2 two-set pipeline submission" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try bloom_pass_v2.BloomPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        5001,
        5002,
        .{ .threshold = 0.8, .intensity = 0.5 },
    );
    try std.testing.expectEqual(rhi.QueueClass.graphics, backend.last_submit_queue.?);

    // Verify cache was populated: 2 binding sets created
    try std.testing.expect(device.bindingSetCacheEntryCount() >= 2);
}

test "binding set cache FIFO eviction at capacity" {
    var cache = binding_cache.BindingSetCache.init(std.testing.allocator);
    defer cache.deinit();

    // Fill cache to max_entries
    const max = binding_cache.BindingSetCache.max_entries;
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        try cache.putByHash(@as(u64, i) + 1, cache.nextSyntheticId());
    }
    try std.testing.expectEqual(max, cache.entryCount());
    try std.testing.expectEqual(@as(u64, 0), cache.stats.evictions);

    // One more insert triggers eviction
    try cache.putByHash(999_999, cache.nextSyntheticId());
    try std.testing.expectEqual(max, cache.entryCount());
    try std.testing.expectEqual(@as(u64, 1), cache.stats.evictions);

    // The oldest hash (1) should be gone
    try std.testing.expectEqual(@as(?u32, null), cache.getByHash(1));
    // The newest should be present
    try std.testing.expect(cache.getByHash(999_999) != null);
}

test "tonemap pass v2 three-set pipeline submission" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try tonemap_pass_v2.TonemapPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        6001,
        6002,
        .{},
    );
    try std.testing.expectEqual(rhi.QueueClass.graphics, backend.last_submit_queue.?);

    // 3 binding sets should be cached
    try std.testing.expect(device.bindingSetCacheEntryCount() >= 3);
}

test "setPassBindingConstraints injects constraints into compiled graph" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    const layout_id = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });
    _ = try device.resolvePipelineLayout(&.{layout_id});

    var graph = render_graph.RenderGraph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addResource(.{ .name = "Color", .kind = .scene_color });
    try graph.addPass(.{
        .name = "Tonemap",
        .kind = .tonemap_pass,
    });
    try graph.compile();

    // Before injection: no constraints → no errors (nothing to check)
    const errors_before = try graph.validateSlotLayoutConstraints(std.testing.allocator, &device);
    defer std.testing.allocator.free(errors_before);
    try std.testing.expectEqual(@as(usize, 0), errors_before.len);

    // Inject constraints at runtime
    try graph.setPassBindingConstraints(.tonemap_pass, &.{
        .{ .slot = 0, .expected_layout_id = layout_id.id },
    });

    // After injection with matching layout: still no errors
    const errors_after = try graph.validateSlotLayoutConstraints(std.testing.allocator, &device);
    defer std.testing.allocator.free(errors_after);
    try std.testing.expectEqual(@as(usize, 0), errors_after.len);
}

test "command buffer encode-decode round-trip" {
    var cb = command_buffer.CommandBuffer.init(std.testing.allocator);
    defer cb.deinit();

    // Encode a multi-pass sequence: render pass → compute pass → barrier
    try cb.encodeBeginRenderPass(.{ .color_target_id = 10, .depth_target_id = 20, .clear_mask = 3 });
    try cb.encodeSetBindingSet(.{ .slot = 0, .set_id = 100 });
    try cb.encodeDrawIndexed(.{ .index_count = 36, .instance_count = 1, .first_index = 0, .vertex_offset = 0, .first_instance = 0 });
    try cb.encodeEndRenderPass();
    try cb.encodePipelineBarrier(.{ .resource_id = 10, .src_state_bits = 0x04, .dst_state_bits = 0x10, .src_queue = 0, .dst_queue = 0 });
    try cb.encodeBeginComputePass(.{});
    try cb.encodeSetBindingSet(.{ .slot = 1, .set_id = 200 });
    try cb.encodeDispatch(.{ .x = 8, .y = 8, .z = 1 });
    try cb.encodeEndComputePass();

    // Decode and verify the exact sequence
    var dec = cb.decoder();
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.begin_render_pass, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 10), cmd.begin_render_pass.color_target_id);
        try std.testing.expectEqual(@as(u32, 20), cmd.begin_render_pass.depth_target_id);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.set_binding_set, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 100), cmd.set_binding_set.set_id);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.draw_indexed, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 36), cmd.draw_indexed.index_count);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.end_render_pass, std.meta.activeTag(cmd));
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.pipeline_barrier, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 10), cmd.pipeline_barrier.resource_id);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.begin_compute_pass, std.meta.activeTag(cmd));
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.set_binding_set, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 200), cmd.set_binding_set.set_id);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.dispatch, std.meta.activeTag(cmd));
        try std.testing.expectEqual(@as(u32, 8), cmd.dispatch.x);
    }
    {
        const cmd = (try dec.next()).?;
        try std.testing.expectEqual(command_buffer.OpCode.end_compute_pass, std.meta.activeTag(cmd));
    }
    // No more commands
    try std.testing.expectEqual(@as(?command_buffer.DecodedCommand, null), try dec.next());
}

test "contact shadow pass v2 two-set pipeline submission" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try contact_shadow_v2.ContactShadowPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        7001,
        7002,
        .{},
    );
    try std.testing.expectEqual(rhi.QueueClass.graphics, backend.last_submit_queue.?);
    try std.testing.expect(device.bindingSetCacheEntryCount() >= 2);
}

test "dof pass v2 three-subpass pipeline submission" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try dof_pass_v2.DOFPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        8001,
        8002,
        .{},
    );
    try std.testing.expectEqual(rhi.QueueClass.graphics, backend.last_submit_queue.?);
    // 3 subpasses × unique binding sets
    try std.testing.expect(device.bindingSetCacheEntryCount() >= 3);
}

test "binding set cache per-frame delta stats" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    // Create a layout + binding set to generate a miss
    const layout = try device.createBindingLayout(.{
        .entries = &.{.{ .slot = 0, .binding_type = .texture, .stage = .fragment }},
    });
    _ = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = .{ .id = 50 } } }},
    });

    // Frame 1: snapshot should capture the initial miss
    const delta1 = device.snapshotFrameStats();
    try std.testing.expectEqual(@as(u64, 0), delta1.hits);
    try std.testing.expectEqual(@as(u64, 1), delta1.misses);

    // Frame 2: same binding set → cache hit
    _ = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = .{ .id = 50 } } }},
    });
    const delta2 = device.snapshotFrameStats();
    try std.testing.expectEqual(@as(u64, 1), delta2.hits);
    try std.testing.expectEqual(@as(u64, 0), delta2.misses);

    // Frame 3: no activity → zero delta
    const delta3 = device.snapshotFrameStats();
    try std.testing.expectEqual(@as(u64, 0), delta3.hits);
    try std.testing.expectEqual(@as(u64, 0), delta3.misses);
    try std.testing.expectEqual(@as(u64, 0), delta3.evictions);
}

test "ssr pass v2 four-set pipeline submission" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    try ssr_pass_v2.SSRPassV2.execute(
        std.testing.allocator,
        &device,
        null,
        0,
        0,
        .{},
    );

    const stats = device.bindingSetCacheStats();
    try std.testing.expect(stats.misses >= 4); // 4 binding sets (color, depth, normal, uniform)
}

test "pipeline creation and destruction round-trip" {
    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();

    var device = backend.createDevice();
    defer device.deinit();

    // Create shader modules
    const vert = try device.createShaderModule(.{
        .stage = .vertex,
        .format = .spirv,
        .code = &.{0},
        .entry_point = "main",
    });
    const frag = try device.createShaderModule(.{
        .stage = .fragment,
        .format = .spirv,
        .code = &.{0},
        .entry_point = "main",
    });
    const comp = try device.createShaderModule(.{
        .stage = .compute,
        .format = .spirv,
        .code = &.{0},
        .entry_point = "main",
    });

    // Create a binding layout + pipeline layout for the pipelines
    const layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .uniform_buffer,
            .stage = .fragment,
        }},
        .label = "test_pipeline_layout",
    });
    const pl = try device.resolvePipelineLayout(&.{layout});

    // Create graphics pipeline
    const gfx = try device.createGraphicsPipeline(.{
        .layout = pl,
        .vertex = vert,
        .fragment = frag,
        .color_format = .rgba8_unorm,
    });
    try std.testing.expect(gfx.id > 0);

    // Create compute pipeline
    const cmp = try device.createComputePipeline(.{
        .layout = pl,
        .shader = comp,
    });
    try std.testing.expect(cmp.id > 0);
    try std.testing.expect(cmp.id != gfx.id); // different ID spaces or sequential

    // Destroy — should not panic
    device.destroyGraphicsPipeline(gfx);
    device.destroyComputePipeline(cmp);
}
