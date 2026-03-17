const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("../core/layer.zig");
const editor_console = @import("../ui/windows/console.zig");

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
        const self: *AIBridgeLayer = @ptrCast(@alignCast(context));
        // Initialization code for AI bridge
        _ = try std.log.info("AI Debug Bridge attached", .{});
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *AIBridgeLayer = @ptrCast(@alignCast(context));
        // Check for hotkey or trigger to capture snapshot
        // For now, we'll implement manual trigger via command
    }

    pub fn captureSnapshot(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext) anyerror!void {
        // Delegate to snapshot implementation
        const snapshot = @import("./ai_snapshot.zig");
        try snapshot.captureAndSaveSnapshot(allocator, layer_context);
    }
};
