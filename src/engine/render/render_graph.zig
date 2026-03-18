const std = @import("std");

pub const QueueClass = enum {
    graphics,
    compute,
    copy,
};

pub const PassKind = enum {
    shadow_map,
    depth_prepass,
    id_pass,
    base_pass,
    skybox_pass,
    lighting,
    transparent,
    post_process,
    tonemap_pass,
    outline_pass,
    gizmo_overlay,
    ui_overlay,
};

pub const ResourceKind = enum {
    shadow_map,
    depth,
    id_buffer,
    scene_color,
    lit_color,
    post_color,
    swapchain,
};

pub const ResourceAccess = enum {
    read,
    write,
    read_write,

    pub fn writes(self: ResourceAccess) bool {
        return self == .write or self == .read_write;
    }
};

pub const ResourceNode = struct {
    name: []const u8,
    kind: ResourceKind,
    external: bool = false,
    transient: bool = true,
};

pub const PassResourceUse = struct {
    resource: u16,
    access: ResourceAccess,
};

pub const RenderPass = struct {
    name: []const u8,
    kind: PassKind,
    queue: QueueClass = .graphics,
    enabled: bool = true,
    inputs: []const PassResourceUse = &.{},
    outputs: []const PassResourceUse = &.{},
};

pub const DependencyEdge = struct {
    from_pass: u16,
    to_pass: u16,
    resource: u16,
    previous_access: ResourceAccess,
    next_access: ResourceAccess,
    cross_queue: bool,
};

pub const ResourceLifetime = struct {
    resource: u16,
    first_use_pass: ?u16 = null,
    last_use_pass: ?u16 = null,
};

pub const CompiledPass = struct {
    pass_index: u16,
    name: []const u8,
    kind: PassKind,
    queue: QueueClass,
    inputs: []const PassResourceUse,
    outputs: []const PassResourceUse,
    dependency_count: usize,
};

pub const PassExecutionStat = struct {
    name: []const u8,
    kind: PassKind,
    queue: QueueClass,
    input_count: usize,
    output_count: usize,
    dependency_count: usize,
    cpu_time_ns: u64 = 0,
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,
};

const AccessState = struct {
    pass: u16,
    access: ResourceAccess,
    queue: QueueClass,
};

const GraphJson = struct {
    resources: []const ResourceNode,
    passes: []const CompiledPass,
    dependencies: []const DependencyEdge,
    lifetimes: []const ResourceLifetime,
};

const GraphReport = struct {
    backend: []const u8,
    draw_calls: usize,
    triangles_drawn: usize,
    resource_count: usize,
    pass_count: usize,
    passes: []const PassExecutionStat,
    lifetimes: []const ResourceLifetime,
};

