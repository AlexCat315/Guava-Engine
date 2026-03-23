const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

/// Draw the RHI v2 debug stats overlay panel.
pub fn drawRhiV2StatsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var open = state.rhi_v2_stats_open;
    if (!gui.beginWindowOpen("RHI v2 Stats###rhi_v2_stats_panel", &open)) {
        gui.endWindow();
        state.rhi_v2_stats_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.rhi_v2_stats_open = open;
    }

    const renderer = layer_context.renderer;
    const v2_dev = renderer.rhi_v2_device orelse {
        gui.textWrapped("RHI v2 device not initialized.");
        return;
    };

    // ── Binding Cache ──────────────────────────────────────────────
    if (gui.collapsingHeader("Binding Set Cache", true)) {
        const stats = v2_dev.bindingSetCacheStats();
        const entries = v2_dev.bindingSetCacheEntryCount();

        var buf: [128]u8 = undefined;

        const hit_text = std.fmt.bufPrint(&buf, "{d}", .{stats.hits}) catch "?";
        gui.labelText("Hits", hit_text);

        const miss_text = std.fmt.bufPrint(&buf, "{d}", .{stats.misses}) catch "?";
        gui.labelText("Misses", miss_text);

        const rate_text = std.fmt.bufPrint(&buf, "{d:.1}%", .{stats.hitRate() * 100.0}) catch "?";
        gui.labelText("Hit Rate", rate_text);

        const total_text = std.fmt.bufPrint(&buf, "{d}", .{stats.totalLookups()}) catch "?";
        gui.labelText("Total Lookups", total_text);

        const evict_text = std.fmt.bufPrint(&buf, "{d}", .{stats.evictions}) catch "?";
        gui.labelText("Evictions", evict_text);

        const entry_text = std.fmt.bufPrint(&buf, "{d} / 1024", .{entries}) catch "?";
        gui.labelText("Entries", entry_text);

        gui.dummy(0.0, 4.0);
        if (gui.button("Reset Stats")) {
            v2_dev.resetBindingSetCacheStats();
        }
    }

    // ── Slot-Layout Validation ─────────────────────────────────────
    if (gui.collapsingHeader("Slot-Layout Validation", true)) {
        const slot_errors = renderer.graph.validateSlotLayoutConstraints(
            renderer.allocator,
            v2_dev,
        ) catch &.{};
        defer if (slot_errors.len > 0) renderer.allocator.free(slot_errors);

        var err_buf: [128]u8 = undefined;
        const err_text = std.fmt.bufPrint(&err_buf, "{d}", .{slot_errors.len}) catch "?";
        if (slot_errors.len == 0) {
            gui.textColored(.{ 0.2, 0.8, 0.2, 1.0 }, "All constraints OK");
        } else {
            gui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, err_text);
        }
        gui.labelText("Constraint Errors", err_text);

        for (slot_errors) |se| {
            const detail = std.fmt.bufPrint(&err_buf, "slot={d} expected={d}", .{ se.slot, se.expected_layout_id }) catch "?";
            gui.labelText(se.pass_name, detail);
        }
    }

    // ── V2 Pass Migration Status ───────────────────────────────────
    if (gui.collapsingHeader("V2 Pass Migration", true)) {
        const vs = renderer.editor_viewport_state;
        gui.labelText("SSAO", if (!vs.ssao_use_legacy_path) "v2 (compute)" else "legacy");
        gui.labelText("FXAA", if (vs.fxaa_use_rhi_v2) "v2" else "legacy");
        gui.labelText("Bloom", if (vs.bloom_use_rhi_v2) "v2" else "legacy");
        gui.labelText("Tonemap", if (vs.tonemap_use_rhi_v2) "v2" else "legacy");
    }
}
