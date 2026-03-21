const std = @import("std");
const scene_mod = @import("../scene/scene.zig");
const renderer_mod = @import("../render/renderer.zig");
const rhi_mod = @import("../rhi/device.zig");
const input_mod = @import("input.zig");
const command_queue_mod = @import("command_queue.zig");
const editor_utility_runtime_mod = @import("../script/editor_utility_runtime.zig");
const script_runtime_mod = @import("../script/runtime.zig");
const window_mod = @import("../platform/window.zig");
const physics_mod = @import("../physics/system.zig");

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
};

pub const PlaybackController = struct {
    state: PlaybackState = .stopped,
    pending_steps: usize = 0,

    pub fn setState(self: *PlaybackController, next: PlaybackState) void {
        self.state = next;
        if (next == .playing) {
            self.pending_steps = 0;
        }
    }

    pub fn requestStep(self: *PlaybackController) void {
        self.state = .paused;
        self.pending_steps += 1;
    }

    pub fn shouldAdvance(self: *const PlaybackController) bool {
        return self.state == .playing or self.pending_steps > 0;
    }

    pub fn consumeAdvance(self: *PlaybackController) void {
        if (self.state == .playing or self.pending_steps == 0) {
            return;
        }
        self.pending_steps -= 1;
    }
};

pub const LayerContext = struct {
    world: *scene_mod.World,
    scene: *scene_mod.Scene,
    renderer: *renderer_mod.Renderer,
    command_queue: ?*command_queue_mod.CommandQueue = null,
    script_runtime: ?*script_runtime_mod.ScriptRuntime = null,
    editor_utility_runtime: ?*editor_utility_runtime_mod.EditorUtilityRuntime = null,
    input: *input_mod.InputState,
    window: *window_mod.Window,
    playback_controller: *PlaybackController,
    physics_state: *physics_mod.PhysicsState,
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

test "PlaybackController advances only while playing or stepping" {
    var controller = PlaybackController{};
    try std.testing.expect(!controller.shouldAdvance());

    controller.requestStep();
    try std.testing.expect(controller.shouldAdvance());
    try std.testing.expectEqual(@as(PlaybackState, .paused), controller.state);
    controller.consumeAdvance();
    try std.testing.expect(!controller.shouldAdvance());

    controller.setState(.playing);
    try std.testing.expect(controller.shouldAdvance());
    controller.consumeAdvance();
    try std.testing.expect(controller.shouldAdvance());

    controller.setState(.stopped);
    try std.testing.expect(!controller.shouldAdvance());
}
