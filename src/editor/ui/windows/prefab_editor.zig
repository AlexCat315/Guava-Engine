const std = @import("std");
const engine = @import("guava");
const layout = @import("../layout.zig");

const EntityId = engine.scene.EntityId;
const PrefabResource = engine.scene.PrefabResource;

pub const PrefabEditorState = struct {
    selected_prefab_id: ?[]const u8 = null,
    selected_entity_index: ?usize = null,
    is_editing: bool = false,
    pending_save: bool = false,
    prefab_name_buffer: [256]u8 = [_]u8{0} ** 256,
    search_filter: [128]u8 = [_]u8{0} ** 128,
    show_create_dialog: bool = false,
    new_prefab_name_buffer: [128]u8 = [_]u8{0} ** 128,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.selected_prefab_id) |id| {
            allocator.free(id);
        }
        self.* = undefined;
    }
};

pub fn drawPrefabEditor(
    state: *engine.AppState,
    layer_context: *engine.LayerContext,
    editor_state: *PrefabEditorState,
) void {
    _ = layer_context;
    const world = state.world orelse return;

    if (engine.ui.ImGui.begin("Prefab Library")) {
        defer engine.ui.ImGui.end();

        drawPrefabToolbar(state, editor_state);

        engine.ui.ImGui.separator();

        const left_pane_width = engine.ui.ImGui.getContentRegionAvail().x * 0.3;
        _ = engine.ui.ImGui.beginChild("prefab_list", left_pane_width, -1.0, true);
        defer engine.ui.ImGui.endChild();

        drawPrefabList(state, editor_state);
    }

    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.begin("Prefab Details")) {
        defer engine.ui.ImGui.end();

        if (editor_state.selected_prefab_id) |prefab_id| {
            if (world.prefab_library.getPrefab(prefab_id)) |prefab| {
                drawPrefabDetails(state, editor_state, prefab);
            } else {
                engine.ui.ImGui.textWrapped("Prefab not found");
            }
        } else {
            engine.ui.ImGui.textWrapped("Select a prefab from the library");
        }
    }
}

fn drawPrefabToolbar(
    state: *engine.AppState,
    editor_state: *PrefabEditorState,
) void {
    _ = state;

    if (engine.ui.ImGui.button("Create Prefab")) {
        editor_state.show_create_dialog = true;
    }

    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Save All")) {
    }

    engine.ui.ImGui.sameLine();

    engine.ui.ImGui.text("Search:");
    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.inputText("##prefab_search", &editor_state.search_filter, 128, .{}, null, null);
}

fn drawPrefabList(
    state: *engine.AppState,
    editor_state: *PrefabEditorState,
) void {
    const world = state.world orelse return;

    var filter_empty = true;
    for (editor_state.search_filter) |c| {
        if (c != 0) {
            filter_empty = false;
            break;
        }
    }

    var prefab_iter = world.prefab_library.prefabs.iterator();
    while (prefab_iter.next()) |entry| {
        const prefab_id = entry.key_ptr.*;
        const prefab = entry.value_ptr.*;

        if (!filter_empty) {
            const filter = std.mem.sliceTo(&editor_state.search_filter, 0);
            if (std.mem.indexOf(u8, prefab.name, filter) == null and
                std.mem.indexOf(u8, prefab_id, filter) == null)
            {
                continue;
            }
        }

        const is_selected = editor_state.selected_prefab_id != null and
            std.mem.eql(u8, editor_state.selected_prefab_id.?, prefab_id);

        var name_buf: [256]u8 = undefined;
        const display_name = std.fmt.bufPrint(&name_buf, "{s}##{s}", .{ prefab.name, prefab_id }) catch continue;

        if (engine.ui.ImGui.selectable(display_name, is_selected)) {
            if (editor_state.selected_prefab_id) |old_id| {
                state.allocator.free(old_id);
            }
            editor_state.selected_prefab_id = state.allocator.dupe(u8, prefab_id) catch null;
        }

        if (engine.ui.ImGui.beginPopupContextItem()) {
            if (engine.ui.ImGui.selectable("Delete Prefab", false)) {
            }
            if (engine.ui.ImGui.selectable("Duplicate Prefab", false)) {
            }
            engine.ui.ImGui.endPopup();
        }
    }
}

fn drawPrefabDetails(
    state: *engine.AppState,
    editor_state: *PrefabEditorState,
    prefab: *const PrefabResource,
) void {
    _ = state;
    _ = editor_state;

    if (layout.beginInspectorPropertyTable("prefab_details", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("ID", null);
        engine.ui.ImGui.textWrapped(prefab.id);

        layout.drawInspectorPropertyRow("Name", null);
        engine.ui.ImGui.textWrapped(prefab.name);

        layout.drawInspectorPropertyRow("Version", null);
        engine.ui.ImGui.text("{}", .{prefab.version});

        layout.drawInspectorPropertyRow("Entities", null);
        engine.ui.ImGui.text("{}", .{prefab.entities.len});

        layout.drawInspectorPropertyRow("Source Path", null);
        if (prefab.source_path) |path| {
            engine.ui.ImGui.textWrapped(path);
        } else {
            engine.ui.ImGui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Not saved");
        }
    }

    engine.ui.ImGui.separator();
    engine.ui.ImGui.text("Entity List:");
    engine.ui.ImGui.separator();

    if (engine.ui.ImGui.beginChild("prefab_entity_list", -1.0, -1.0, true)) {
        for (prefab.entities, 0..) |entity, index| {
            const is_selected = editor_state.selected_entity_index != null and
                editor_state.selected_entity_index.? == index;

            var name_buf: [256]u8 = undefined;
            const display_name = std.fmt.bufPrint(&name_buf, "{s}##{}", .{ entity.name, index }) catch continue;

            if (engine.ui.ImGui.selectable(display_name, is_selected)) {
                editor_state.selected_entity_index = index;
            }
        }
    }
    engine.ui.ImGui.endChild();
}
