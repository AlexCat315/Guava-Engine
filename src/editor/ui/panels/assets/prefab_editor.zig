const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const layout = @import("../../layout.zig");

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

    if (gui.begin("Prefab Library")) {
        defer gui.end();

        drawPrefabToolbar(state, editor_state);

        gui.separator();

        const left_pane_width = gui.getContentRegionAvail().x * 0.3;
        _ = gui.beginChild("prefab_list", left_pane_width, -1.0, true);
        defer gui.endChild();

        drawPrefabList(state, editor_state);
    }

    gui.sameLine();

    if (gui.begin("Prefab Details")) {
        defer gui.end();

        if (editor_state.selected_prefab_id) |prefab_id| {
            if (world.prefab_library.getPrefab(prefab_id)) |prefab| {
                drawPrefabDetails(state, editor_state, prefab);
            } else {
                gui.textWrapped("Prefab not found");
            }
        } else {
            gui.textWrapped("Select a prefab from the library");
        }
    }
}

fn drawPrefabToolbar(
    state: *engine.AppState,
    editor_state: *PrefabEditorState,
) void {
    _ = state;

    if (gui.button("Create Prefab")) {
        editor_state.show_create_dialog = true;
    }

    gui.sameLine();

    if (gui.button("Save All")) {}

    gui.sameLine();

    gui.text("Search:");
    gui.sameLine();
    _ = gui.inputText("##prefab_search", &editor_state.search_filter, 128, .{}, null, null);
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

        if (gui.selectable(display_name, is_selected)) {
            if (editor_state.selected_prefab_id) |old_id| {
                state.allocator.free(old_id);
            }
            editor_state.selected_prefab_id = state.allocator.dupe(u8, prefab_id) catch null;
        }

        if (gui.beginPopupContextItem()) {
            if (gui.selectable("Delete Prefab", false)) {}
            if (gui.selectable("Duplicate Prefab", false)) {}
            gui.endPopup();
        }
    }
}

fn drawPrefabDetails(
    state: *engine.AppState,
    editor_state: *PrefabEditorState,
    prefab: *const PrefabResource,
) void {
    _ = state;
    // _ = editor_state;

    if (layout.beginInspectorPropertyTable("prefab_details", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("ID", null);
        gui.textWrapped(prefab.id);

        layout.drawInspectorPropertyRow("Name", null);
        gui.textWrapped(prefab.name);

        layout.drawInspectorPropertyRow("Version", null);
        gui.text("{}", .{prefab.version});

        layout.drawInspectorPropertyRow("Entities", null);
        gui.text("{}", .{prefab.entities.len});

        layout.drawInspectorPropertyRow("Source Path", null);
        if (prefab.source_path) |path| {
            gui.textWrapped(path);
        } else {
            gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Not saved");
        }
    }

    gui.separator();
    gui.text("Entity List:");
    gui.separator();

    if (gui.beginChild("prefab_entity_list", -1.0, -1.0, true)) {
        for (prefab.entities, 0..) |entity, index| {
            const is_selected = editor_state.selected_entity_index != null and
                editor_state.selected_entity_index.? == index;

            var name_buf: [256]u8 = undefined;
            const display_name = std.fmt.bufPrint(&name_buf, "{s}##{}", .{ entity.name, index }) catch continue;

            if (gui.selectable(display_name, is_selected)) {
                editor_state.selected_entity_index = index;
            }
        }
    }
    gui.endChild();
}
