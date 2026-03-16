const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;

pub fn drawContentBrowser(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .content_browser, "content_browser_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    if (engine.ui.ImGui.button(state.text(.refresh))) {
        try refreshAssetBrowser(state);
    }
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.quick_save))) {
        history.saveScene(state, layer_context);
    }

    if (selectedAsset(state)) |entry| {
        engine.ui.ImGui.labelText(state.text(.selected), entry.name);
        engine.ui.ImGui.labelText(state.text(.type), utils.assetKindLabel(state, entry.kind));
        engine.ui.ImGui.labelText(state.text(.path), entry.path);

        if (selectedAssetCanLoadScene(state) and engine.ui.ImGui.button(state.text(.save_over_selected_scene))) {
            history.saveScenePath(state, layer_context, entry.path);
        }
        if (selectedAssetCanLoadScene(state) and engine.ui.ImGui.button(state.text(.load_selected_scene))) {
            try history.loadScenePath(state, layer_context, entry.path);
            return;
        }
        if (selectedAssetCanImportModel(state) and engine.ui.ImGui.button(state.text(.instantiate_selected_model))) {
            try history.importModelPath(state, layer_context, entry.path);
        }
    } else {
        engine.ui.ImGui.text(state.text(.no_asset_selected));
    }

    engine.ui.ImGui.separator();
    _ = engine.ui.ImGui.inputText(state.text(.asset_filter), state.asset_filter_buffer[0..]);
    try drawAssetGroup(state, state.text(.scenes), .scene);
    try drawAssetGroup(state, state.text(.models), .model);
    try drawAssetGroup(state, state.text(.textures), .texture);
    try drawAssetGroup(state, state.text(.shaders), .shader);
}

pub fn drawAssetGroup(state: *EditorState, title: []const u8, kind: AssetKind) !void {
    if (!engine.ui.ImGui.collapsingHeader(title, kind == .scene or kind == .model)) {
        return;
    }

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
            "{s}{s}",
            .{ if (state.selected_asset_index == index) "> " else "", entry.name },
        );
        if (engine.ui.ImGui.button(label)) {
            state.selected_asset_index = index;
        }
        engine.ui.ImGui.sameLine();
        engine.ui.ImGui.text(entry.path);
    }
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
