const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;

pub const AIBridgeLayer = struct {
    pub fn asLayer(self: *AIBridgeLayer) engine.core.Layer {
        return .{
            .name = "AIBridge",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        _ = context;
        _ = layer_context;
        try std.log.info("AI Debug Bridge attached", .{});
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        _ = context;

        const io = engine.ui.ImGui.getIO();
        const modifiers = layer_context.input.modifiers;
        if (modifiers.super and modifiers.shift and io.keys_down[@intFromEnum(engine.ui.ImGui.Key.d)]) {
            const allocator = layer_context.world.allocator;
            captureSnapshot(allocator, layer_context) catch |err| {
                try std.log.err("Failed to capture AI snapshot: {}", .{err});
            };
        }
    }

    pub fn captureSnapshot(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext) anyerror!void {
        const snapshot = @import("./ai_snapshot.zig");
        try snapshot.captureAndSaveSnapshot(allocator, layer_context);
    }
};
