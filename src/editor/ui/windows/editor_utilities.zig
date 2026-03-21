const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const layout = @import("../layout.zig");

pub fn drawEditorUtilitiesWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var open = state.editor_utilities_open;
    if (!engine.ui.ImGui.beginWindowOpen("AI Utilities###editor_utilities_panel", &open)) {
        engine.ui.ImGui.endWindow();
        state.editor_utilities_open = open;
        return;
    }
    defer {
        engine.ui.ImGui.endWindow();
        state.editor_utilities_open = open;
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    const runtime = layer_context.editor_utility_runtime orelse {
        engine.ui.ImGui.textWrapped("Editor utility runtime is not available.");
        return;
    };

    const snapshots = try runtime.listAlloc(layer_context.world.allocator);
    defer engine.script.freeEditorUtilitySnapshots(layer_context.world.allocator, snapshots);

    if (snapshots.len == 0) {
        engine.ui.ImGui.textWrapped("No editor utilities are loaded. Use MCP compile_editor_utility to add one.");
        return;
    }

    engine.ui.ImGui.text("Loaded Utilities");
    const registry_height = @min(260.0, @max(148.0, engine.ui.ImGui.contentRegionAvail()[1] * 0.42));
    if (engine.ui.ImGui.beginChild("editor_utilities_registry", 0.0, registry_height, true)) {
        defer engine.ui.ImGui.endChild();
        try drawRegistry(runtime, snapshots);
    }

    engine.ui.ImGui.dummy(0.0, 8.0);
    engine.ui.ImGui.text("Panel Content");
    engine.ui.ImGui.separator();

    var open_count: usize = 0;
    for (snapshots) |snapshot| {
        if (!snapshot.open) {
            continue;
        }
        open_count += 1;

        engine.ui.ImGui.pushIdU64(@intFromEnum(snapshot.handle));
        defer engine.ui.ImGui.popId();

        if (engine.ui.ImGui.collapsingHeader(snapshot.name, true)) {
            if (snapshot.description.len != 0) {
                engine.ui.ImGui.textWrapped(snapshot.description);
            }
            if (snapshot.source_path.len != 0) {
                engine.ui.ImGui.labelText("Source", snapshot.source_path);
            }
            engine.ui.ImGui.labelText("Status", statusLabel(snapshot.status));
            if (snapshot.last_error.len != 0 and snapshot.status != .ready) {
                engine.ui.ImGui.textWrapped(snapshot.last_error);
            }
            engine.ui.ImGui.separator();
            _ = runtime.drawUtilityInCurrentWindow(snapshot.handle, .{
                .world = layer_context.world,
                .allocator = layer_context.world.allocator,
                .command_queue = layer_context.command_queue,
                .delta_seconds = layer_context.delta_seconds,
                .selection = layer_context.renderer.selectedEntities(),
                .selection_api = .{
                    .context = layer_context,
                    .select_entity = editorUtilitySelectEntity,
                    .clear_selection = editorUtilityClearSelection,
                },
            });
        }

        engine.ui.ImGui.dummy(0.0, 6.0);
    }

    if (open_count == 0) {
        engine.ui.ImGui.textWrapped("No utility panels are currently open. Toggle Open above to render one here.");
    }
}

fn drawRegistry(
    runtime: *engine.script.EditorUtilityRuntime,
    snapshots: anytype,
) !void {
    for (snapshots, 0..) |snapshot, index| {
        engine.ui.ImGui.pushIdU64(@intFromEnum(snapshot.handle));
        defer engine.ui.ImGui.popId();

        if (index != 0) {
            engine.ui.ImGui.separator();
        }

        engine.ui.ImGui.text(snapshot.name);
        if (snapshot.description.len != 0) {
            engine.ui.ImGui.textWrapped(snapshot.description);
        }
        if (snapshot.source_path.len != 0) {
            engine.ui.ImGui.labelText("Source", snapshot.source_path);
        }
        engine.ui.ImGui.labelText("Status", statusLabel(snapshot.status));

        var is_open = snapshot.open;
        if (engine.ui.ImGui.checkbox("Open", &is_open)) {
            runtime.setOpen(snapshot.handle, is_open);
        }
        engine.ui.ImGui.sameLine();
        if (engine.ui.ImGui.button("Unload")) {
            _ = runtime.remove(snapshot.handle);
            continue;
        }

        if (snapshot.last_error.len != 0 and snapshot.status != .ready) {
            engine.ui.ImGui.textWrapped(snapshot.last_error);
        }
    }
}

fn statusLabel(status: engine.script.EditorUtilityStatus) []const u8 {
    return switch (status) {
        .ready => "ready",
        .load_error => "load_error",
        .init_error => "init_error",
        .update_error => "update_error",
    };
}

fn editorUtilitySelectEntity(context_ptr: *anyopaque, entity_id: engine.scene.EntityId, additive: bool) void {
    const layer_context: *engine.core.LayerContext = @ptrCast(@alignCast(context_ptr));
    if (additive) {
        layer_context.renderer.toggleSelection(entity_id) catch {};
    } else {
        layer_context.renderer.replaceSelection(entity_id) catch {};
    }
}

fn editorUtilityClearSelection(context_ptr: *anyopaque) void {
    const layer_context: *engine.core.LayerContext = @ptrCast(@alignCast(context_ptr));
    layer_context.renderer.replaceSelection(null) catch {};
}
