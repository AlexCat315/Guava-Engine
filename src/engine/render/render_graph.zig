const std = @import("std");

pub const QueueClass = enum {
    graphics,
    compute,
    copy,
};

pub const PassKind = enum {
    shadow_map,
    depth_prepass,
    opaque_geometry,
    lighting,
    transparent,
    post_process,
    ui_overlay,
};

pub const RenderPass = struct {
    name: []const u8,
    kind: PassKind,
    queue: QueueClass = .graphics,
    enabled: bool = true,
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayList(RenderPass) = .empty,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{ .allocator = allocator };
    }

    pub fn initDefault3D(allocator: std.mem.Allocator) !RenderGraph {
        var graph = RenderGraph.init(allocator);
        try graph.resetToDefault3D();
        return graph;
    }

    pub fn deinit(self: *RenderGraph) void {
        self.passes.deinit(self.allocator);
    }

    pub fn resetToDefault3D(self: *RenderGraph) !void {
        self.passes.clearRetainingCapacity();
        try self.addPass(.{ .name = "ShadowMap", .kind = .shadow_map });
        try self.addPass(.{ .name = "DepthPrepass", .kind = .depth_prepass });
        try self.addPass(.{ .name = "OpaqueGeometry", .kind = .opaque_geometry });
        try self.addPass(.{ .name = "Lighting", .kind = .lighting });
        try self.addPass(.{ .name = "Transparent", .kind = .transparent });
        try self.addPass(.{ .name = "PostProcess", .kind = .post_process });
        try self.addPass(.{ .name = "UIOverlay", .kind = .ui_overlay });
    }

    pub fn addPass(self: *RenderGraph, pass: RenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }
};