pub const CompiledGraph = struct {
    allocator: std.mem.Allocator,
    execution: []CompiledPass,
    dependencies: []DependencyEdge,
    resource_lifetimes: []ResourceLifetime,

    pub fn deinit(self: *CompiledGraph) void {
        self.allocator.free(self.execution);
        self.allocator.free(self.dependencies);
        self.allocator.free(self.resource_lifetimes);
        self.* = undefined;
    }
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(ResourceNode) = .empty,
    passes: std.ArrayList(RenderPass) = .empty,
    compiled: ?CompiledGraph = null,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{ .allocator = allocator };
    }

    pub fn initDefault3D(allocator: std.mem.Allocator) !RenderGraph {
        var graph = RenderGraph.init(allocator);
        try graph.resetToDefault3D();
        return graph;
    }

    pub fn deinit(self: *RenderGraph) void {
        if (self.compiled) |*compiled| {
            compiled.deinit();
        }
        for (self.passes.items) |*pass| {
            self.allocator.free(pass.inputs);
            self.allocator.free(pass.outputs);
        }
        self.passes.deinit(self.allocator);
        self.resources.deinit(self.allocator);
    }

    pub fn resetToDefault3D(self: *RenderGraph) !void {
        if (self.compiled) |*compiled| {
            compiled.deinit();
            self.compiled = null;
        }
        for (self.passes.items) |*pass| {
            self.allocator.free(pass.inputs);
            self.allocator.free(pass.outputs);
        }
        self.passes.clearRetainingCapacity();
        self.resources.clearRetainingCapacity();

        const shadow_map = try self.addResource(.{ .name = "ShadowMap", .kind = .shadow_map });
        const scene_depth = try self.addResource(.{ .name = "SceneDepth", .kind = .depth });
        const entity_id = try self.addResource(.{ .name = "EntityId", .kind = .id_buffer });
        const scene_color = try self.addResource(.{ .name = "SceneColor", .kind = .scene_color });
        const lit_color = try self.addResource(.{ .name = "LitColor", .kind = .lit_color });
        const post_color = try self.addResource(.{ .name = "PostColor", .kind = .post_color });
        const swapchain = try self.addResource(.{ .name = "Swapchain", .kind = .swapchain, .external = true, .transient = false });

        try self.addPass(.{
            .name = "ShadowMap",
            .kind = .shadow_map,
            .outputs = &.{.{ .resource = shadow_map, .access = .write }},
        });
        try self.addPass(.{
            .name = "DepthPrepass",
            .kind = .depth_prepass,
            .outputs = &.{.{ .resource = scene_depth, .access = .write }},
        });
        try self.addPass(.{
            .name = "IDPass",
            .kind = .id_pass,
            .inputs = &.{.{ .resource = scene_depth, .access = .read }},
            .outputs = &.{.{ .resource = entity_id, .access = .write }},
        });
        try self.addPass(.{
            .name = "BasePass",
            .kind = .base_pass,
            .inputs = &.{.{ .resource = scene_depth, .access = .read }},
            .outputs = &.{.{ .resource = scene_color, .access = .write }},
        });
        try self.addPass(.{
            .name = "Lighting",
            .kind = .lighting,
            .inputs = &.{
                .{ .resource = shadow_map, .access = .read },
                .{ .resource = scene_depth, .access = .read },
                .{ .resource = scene_color, .access = .read },
            },
            .outputs = &.{.{ .resource = lit_color, .access = .write }},
        });
        try self.addPass(.{
            .name = "Transparent",
            .kind = .transparent,
            .inputs = &.{
                .{ .resource = lit_color, .access = .read },
                .{ .resource = scene_depth, .access = .read },
            },
            .outputs = &.{.{ .resource = lit_color, .access = .read_write }},
        });
        try self.addPass(.{
            .name = "PostProcess",
            .kind = .post_process,
            .inputs = &.{.{ .resource = lit_color, .access = .read }},
            .outputs = &.{.{ .resource = post_color, .access = .write }},
        });
        try self.addPass(.{
            .name = "OutlinePass",
            .kind = .outline_pass,
            .inputs = &.{
                .{ .resource = entity_id, .access = .read },
                .{ .resource = post_color, .access = .read },
            },
            .outputs = &.{.{ .resource = post_color, .access = .read_write }},
        });
        try self.addPass(.{
            .name = "GizmoPass",
            .kind = .gizmo_overlay,
            .inputs = &.{.{ .resource = post_color, .access = .read }},
            .outputs = &.{.{ .resource = post_color, .access = .read_write }},
        });
        try self.addPass(.{
            .name = "UIOverlay",
            .kind = .ui_overlay,
            .inputs = &.{.{ .resource = post_color, .access = .read }},
            .outputs = &.{.{ .resource = swapchain, .access = .write }},
        });

        try self.compile();
    }

    pub fn addResource(self: *RenderGraph, resource: ResourceNode) !u16 {
        try self.resources.append(self.allocator, resource);
        return @intCast(self.resources.items.len - 1);
    }

    pub fn addPass(self: *RenderGraph, pass: RenderPass) !void {
        try self.passes.append(self.allocator, .{
            .name = pass.name,
            .kind = pass.kind,
            .queue = pass.queue,
            .enabled = pass.enabled,
            .inputs = try self.allocator.dupe(PassResourceUse, pass.inputs),
            .outputs = try self.allocator.dupe(PassResourceUse, pass.outputs),
        });
    }

    pub fn compile(self: *RenderGraph) !void {
        if (self.compiled) |*compiled| {
            compiled.deinit();
            self.compiled = null;
        }

        var enabled_passes = std.ArrayList(CompiledPass).empty;
        defer enabled_passes.deinit(self.allocator);
        var dependencies = std.ArrayList(DependencyEdge).empty;
        defer dependencies.deinit(self.allocator);
        const resource_lifetimes = try self.allocator.alloc(ResourceLifetime, self.resources.items.len);
        errdefer self.allocator.free(resource_lifetimes);
        for (resource_lifetimes, 0..) |*lifetime, index| {
            lifetime.* = .{ .resource = @intCast(index) };
        }

        const last_access = try self.allocator.alloc(?AccessState, self.resources.items.len);
        defer self.allocator.free(last_access);
        @memset(last_access, null);

        var dependency_counts = std.ArrayList(usize).empty;
        defer dependency_counts.deinit(self.allocator);

        for (self.passes.items) |pass| {
            if (!pass.enabled) {
                continue;
            }
            const pass_index: u16 = @intCast(enabled_passes.items.len);
            try dependency_counts.append(self.allocator, 0);

            for (pass.inputs) |input| {
                try registerResourceUse(self.allocator, &dependencies, &dependency_counts, resource_lifetimes, last_access, pass_index, pass.queue, input);
            }
            for (pass.outputs) |output| {
                try registerResourceUse(self.allocator, &dependencies, &dependency_counts, resource_lifetimes, last_access, pass_index, pass.queue, output);
            }

            try enabled_passes.append(self.allocator, .{
                .pass_index = pass_index,
                .name = pass.name,
                .kind = pass.kind,
                .queue = pass.queue,
                .inputs = pass.inputs,
                .outputs = pass.outputs,
                .dependency_count = dependency_counts.items[pass_index],
            });
        }

        self.compiled = .{
            .allocator = self.allocator,
            .execution = try enabled_passes.toOwnedSlice(self.allocator),
            .dependencies = try dependencies.toOwnedSlice(self.allocator),
            .resource_lifetimes = resource_lifetimes,
        };
    }

    pub fn passCount(self: *const RenderGraph) usize {
        if (self.compiled) |compiled| {
            return compiled.execution.len;
        }
        return self.passes.items.len;
    }

    pub fn resourceCount(self: *const RenderGraph) usize {
        return self.resources.items.len;
    }

    pub fn compiledPasses(self: *const RenderGraph) []const CompiledPass {
        return if (self.compiled) |compiled| compiled.execution else &.{};
    }

    pub fn lifetimes(self: *const RenderGraph) []const ResourceLifetime {
        return if (self.compiled) |compiled| compiled.resource_lifetimes else &.{};
    }

    pub fn allocatePassStats(self: *const RenderGraph, allocator: std.mem.Allocator) ![]PassExecutionStat {
        const compiled = self.compiled orelse return allocator.alloc(PassExecutionStat, 0);
        const stats = try allocator.alloc(PassExecutionStat, compiled.execution.len);
        for (compiled.execution, 0..) |pass, index| {
            stats[index] = .{
                .name = pass.name,
                .kind = pass.kind,
                .queue = pass.queue,
                .input_count = pass.inputs.len,
                .output_count = pass.outputs.len,
                .dependency_count = pass.dependency_count,
            };
        }
        return stats;
    }

    pub fn recordPassStat(
        self: *const RenderGraph,
        stats: []PassExecutionStat,
        kind: PassKind,
        cpu_time_ns: u64,
        draw_calls: usize,
        triangles_drawn: usize,
    ) void {
        _ = self;
        for (stats) |*stat| {
            if (stat.kind == kind) {
                stat.cpu_time_ns += cpu_time_ns;
                stat.draw_calls += draw_calls;
                stat.triangles_drawn += triangles_drawn;
                return;
            }
        }
    }

    pub fn exportDotAlloc(self: *const RenderGraph, allocator: std.mem.Allocator) ![]u8 {
        const compiled = self.compiled orelse return allocator.dupe(u8, "digraph RenderGraph {}\n");
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        try output.writer(allocator).print("digraph RenderGraph {{\n  rankdir=LR;\n", .{});
        for (self.resources.items, 0..) |resource, index| {
            try output.writer(allocator).print(
                "  resource_{d} [shape=ellipse,label=\"{s}\"];\n",
                .{ index, resource.name },
            );
        }
        for (compiled.execution, 0..) |pass, index| {
            try output.writer(allocator).print(
                "  pass_{d} [shape=box,label=\"{s}\"];\n",
                .{ index, pass.name },
            );
            for (pass.inputs) |input| {
                try output.writer(allocator).print("  resource_{d} -> pass_{d};\n", .{ input.resource, index });
            }
            for (pass.outputs) |resource_use| {
                try output.writer(allocator).print("  pass_{d} -> resource_{d};\n", .{ index, resource_use.resource });
            }
        }
        try output.writer(allocator).print("}}\n", .{});
        return output.toOwnedSlice(allocator);
    }

    pub fn exportJsonAlloc(self: *const RenderGraph, allocator: std.mem.Allocator) ![]u8 {
        const compiled = self.compiled orelse return allocator.dupe(u8, "{}\n");
        return stringifyAlloc(allocator, GraphJson{
            .resources = self.resources.items,
            .passes = compiled.execution,
            .dependencies = compiled.dependencies,
            .lifetimes = compiled.resource_lifetimes,
        });
    }

    pub fn writeExports(self: *const RenderGraph, dot_path: []const u8, json_path: []const u8) !void {
        const dot = try self.exportDotAlloc(self.allocator);
        defer self.allocator.free(dot);
        const json = try self.exportJsonAlloc(self.allocator);
        defer self.allocator.free(json);
        try writeTextFile(dot_path, dot);
        try writeTextFile(json_path, json);
    }

    pub fn writeFrameReport(
        self: *const RenderGraph,
        allocator: std.mem.Allocator,
        path: []const u8,
        backend_name: []const u8,
        draw_calls: usize,
        triangles_drawn: usize,
        stats: []const PassExecutionStat,
    ) !void {
        const report = GraphReport{
            .backend = backend_name,
            .draw_calls = draw_calls,
            .triangles_drawn = triangles_drawn,
            .resource_count = self.resourceCount(),
            .pass_count = self.passCount(),
            .passes = stats,
            .lifetimes = self.lifetimes(),
        };
        const encoded = try stringifyAlloc(allocator, report);
        defer allocator.free(encoded);
        try writeTextFile(path, encoded);
    }
};

