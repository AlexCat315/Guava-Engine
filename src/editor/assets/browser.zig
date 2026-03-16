const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const asset_preview = @import("preview.zig");
const console = @import("../ui/windows/console.zig");
const ui_icons = @import("../ui/icons.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;
const BottomPanelTab = state_mod.BottomPanelTab;

pub fn drawContentBrowser(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .content_browser, "content_browser_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    try drawBottomTabs(state);
    engine.ui.ImGui.separator();

    switch (state.bottom_panel_tab) {
        .project => try drawProjectPanel(state, layer_context),
        .console => try console.drawConsolePanel(state),
    }
}

fn drawBottomTabs(state: *EditorState) !void {
    if (drawTabButton(state, .project, state.text(.project))) {
        state.bottom_panel_tab = .project;
    }
    engine.ui.ImGui.sameLine();
    if (drawTabButton(state, .console, state.text(.console))) {
        state.bottom_panel_tab = .console;
    }
}

fn drawTabButton(state: *EditorState, tab: BottomPanelTab, label: []const u8) bool {
    const active = state.bottom_panel_tab == tab;
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    engine.ui.ImGui.pushStyleColor(.button, palette.button);
    engine.ui.ImGui.pushStyleColor(.button_hovered, palette.hovered);
    engine.ui.ImGui.pushStyleColor(.button_active, palette.active);
    defer engine.ui.ImGui.popStyleColor(3);
    return engine.ui.ImGui.buttonEx(label, 104.0, 0.0);
}

fn drawProjectPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    ensureSelectedAssetDirectory(state);

    if (engine.ui.ImGui.buttonEx(state.text(.refresh), 104.0, 0.0)) {
        try refreshAssetBrowser(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx(state.text(.quick_save), 116.0, 0.0)) {
        history.saveScene(state, layer_context);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx("S", 28.0, 0.0)) {
        state.asset_thumbnail_size = 84.0;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx("M", 28.0, 0.0)) {
        state.asset_thumbnail_size = 104.0;
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.buttonEx("L", 28.0, 0.0)) {
        state.asset_thumbnail_size = 132.0;
    }
    engine.ui.ImGui.sameLine();
    var thumbnail_size = state.asset_thumbnail_size;
    engine.ui.ImGui.setNextItemWidth(140.0);
    if (engine.ui.ImGui.dragFloat(state.text(.thumbnails), &thumbnail_size, 1.0, 72.0, 160.0)) {
        state.asset_thumbnail_size = std.math.clamp(thumbnail_size, 72.0, 160.0);
    }

    engine.ui.ImGui.setNextItemWidth(-1.0);
    _ = engine.ui.ImGui.inputText(state.text(.asset_filter), state.asset_filter_buffer[0..]);
    engine.ui.ImGui.separator();

    if (!engine.ui.ImGui.beginTable("project_browser_layout", 2)) {
        return;
    }
    defer engine.ui.ImGui.endTable();
    engine.ui.ImGui.tableSetupColumn(state.text(.folders), false, 224.0);
    engine.ui.ImGui.tableSetupColumn(state.text(.project), true, 1.0);

    engine.ui.ImGui.tableNextRow();
    engine.ui.ImGui.tableNextColumn();
    _ = engine.ui.ImGui.beginChild("project_folders_tree", 0.0, 0.0, true);
    defer engine.ui.ImGui.endChild();
    try drawFolderTree(state);

    engine.ui.ImGui.tableNextColumn();
    _ = engine.ui.ImGui.beginChild("project_assets_grid", 0.0, 0.0, false);
    defer engine.ui.ImGui.endChild();
    try drawSelectedAssetPreview(state, layer_context);
    engine.ui.ImGui.separator();
    try drawAssetGrid(state, layer_context);
}

fn drawFolderTree(state: *EditorState) !void {
    for (state.asset_directories.items) |directory| {
        try drawFolderRow(state, directory);
    }
}

fn drawFolderRow(state: *EditorState, directory: []const u8) !void {
    const selected_directory = selectedDirectory(state);
    const depth = directoryDepth(directory);
    if (depth > 0) {
        engine.ui.ImGui.dummy(@as(f32, @floatFromInt(depth)) * 12.0, 1.0);
        engine.ui.ImGui.sameLine();
    }

    const label_name = directoryName(directory);
    var label_buffer: [320]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buffer, "{s}##dir_{s}", .{ label_name, directory });
    if (engine.ui.ImGui.selectable(label, std.mem.eql(u8, selected_directory, directory), false, 0.0, 24.0)) {
        setSelectedAssetDirectory(state, directory);
    }
}

