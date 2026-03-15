const scene_mod = @import("../scene/scene.zig");
const renderer_mod = @import("../render/renderer.zig");
const rhi_mod = @import("../rhi/device.zig");

pub const LayerContext = struct {
    scene: *scene_mod.Scene,
    renderer: *renderer_mod.Renderer,
    frame_index: usize,
    delta_seconds: f32,

    pub fn rhi(self: *LayerContext) *rhi_mod.RhiDevice {
        return self.renderer.device();
    }
};

pub const Hooks = struct {
    on_attach: ?*const fn (context: *anyopaque, layer_context: *LayerContext) anyerror!void = null,
    on_detach: ?*const fn (context: *anyopaque) void = null,
    on_update: ?*const fn (context: *anyopaque, layer_context: *LayerContext) anyerror!void = null,
};

pub const Layer = struct {
    name: []const u8,
    context: *anyopaque,
    hooks: Hooks = .{},

    pub fn attach(self: *const Layer, layer_context: *LayerContext) !void {
        if (self.hooks.on_attach) |hook| {
            try hook(self.context, layer_context);
        }
    }

    pub fn detach(self: *const Layer) void {
        if (self.hooks.on_detach) |hook| {
            hook(self.context);
        }
    }

    pub fn update(self: *const Layer, layer_context: *LayerContext) !void {
        if (self.hooks.on_update) |hook| {
            try hook(self.context, layer_context);
        }
    }
};