fn registerResourceUse(
    allocator: std.mem.Allocator,
    dependencies: *std.ArrayList(DependencyEdge),
    dependency_counts: *std.ArrayList(usize),
    lifetimes: []ResourceLifetime,
    last_access: []?AccessState,
    pass_index: u16,
    queue: QueueClass,
    use_ref: PassResourceUse,
) !void {
    if (use_ref.resource >= lifetimes.len) {
        return error.ResourceIndexOutOfBounds;
    }

    var lifetime = &lifetimes[use_ref.resource];
    if (lifetime.first_use_pass == null) {
        lifetime.first_use_pass = pass_index;
    }
    lifetime.last_use_pass = pass_index;

    if (last_access[use_ref.resource]) |previous| {
        try appendDependencyIfMissing(allocator, dependencies, .{
            .from_pass = previous.pass,
            .to_pass = pass_index,
            .resource = use_ref.resource,
            .previous_access = previous.access,
            .next_access = use_ref.access,
            .cross_queue = previous.queue != queue,
        });
        dependency_counts.items[pass_index] = dependencyCountsForPass(dependencies.items, pass_index);
    }

    last_access[use_ref.resource] = .{
        .pass = pass_index,
        .access = use_ref.access,
        .queue = queue,
    };
}

fn appendDependencyIfMissing(allocator: std.mem.Allocator, list: *std.ArrayList(DependencyEdge), edge: DependencyEdge) !void {
    for (list.items) |existing| {
        if (existing.from_pass == edge.from_pass and existing.to_pass == edge.to_pass and existing.resource == edge.resource) {
            return;
        }
    }
    try list.append(allocator, edge);
}

fn dependencyCountsForPass(edges: []const DependencyEdge, pass_index: u16) usize {
    var count: usize = 0;
    for (edges) |edge| {
        if (edge.to_pass == pass_index) {
            count += 1;
        }
    }
    return count;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

fn writeTextFile(path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
    });
}

test "default render graph compiles with resource lifetimes" {
    var graph = try RenderGraph.initDefault3D(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 7), graph.resourceCount());
    try std.testing.expectEqual(@as(usize, 10), graph.passCount());
    const lifetimes = graph.lifetimes();
    try std.testing.expect(lifetimes.len == 7);
    try std.testing.expect(lifetimes[1].first_use_pass != null);
    try std.testing.expect(lifetimes[5].last_use_pass != null);
}

test "render graph exports deterministic dot" {
    var graph = try RenderGraph.initDefault3D(std.testing.allocator);
    defer graph.deinit();

    const dot = try graph.exportDotAlloc(std.testing.allocator);
    defer std.testing.allocator.free(dot);

    try std.testing.expect(std.mem.indexOf(u8, dot, "OutlinePass") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "SceneDepth") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "resource_1 -> pass_2") != null);
}
