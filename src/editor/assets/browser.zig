const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const asset_preview = @import("preview.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;

pub fn drawContentBrowser(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .content_browser, "content_browser_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    if (engine.ui.ImGui.buttonEx(state.text(.refresh), 104.0, 0.0)) {
        try refreshAssetBrowser(state);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.quick_save), 116.0, 0.0)) {
        history.saveScene(state, layer_context);
    }

    engine.ui.ImGui.setNextItemWidth(-1.0);
    _ = engine.ui.ImGui.inputText(state.text(.asset_filter), state.asset_filter_buffer[0..]);

    {
        _ = engine.ui.ImGui.beginChild("content_browser_preview", 0.0, 192.0, true);
        defer engine.ui.ImGui.endChild();
        try drawSelectedAssetPreview(state, layer_context);
    }
    engine.ui.ImGui.separator();
    try drawAssetGroup(state, state.text(.scenes), .scene);
    try drawAssetGroup(state, state.text(.models), .model);
    try drawAssetGroup(state, state.text(.textures), .texture);
    try drawAssetGroup(state, state.text(.shaders), .shader);
}

pub fn drawAssetGroup(state: *EditorState, title: []const u8, kind: AssetKind) !void {
    if (!engine.ui.ImGui.collapsingHeader(title, kind == .scene or kind == .model)) {
        return;
    }

    var has_entries = false;
    for (state.asset_entries.items) |entry| {
        if (entry.kind == kind and utils.assetMatchesFilter(state, entry)) {
            has_entries = true;
            break;
        }
    }
    if (!has_entries) {
        engine.ui.ImGui.text(state.text(.none));
        return;
    }

    var table_id_buffer: [64]u8 = undefined;
    const table_id = try std.fmt.bufPrint(&table_id_buffer, "asset_group_{d}", .{@intFromEnum(kind)});
    if (!engine.ui.ImGui.beginTable(table_id, 2)) {
        return;
    }
    defer engine.ui.ImGui.endTable();

    engine.ui.ImGui.tableSetupColumn(state.text(.name), false, 220.0);
    engine.ui.ImGui.tableSetupColumn(state.text(.path), true, 1.0);
    engine.ui.ImGui.tableHeadersRow();

    for (state.asset_entries.items, 0..) |entry, index| {
        if (entry.kind != kind) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }

        var label_buffer: [320]u8 = undefined;
        const label = try std.fmt.bufPrint(
            &label_buffer,
            "{s}##asset_{d}",
            .{ entry.name, index },
        );
        engine.ui.ImGui.tableNextRow();
        engine.ui.ImGui.tableNextColumn();
        if (engine.ui.ImGui.selectable(label, state.selected_asset_index == index, true, 0.0, 28.0)) {
            state.selected_asset_index = index;
        }
        engine.ui.ImGui.tableNextColumn();
        engine.ui.ImGui.text(entry.path);
    }
}

fn drawSelectedAssetPreview(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (selectedAsset(state)) |entry| {
        engine.ui.ImGui.labelText(state.text(.selected), entry.name);
        engine.ui.ImGui.labelText(state.text(.type), utils.assetKindLabel(state, entry.kind));
        engine.ui.ImGui.labelText(state.text(.path), entry.path);

        switch (entry.kind) {
            .texture => {
                {
                    _ = engine.ui.ImGui.beginChild("content_browser_thumbnail", 0.0, 96.0, true);
                    defer engine.ui.ImGui.endChild();
                    try asset_preview.ensurePreviewTextureForAssetPath(state, layer_context, entry.path);
                    asset_preview.drawCurrentPreviewImage(state);
                }
                engine.ui.ImGui.text(state.text(.use_this_texture_from_details_gt_material));
            },
            .scene => {
                if (engine.ui.ImGui.buttonEx(state.text(.load_selected_scene), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
                    try history.loadScenePath(state, layer_context, entry.path);
                    return;
                }
                if (engine.ui.ImGui.buttonEx(state.text(.save_over_selected_scene), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
                    history.saveScenePath(state, layer_context, entry.path);
                }
                engine.ui.ImGui.text(state.text(.scenes_can_be_loaded_directly_or_overwritten_from_the_current_world));
            },
            .model => {
                if (engine.ui.ImGui.buttonEx(state.text(.instantiate_selected_model), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
                    try history.importModelPath(state, layer_context, entry.path);
                }
                engine.ui.ImGui.text(state.text(.models_are_imported_as_grouped_instances_with_a_movable_root_entity));
            },
            .shader => {
                engine.ui.ImGui.text(state.text(.shader_source_preview_is_currently_metadata_only));
            },
        }
        return;
    }

    engine.ui.ImGui.text(state.text(.no_asset_selected));
}

pub fn selectedAssetCanUseAsTexture(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .texture;
}

pub fn refreshAssetBrowser(state: *EditorState) !void {
    const allocator = state.allocator orelse return;
    clearAssetBrowser(state);

    var assets_dir = std.fs.cwd().openDir("assets", .{ .iterate = true }) catch |err| {
        std.log.warn("failed to open assets directory: {}", .{err});
        return;
    };
    defer assets_dir.close();

    var walker = try assets_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        const kind = utils.assetKindForPath(entry.path) orelse continue;
        const relative_path = try std.fs.path.join(allocator, &.{ "assets", entry.path });
        errdefer allocator.free(relative_path);
        const name = try allocator.dupe(u8, std.fs.path.basename(entry.path));
        errdefer allocator.free(name);

        try state.asset_entries.append(allocator, .{
            .path = relative_path,
            .name = name,
            .kind = kind,
        });
    }

    std.sort.heap(AssetEntry, state.asset_entries.items, {}, utils.lessThanAssetEntry);
    if (state.selected_asset_index) |selected_index| {
        if (selected_index >= state.asset_entries.items.len) {
            state.selected_asset_index = null;
        }
    }
}

pub fn clearAssetBrowser(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.asset_entries.items) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.name);
    }
    state.asset_entries.deinit(allocator);
    state.asset_entries = .empty;
    state.selected_asset_index = null;
}

pub fn selectedAsset(state: *EditorState) ?*const AssetEntry {
    const index = state.selected_asset_index orelse return null;
    if (index >= state.asset_entries.items.len) {
        state.selected_asset_index = null;
        return null;
    }
    return &state.asset_entries.items[index];
}

pub fn selectedAssetCanLoadScene(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .scene;
}

pub fn selectedAssetCanImportModel(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .model;
}

pub fn instantiateSelectedAsset(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entry = selectedAsset(state) orelse return;
    switch (entry.kind) {
        .scene => try history.loadScenePath(state, layer_context, entry.path),
        .model => try history.importModelPath(state, layer_context, entry.path),
        else => {},
    }
}