fn drawAssetGrid(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const available = engine.ui.ImGui.contentRegionAvail();
    const tile_size = std.math.clamp(state.asset_thumbnail_size, 72.0, 160.0);
    const stride = tile_size + 20.0;
    const column_count = @as(i32, @intFromFloat(@max(@floor(available[0] / stride), 1.0)));

    if (!engine.ui.ImGui.beginTable("project_assets_table", column_count)) {
        return;
    }
    defer engine.ui.ImGui.endTable();

    var shown: usize = 0;
    for (state.asset_entries.items, 0..) |entry, index| {
        if (!assetVisibleInDirectory(state, entry)) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }
        shown += 1;
        engine.ui.ImGui.tableNextColumn();
        try drawAssetCard(state, layer_context, entry, index, tile_size);
    }

    if (shown == 0) {
        engine.ui.ImGui.tableNextColumn();
        engine.ui.ImGui.text(state.text(.none));
    }
}

fn drawAssetCard(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: AssetEntry,
    index: usize,
    tile_size: f32,
) !void {
    var child_id_buffer: [64]u8 = undefined;
    const child_id = try std.fmt.bufPrint(&child_id_buffer, "asset_card_{d}", .{index});
    const child_height = tile_size + 46.0;
    _ = engine.ui.ImGui.beginChild(child_id, tile_size + 10.0, child_height, true);
    defer engine.ui.ImGui.endChild();

    const icon_size = tile_size * 0.62;
    const icon_path = assetIconPath(entry.kind);
    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        icon_path,
        icon_size,
        assetIconTint(entry.kind),
    );
    const x_padding = @max((tile_size + 10.0 - icon_size) * 0.5, 4.0);
    engine.ui.ImGui.setCursorPos(.{ x_padding, 10.0 });

    var button_id_buffer: [64]u8 = undefined;
    const button_id = try std.fmt.bufPrint(&button_id_buffer, "asset_thumb_{d}", .{index});
    if (engine.ui.ImGui.imageButton(
        button_id,
        icon_texture,
        icon_size,
        icon_size,
        if (state.selected_asset_index == index) .{ 0.12, 0.32, 0.58, 0.88 } else .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 1.0, 1.0 },
    )) {
        state.selected_asset_index = index;
    }

    const label_y = icon_size + 18.0;
    engine.ui.ImGui.setCursorPos(.{ 8.0, label_y });
    engine.ui.ImGui.text(entry.name);
}

