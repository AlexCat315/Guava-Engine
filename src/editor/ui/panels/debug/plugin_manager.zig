const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

/// Draw the Plugin Manager panel.
/// Shows all discovered plugins with name, source, type, lifecycle, errors,
/// and per-plugin Enable / Disable / Unload buttons.
pub fn drawPluginManagerWindow(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var open = state.plugin_manager_open;
    const open_window = gui.beginWindowOpen("Plugin Manager###plugin_manager_panel", &open);
    floating_window_blocker.registerCurrentWindow("plugin_manager_panel");
    if (!open_window) {
        gui.endWindow();
        state.plugin_manager_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.plugin_manager_open = open;
    }

    const renderer = layer_context.renderer;
    const plugin_reg = renderer.pluginRegistry();

    // ── Toolbar ─────────────────────────────────────────────────────────
    if (gui.button("Rescan project_plugins")) {
        renderer.rescanPlugins("project_plugins");
    }
    gui.sameLine();

    var buf: [256]u8 = undefined;
    const count_text = std.fmt.bufPrint(&buf, "Discovered plugins: {d}", .{plugin_reg.plugins.count()}) catch "?";
    gui.text(count_text);
    gui.separator();

    // ── Table ───────────────────────────────────────────────────────────
    if (gui.beginTable("plugin_table", 6)) {
        gui.tableSetupColumn("Name", true, 0.0);
        gui.tableSetupColumn("Type", true, 0.0);
        gui.tableSetupColumn("Source", true, 0.0);
        gui.tableSetupColumn("State", true, 0.0);
        gui.tableSetupColumn("Actions", true, 0.0);
        gui.tableSetupColumn("Error", true, 0.0);
        gui.tableHeadersRow();

        var it = plugin_reg.plugins.iterator();
        while (it.next()) |entry| {
            const record = entry.value_ptr.*;
            gui.tableNextRow();

            // Name
            gui.tableNextColumn();
            gui.text(record.getName());

            // Type
            gui.tableNextColumn();
            gui.text(@tagName(record.getType()));

            // Source
            gui.tableNextColumn();
            gui.text(@tagName(record.getSource()));

            // Lifecycle state
            gui.tableNextColumn();
            const lifecycle = record.lifecycle;
            switch (lifecycle) {
                .enabled => gui.textColored(.{ 0.3, 0.9, 0.3, 1.0 }, "enabled"),
                .loaded => gui.textColored(.{ 0.7, 0.8, 1.0, 1.0 }, "loaded"),
                .unloaded => gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "unloaded"),
                .load_error => gui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "error"),
            }

            // Actions
            gui.tableNextColumn();
            const name = record.getName();
            switch (lifecycle) {
                .enabled => {
                    // Action button id: "Disable##<name>"
                    var id_buf: [128]u8 = undefined;
                    const disable_id = std.fmt.bufPrint(&id_buf, "Disable##{s}", .{name}) catch "Disable";
                    if (gui.button(disable_id)) {
                        renderer.disablePlugin(name);
                    }
                },
                .loaded => {
                    var id_buf: [128]u8 = undefined;
                    const enable_id = std.fmt.bufPrint(&id_buf, "Enable##{s}", .{name}) catch "Enable";
                    if (gui.button(enable_id)) {
                        renderer.enablePlugin(name);
                    }
                },
                .load_error, .unloaded => {},
            }
            gui.sameLine();
            {
                var id_buf: [128]u8 = undefined;
                const unload_id = std.fmt.bufPrint(&id_buf, "Unload##{s}", .{name}) catch "Unload";
                if (gui.button(unload_id)) {
                    renderer.unloadPlugin(name);
                }
            }

            // Last error
            gui.tableNextColumn();
            if (record.last_error) |err| {
                gui.textColored(.{ 1.0, 0.4, 0.4, 1.0 }, err);
            } else {
                gui.textColored(.{ 0.4, 0.4, 0.4, 1.0 }, "—");
            }
        }
        gui.endTable();
    }
}