fn drawSelectedAssetPreview(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = engine.ui.ImGui.beginChild("project_asset_preview", 0.0, 188.0, true);
    defer engine.ui.ImGui.endChild();

    if (selectedAsset(state)) |entry| {
        engine.ui.ImGui.labelText(state.text(.selected), entry.name);
        engine.ui.ImGui.labelText(state.text(.type), utils.assetKindLabel(state, entry.kind));
        engine.ui.ImGui.labelText(state.text(.path), entry.path);

        switch (entry.kind) {
            .texture => {
                {
                    _ = engine.ui.ImGui.beginChild("project_thumbnail", 0.0, 96.0, true);
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

fn assetIconPath(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => ui_icons.paths.hierarchy.object,
        .model => ui_icons.paths.hierarchy.mesh,
        .texture => ui_icons.paths.toolbar.settings,
        .shader => ui_icons.paths.toolbar.rotate,
    };
}

fn assetIconTint(kind: AssetKind) [4]u8 {
    return switch (kind) {
        .scene => .{ 164, 203, 255, 255 },
        .model => .{ 196, 234, 255, 255 },
        .texture => .{ 255, 214, 150, 255 },
        .shader => .{ 214, 176, 255, 255 },
    };
}

fn selectedDirectory(state: *const EditorState) []const u8 {
    const value = utils.zeroTerminatedSlice(state.asset_directory_buffer[0..]);
    return if (value.len == 0) "assets" else value;
}

fn ensureSelectedAssetDirectory(state: *EditorState) void {
    if (selectedDirectory(state).len == 0 or state.asset_directories.items.len == 0) {
        setSelectedAssetDirectory(state, "assets");
        return;
    }
    for (state.asset_directories.items) |directory| {
        if (std.mem.eql(u8, directory, selectedDirectory(state))) {
            return;
        }
    }
    setSelectedAssetDirectory(state, "assets");
}

fn setSelectedAssetDirectory(state: *EditorState, path: []const u8) void {
    @memset(state.asset_directory_buffer[0..], 0);
    const copy_len = @min(path.len, state.asset_directory_buffer.len - 1);
    @memcpy(state.asset_directory_buffer[0..copy_len], path[0..copy_len]);
}

fn assetVisibleInDirectory(state: *const EditorState, entry: AssetEntry) bool {
    const selected_dir = selectedDirectory(state);
    const directory = directoryPath(entry.path);
    return std.mem.eql(u8, selected_dir, directory);
}

fn directoryPath(path: []const u8) []const u8 {
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "assets";
    return path[0..slash_index];
}

fn directoryName(path: []const u8) []const u8 {
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash_index + 1 ..];
}

fn directoryDepth(path: []const u8) usize {
    var depth: usize = 0;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            depth += 1;
        }
    }
    return depth -| 1;
}

pub fn selectedAssetCanUseAsTexture(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .texture;
}

pub fn refreshAssetBrowser(state: *EditorState, _: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    clearAssetBrowser(state);

    const registry = if (state.asset_registry) |*value|
        value
    else
        return;

    try registry.refreshProject("assets");
    registry.writeSnapshotToPath("assets/derived/asset_registry.json") catch |err| {
        std.log.warn("failed to write asset registry snapshot: {}", .{err});
    };

    for (registry.records.items) |record| {
        const kind = switch (record.type) {
            .scene => AssetKind.scene,
            .model => AssetKind.model,
            .texture => AssetKind.texture,
            .shader => AssetKind.shader,
            else => continue,
        };

        try state.asset_entries.append(allocator, .{
            .id = try allocator.dupe(u8, record.id),
            .path = try allocator.dupe(u8, record.source_path),
            .name = try allocator.dupe(u8, record.metadata.display_name),
            .kind = kind,
        });
    }

    std.sort.heap(AssetEntry, state.asset_entries.items, {}, utils.lessThanAssetEntry);
    try rebuildAssetDirectories(state);

    if (state.selected_asset_index) |selected_index| {
        if (selected_index >= state.asset_entries.items.len) {
            state.selected_asset_index = null;
        }
    }
}

fn rebuildAssetDirectories(state: *EditorState) !void {
    const allocator = state.allocator orelse return;
    for (state.asset_entries.items) |entry| {
        try addDirectoryPath(state, directoryPath(entry.path));
    }

    std.sort.heap([]u8, state.asset_directories.items, {}, lessThanDirectory);
    if (state.asset_directories.items.len == 0) {
        try state.asset_directories.append(allocator, try allocator.dupe(u8, "assets"));
    }
    ensureSelectedAssetDirectory(state);
}

fn addDirectoryPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    var cursor: usize = 0;
    while (cursor < path.len) : (cursor += 1) {
        if (path[cursor] != '/') {
            continue;
        }
        if (cursor == 0) {
            continue;
        }
        try appendDirectoryIfMissing(state, path[0..cursor]);
    }
    try appendDirectoryIfMissing(state, path);
    if (state.asset_directories.items.len == 0) {
        try state.asset_directories.append(allocator, try allocator.dupe(u8, "assets"));
    }
}

fn appendDirectoryIfMissing(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.asset_directories.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            return;
        }
    }
    try state.asset_directories.append(allocator, try allocator.dupe(u8, path));
}

fn lessThanDirectory(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn clearAssetBrowser(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.asset_entries.items) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.path);
        allocator.free(entry.name);
    }
    state.asset_entries.deinit(allocator);
    state.asset_entries = .empty;

    for (state.asset_directories.items) |directory| {
        allocator.free(directory);
    }
    state.asset_directories.deinit(allocator);
    state.asset_directories = .empty;

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
