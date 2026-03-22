const builtin = @import("builtin");
const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const asset_preview = @import("preview.zig");
const console = @import("../ui/panels/debug/console.zig");
const command_timeline = @import("../ui/panels/debug/command_timeline.zig");
const ui_icons = @import("../ui/icons.zig");
const layout = @import("../ui/layout.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;
const BottomPanelTab = state_mod.BottomPanelTab;
const asset_drag_preview_icon_size: f32 = 24.0;

pub fn drawContentBrowser(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .content_browser, "content_browser_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    try drawBottomTabs(state);
    gui.separator();

    switch (state.bottom_panel_tab) {
        .project => try drawProjectPanel(state, layer_context),
        .console => try console.drawConsolePanel(state),
        .command_timeline => try command_timeline.drawCommandTimelinePanel(state, layer_context),
    }
}

fn drawBottomTabs(state: *EditorState) !void {
    const available_width = gui.contentRegionAvail()[0];
    // 3 tabs: need at least 3*84 + 2*8 = 268 px for horizontal layout
    const stacked = available_width < 268.0;
    const tab_width = if (stacked)
        available_width
    else
        std.math.clamp((available_width - 16.0) / 3.0, 84.0, 140.0);
    if (drawTabButton(state, .project, state.text(.project), tab_width)) {
        state.bottom_panel_tab = .project;
    }
    if (!stacked) {
        gui.sameLine();
    } else {
        gui.dummy(0.0, 4.0);
    }
    if (drawTabButton(state, .console, state.text(.console), tab_width)) {
        state.bottom_panel_tab = .console;
    }
    if (!stacked) {
        gui.sameLine();
    } else {
        gui.dummy(0.0, 4.0);
    }
    if (drawTabButton(state, .command_timeline, state.text(.command_timeline), tab_width)) {
        state.bottom_panel_tab = .command_timeline;
    }
}

fn drawAssetDragPreview(
    state: *EditorState,
    entry: AssetEntry,
    payload_type: []const u8,
    payload_value: u64,
    preview_texture: *const engine.rhi.Texture,
) void {
    if (!gui.beginDragDropSourceU64(payload_type, payload_value)) {
        return;
    }
    defer gui.endDragDropSource();

    state.active_drag_payload = .{
        .kind = if (std.mem.eql(u8, payload_type, state_mod.asset_model_drag_payload))
            .asset_model
        else if (std.mem.eql(u8, payload_type, state_mod.asset_material_drag_payload))
            .asset_material
        else
            .asset_texture,
        .asset_index = @intCast(payload_value),
    };

    var preview_buffer: [384]u8 = undefined;
    const preview_text = std.fmt.bufPrint(
        &preview_buffer,
        "{s}\n{s}",
        .{ entry.name, utils.assetKindLabel(state, entry.kind) },
    ) catch entry.name;

    gui.image(preview_texture, asset_drag_preview_icon_size, asset_drag_preview_icon_size);
    gui.sameLine();
    gui.text(preview_text);
}

fn drawAssetDragSource(state: *EditorState, entry: AssetEntry, index: usize, preview_texture: *const engine.rhi.Texture) void {
    switch (entry.kind) {
        .model => drawAssetDragPreview(state, entry, state_mod.asset_model_drag_payload, @intCast(index), preview_texture),
        .material => drawAssetDragPreview(state, entry, state_mod.asset_material_drag_payload, @intCast(index), preview_texture),
        .texture => drawAssetDragPreview(state, entry, state_mod.asset_texture_drag_payload, @intCast(index), preview_texture),
        else => {},
    }
}

fn drawTabButton(state: *EditorState, tab: BottomPanelTab, label: []const u8, width: f32) bool {
    const active = state.bottom_panel_tab == tab;
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);

    // 如果是激活状态，文字颜色也使用强调色，增加区分度
    if (active) {
        gui.pushStyleColor(.text, .{ 0.20, 0.60, 0.45, 1.0 });
    }

    const clicked = gui.buttonEx(label, width, 0.0);

    if (active) {
        gui.popStyleColor(1);

        // 绘制底部的指示条 (Indicator)
        const pos_min = gui.getItemRectMin();
        const pos_max = gui.getItemRectMax();
        const draw_list = gui.getWindowDrawList();

        const indicator_y = pos_max[1] - 2.0;
        const indicator_color = gui.getColorU32Slot(.text);

        draw_list.addLine(
            .{ pos_min[0] + 4.0, indicator_y },
            .{ pos_max[0] - 4.0, indicator_y },
            indicator_color,
            2.0,
        );
    }

    gui.popStyleColor(3);
    return clicked;
}

fn drawThumbnailPresetButton(state: *EditorState, label: []const u8, size: f32) void {
    const active = @abs(state.asset_thumbnail_size - size) < 0.5;
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.compact_icon_button_rounding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(3);
    }

    if (gui.buttonEx(label, 32.0, 30.0)) {
        state.asset_thumbnail_size = size;
    }
}

fn drawBreadcrumbButton(label: []const u8, active: bool, width: f32) bool {
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);

    if (active) {
        gui.pushStyleColor(.text, .{ 0.20, 0.60, 0.45, 1.0 });
    }

    gui.pushStyleVarVec2(.frame_padding, ui_icons.compact_icon_button_padding);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.compact_icon_button_rounding);

    const clicked = gui.buttonEx(label, width, 0.0);

    if (active) {
        gui.popStyleColor(1);
    }

    gui.popStyleVar(2);
    gui.popStyleColor(3);
    return clicked;
}

fn drawProjectPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    ensureSelectedAssetDirectory(state);
    try drawProjectPanelHeader(state, layer_context);

    if (!gui.beginTable("project_browser_layout", 2)) {
        return;
    }
    defer gui.endTable();
    gui.tableSetupColumn(state.text(.folders), false, std.math.clamp(gui.contentRegionAvail()[0] * 0.24, 132.0, 220.0));
    gui.tableSetupColumn(state.text(.project), true, 1.0);

    gui.tableNextRow();
    gui.tableNextColumn();
    _ = gui.beginChild("project_folders_tree", 0.0, 0.0, true);
    defer gui.endChild();
    try drawFolderTree(state);

    gui.tableNextColumn();
    _ = gui.beginChild("project_assets_grid", 0.0, 0.0, false);
    defer gui.endChild();
    try drawSelectedAssetPreview(state, layer_context);
    gui.separator();
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
        gui.dummy(@as(f32, @floatFromInt(depth)) * 12.0, 1.0);
        gui.sameLine();
    }

    const label_name = directoryName(directory);
    var label_buffer: [320]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buffer, "{s}##dir_{s}", .{ label_name, directory });
    if (gui.selectable(label, std.mem.eql(u8, selected_directory, directory), false, 0.0, 24.0)) {
        setSelectedAssetDirectory(state, directory);
    }
}

fn drawAssetGrid(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    switch (state.browser_view_mode) {
        .grid => try drawAssetGridView(state, layer_context),
        .list => try drawAssetListView(state, layer_context),
    }
}

fn drawAssetGridView(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const available = gui.contentRegionAvail();
    const tile_size = std.math.clamp(state.asset_thumbnail_size, 72.0, 160.0);
    const stride = tile_size + 20.0;
    const column_count = @as(i32, @intFromFloat(@max(@floor(available[0] / stride), 1.0)));

    if (!gui.beginTable("project_assets_table", column_count)) {
        return;
    }
    defer gui.endTable();

    var shown: usize = 0;
    for (state.asset_entries.items, 0..) |entry, index| {
        if (!assetVisibleInDirectory(state, entry)) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }
        shown += 1;
        gui.tableNextColumn();
        try drawAssetCard(state, layer_context, entry, index, tile_size);
    }

    // Show empty state message if no assets
    if (shown == 0) {
        gui.tableNextColumn();
        gui.pushStyleColor(.text, .{ 0.61, 0.64, 0.68, 1.0 });
        const selected_dir = selectedDirectory(state);
        if (std.mem.eql(u8, selected_dir, "/")) {
            gui.text("No assets in project. Add files to the assets folder.");
        } else {
            gui.text("Drop assets here or use Import to add files");
        }
        gui.popStyleColor(1);
    }
}

fn drawAssetListView(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    // List view: icon + name in a single row
    const row_height: f32 = 36.0;

    for (state.asset_entries.items, 0..) |entry, index| {
        if (!assetVisibleInDirectory(state, entry)) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }

        var button_id_buffer: [64]u8 = undefined;
        const button_id = try std.fmt.bufPrint(&button_id_buffer, "asset_list_{d}", .{index});

        const icon_size: f32 = 24.0;
        const icon_path = assetIconPath(entry.kind);

        // Create a selectable for the entire row
        const selected = state.selected_asset_index == index;
        const icon_tint: [4]u8 = if (selected) .{ 34, 197, 94, 255 } else assetIconTint(entry.kind);
        const icon_texture = try ui_icons.ensureTintedIconTexture(
            state,
            layer_context,
            icon_path,
            icon_size,
            icon_tint,
        );
        const row_texture = if (entry.kind == .material)
            (try queueAndResolveMaterialThumbnailTexture(state, layer_context, &entry) orelse icon_texture)
        else
            icon_texture;

        if (gui.selectable(button_id, selected, false, 0.0, row_height)) {
            state.selected_asset_index = index;
        }
        drawAssetDragSource(state, entry, index, row_texture);

        // Draw icon on the same line
        gui.sameLine();
        gui.image(row_texture, icon_size, icon_size);

        // Draw name on the same line
        gui.sameLine();
        gui.text(entry.name);
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
    const child_height = tile_size + 62.0;
    _ = gui.beginChild(child_id, tile_size + 10.0, child_height, true);
    defer gui.endChild();

    const icon_size = tile_size * 0.62;
    const icon_path = assetIconPath(entry.kind);
    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        icon_path,
        icon_size,
        assetIconTint(entry.kind),
    );
    const card_texture = if (entry.kind == .material)
        (try queueAndResolveMaterialThumbnailTexture(state, layer_context, &entry) orelse icon_texture)
    else
        icon_texture;
    const x_padding = @max((tile_size + 10.0 - icon_size) * 0.5, 4.0);
    gui.setCursorPos(.{ x_padding, 10.0 });

    var button_id_buffer: [64]u8 = undefined;
    const button_id = try std.fmt.bufPrint(&button_id_buffer, "asset_thumb_{d}", .{index});
    if (gui.imageButton(
        button_id,
        card_texture,
        icon_size,
        icon_size,
        if (state.selected_asset_index == index) .{ 0.13, 0.55, 0.35, 0.88 } else .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 1.0, 1.0 },
    )) {
        state.selected_asset_index = index;
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(entry.name);
    }
    drawAssetDragSource(state, entry, index, card_texture);

    const label_y = icon_size + 18.0;
    gui.setCursorPos(.{ 8.0, label_y });
    gui.textWrapped(entry.name);
}

fn drawSelectedAssetPreview(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const preview_height = std.math.clamp(gui.contentRegionAvail()[1] * 0.32, 152.0, 220.0);
    _ = gui.beginChild("project_asset_preview", 0.0, preview_height, true);
    defer gui.endChild();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    if (selectedAsset(state)) |entry| {
        gui.labelText(state.text(.selected), entry.name);
        gui.labelText(state.text(.type), utils.assetKindLabel(state, entry.kind));
        gui.labelText(state.text(.path), entry.path);

        switch (entry.kind) {
            .texture => {
                {
                    _ = gui.beginChild("project_thumbnail", 0.0, 96.0, true);
                    defer gui.endChild();
                    try asset_preview.ensurePreviewTextureForAssetPath(state, layer_context, entry.path);
                    asset_preview.drawCurrentPreviewImage(state);
                }
                gui.textWrapped(state.text(.use_this_texture_from_details_gt_material));
            },
            .scene => {
                if (gui.buttonEx(state.text(.load_selected_scene), gui.contentRegionAvail()[0], 0.0)) {
                    try history.loadScenePath(state, layer_context, entry.path);
                    return;
                }
                if (gui.buttonEx(state.text(.save_over_selected_scene), gui.contentRegionAvail()[0], 0.0)) {
                    history.saveScenePath(state, layer_context, entry.path);
                }
                gui.textWrapped(state.text(.scenes_can_be_loaded_directly_or_overwritten_from_the_current_world));
            },
            .model => {
                if (gui.buttonEx(state.text(.instantiate_selected_model), gui.contentRegionAvail()[0], 0.0)) {
                    try history.importModelPath(state, layer_context, entry.path);
                }
                gui.textWrapped(state.text(.models_are_imported_as_grouped_instances_with_a_movable_root_entity));
            },
            .material => {
                // Try to show material preview
                try drawMaterialAssetPreview(state, layer_context, entry);
            },
            .shader => {
                gui.textWrapped(state.text(.shader_source_preview_is_currently_metadata_only));
            },
        }
        return;
    }

    gui.textWrapped(state.text(.no_asset_selected));
}

// Compressed single-line header: breadcrumbs (left), search (center), thumbnail slider (right)
fn drawProjectPanelHeader(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = layer_context; // Reserved for future use (e.g., context menu on breadcrumb)
    const width = gui.contentRegionAvail()[0];

    // Left: Breadcrumb path (clickable)
    const breadcrumb_width = std.math.clamp(width * 0.35, 120.0, 280.0);
    const current = selectedDirectory(state);
    const is_at_root = std.mem.eql(u8, current, "/");
    const root_label = if (is_at_root) "/" else state.text(.assets_menu);
    if (gui.buttonEx(root_label, breadcrumb_width, 26.0)) {
        setSelectedAssetDirectory(state, "/");
    }

    // Show sub-path buttons if there's more content
    var path_buffer: [256]u8 = undefined;
    // Skip leading slash if present
    var path_pos: usize = if (current.len > 0 and current[0] == '/') 1 else 0;
    while (path_pos < current.len) {
        gui.sameLine();
        const next_slash = std.mem.indexOfScalarPos(u8, current, path_pos, '/') orelse current.len;
        const segment = current[path_pos..next_slash];
        if (segment.len > 0) {
            const segment_label = try std.fmt.bufPrint(&path_buffer, "/{s}", .{segment});
            if (gui.buttonEx(segment_label, 0.0, 26.0)) {
                setSelectedAssetDirectory(state, current[0..next_slash]);
            }
        }
        path_pos = next_slash + 1;
    }

    // Center: Search box
    const search_width = std.math.clamp(width * 0.30, 140.0, 260.0);
    gui.sameLine();
    gui.setNextItemWidth(search_width);
    _ = gui.inputTextWithHint("##asset_filter", state.text(.search_assets), state.asset_filter_buffer[0..]);

    // Right: Thumbnail size slider + view mode toggle
    const controls_start = breadcrumb_width + search_width + 32.0;
    const controls_width = width - controls_start;

    gui.sameLine();
    if (controls_width >= 180.0) {
        // Full controls
        gui.setNextItemWidth(controls_width * 0.45);
        var thumbnail_size = state.asset_thumbnail_size;
        if (gui.dragFloat("##asset_thumbnail_size", &thumbnail_size, 1.0, 72.0, 160.0)) {
            state.asset_thumbnail_size = std.math.clamp(thumbnail_size, 72.0, 160.0);
        }
        gui.sameLine();

        // View mode toggle
        const view_mode_palette = if (state.browser_view_mode == .grid)
            ui_icons.palettes.toolbar_active
        else
            ui_icons.palettes.toolbar_idle;
        gui.pushStyleColor(.button, view_mode_palette.button);
        gui.pushStyleColor(.button_hovered, view_mode_palette.hovered);
        gui.pushStyleColor(.button_active, view_mode_palette.active);
        if (gui.buttonEx(if (state.browser_view_mode == .grid) " Grid " else " List ", 0.0, 26.0)) {
            state.browser_view_mode = switch (state.browser_view_mode) {
                .grid => .list,
                .list => .grid,
            };
        }
        gui.popStyleColor(3);
    } else if (controls_width >= 80.0) {
        // Compact - just view mode
        const view_mode_palette = if (state.browser_view_mode == .grid)
            ui_icons.palettes.toolbar_active
        else
            ui_icons.palettes.toolbar_idle;
        gui.pushStyleColor(.button, view_mode_palette.button);
        gui.pushStyleColor(.button_hovered, view_mode_palette.hovered);
        gui.pushStyleColor(.button_active, view_mode_palette.active);
        if (gui.buttonEx(if (state.browser_view_mode == .grid) "Grid" else "List", 0.0, 26.0)) {
            state.browser_view_mode = switch (state.browser_view_mode) {
                .grid => .list,
                .list => .grid,
            };
        }
        gui.popStyleColor(3);
    }

    gui.separator();
}

fn drawProjectToolbar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const width = gui.contentRegionAvail()[0];
    const stacked_primary = width < 232.0;
    const primary_button_width = if (stacked_primary)
        width
    else if (width >= 680.0)
        116.0
    else
        @max((width - 8.0) * 0.5, 100.0);

    if (gui.buttonEx(state.text(.refresh), primary_button_width, 30.0)) {
        try refreshAssetBrowser(state, layer_context);
    }
    if (!stacked_primary) {
        gui.sameLine();
    } else {
        gui.dummy(0.0, 6.0);
    }
    if (gui.buttonEx(state.text(.quick_save), primary_button_width, 30.0)) {
        history.saveScene(state, layer_context);
    }

    gui.dummy(0.0, 8.0);
    const thumb_columns = layout.responsiveButtonColumns(3, 32.0);
    drawThumbnailPresetButton(state, "S", 84.0);
    layout.advanceResponsiveRow(1, thumb_columns);
    drawThumbnailPresetButton(state, "M", 104.0);
    layout.advanceResponsiveRow(2, thumb_columns);
    drawThumbnailPresetButton(state, "L", 132.0);

    gui.dummy(0.0, 6.0);
    const compact_thumbnails = width < 320.0;
    _ = layout.drawResponsivePropertyLabel(state.text(.thumbnails), if (compact_thumbnails) width else 108.0);
    var thumbnail_size = state.asset_thumbnail_size;
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##asset_thumbnail_size", &thumbnail_size, 1.0, 72.0, 160.0)) {
        state.asset_thumbnail_size = std.math.clamp(thumbnail_size, 72.0, 160.0);
    }

    // View mode toggle (Grid / List)
    gui.dummy(0.0, 8.0);
    const view_mode_palette_grid = if (state.browser_view_mode == .grid) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    const view_mode_palette_list = if (state.browser_view_mode == .list) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, view_mode_palette_grid.button);
    gui.pushStyleColor(.button_hovered, view_mode_palette_grid.hovered);
    gui.pushStyleColor(.button_active, view_mode_palette_grid.active);
    if (gui.buttonEx(state.text(.grid_view), 54.0, 30.0)) {
        state.browser_view_mode = .grid;
    }
    gui.popStyleColor(3);

    gui.pushStyleColor(.button, view_mode_palette_list.button);
    gui.pushStyleColor(.button_hovered, view_mode_palette_list.hovered);
    gui.pushStyleColor(.button_active, view_mode_palette_list.active);
    if (gui.buttonEx(state.text(.list_view), 54.0, 30.0)) {
        state.browser_view_mode = .list;
    }
    gui.popStyleColor(3);
}

fn drawBreadcrumbs(state: *EditorState) !void {
    const current = selectedDirectory(state);
    const stacked = gui.contentRegionAvail()[0] < 360.0;
    var start: usize = 0;
    var crumb_index: usize = 0;

    while (start <= current.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, current, start, '/') orelse current.len;
        const crumb_path = current[0..next_slash];
        const crumb_label = if (crumb_index == 0)
            (if (std.mem.eql(u8, current, "/")) "/" else state.text(.assets_menu))
        else
            directoryName(crumb_path);
        const is_current = next_slash == current.len;
        var stacked_label_buffer: [160]u8 = undefined;
        const button_label = if (stacked and crumb_index > 0)
            try std.fmt.bufPrint(&stacked_label_buffer, "> {s}", .{crumb_label})
        else
            crumb_label;
        if (drawBreadcrumbButton(button_label, is_current, if (stacked) gui.contentRegionAvail()[0] else 0.0)) {
            setSelectedAssetDirectory(state, crumb_path);
        }

        if (next_slash == current.len) {
            break;
        }
        if (!stacked) {
            gui.sameLine();
            gui.pushStyleColor(.text, .{ 0.58, 0.62, 0.68, 1.0 });
            gui.text(">");
            gui.popStyleColor(1);
            gui.sameLine();
        } else {
            gui.dummy(0.0, 4.0);
        }

        start = next_slash + 1;
        crumb_index += 1;
    }
}

fn assetIconPath(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => ui_icons.paths.hierarchy.object,
        .model => ui_icons.paths.hierarchy.mesh,
        .material => ui_icons.paths.toolbar.material,
        .texture => ui_icons.paths.toolbar.settings,
        .shader => ui_icons.paths.toolbar.rotate,
    };
}

fn assetIconTint(kind: AssetKind) [4]u8 {
    return switch (kind) {
        .scene => .{ 164, 203, 255, 255 },
        .model => .{ 196, 234, 255, 255 },
        .material => .{ 186, 228, 196, 255 },
        .texture => .{ 255, 214, 150, 255 },
        .shader => .{ 214, 176, 255, 255 },
    };
}

fn assetKindForRecordType(record_type: engine.assets.AssetType) ?AssetKind {
    return switch (record_type) {
        .scene => .scene,
        .model => .model,
        .material => .material,
        .texture => .texture,
        .shader => .shader,
        else => null,
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
    if (std.mem.eql(u8, selected_dir, "/")) {
        return true;
    }
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

fn materialHandleForAssetEntryInResources(
    resources: *const engine.assets.ResourceLibrary,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    if (entry.kind != .material) {
        return null;
    }
    return resources.materialHandleByAssetId(entry.id);
}

pub fn materialHandleForAssetEntry(
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    return materialHandleForAssetEntryInResources(layer_context.world.assets(), entry);
}

fn syncEntityMaterialFromResource(
    entity: *engine.scene.Entity,
    material_handle: engine.assets.MaterialHandle,
    material_resource: *const engine.assets.MaterialResource,
) bool {
    if (entity.material) |*material_component| {
        var changed = false;
        if (material_component.handle != material_handle) {
            material_component.handle = material_handle;
            changed = true;
        }
        if (material_component.shading != material_resource.shading) {
            material_component.shading = material_resource.shading;
            changed = true;
        }
        if (!std.meta.eql(material_component.base_color_factor, material_resource.base_color_factor)) {
            material_component.base_color_factor = material_resource.base_color_factor;
            changed = true;
        }
        return changed;
    }

    entity.material = .{
        .handle = material_handle,
        .shading = material_resource.shading,
        .base_color_factor = material_resource.base_color_factor,
    };
    return true;
}

fn drawMaterialAssetPreview(state: *EditorState, layer_context: *engine.core.LayerContext, entry: *const AssetEntry) !void {
    const preview_texture = try queueAndResolveMaterialThumbnailTexture(state, layer_context, entry);
    try drawMaterialThumbnailPreview(state, layer_context, preview_texture);

    const material_handle = materialHandleForAssetEntry(layer_context, entry);

    if (material_handle) |handle| {
        // Material is loaded - show preview info
        if (layer_context.world.assets().material(handle)) |material_resource| {
            // Show shading model
            const shading_label = switch (material_resource.shading) {
                .unlit => "Unlit",
                .lambert => "Lambert",
                .pbr_metallic_roughness => "PBR Metallic",
            };
            gui.labelText("Shading", shading_label);

            // Show base color
            const color = material_resource.base_color_factor;
            var color_text: [32]u8 = undefined;
            const color_str = try std.fmt.bufPrint(&color_text, "R:{d:.2} G:{d:.2} B:{d:.2}", .{ color[0], color[1], color[2] });
            gui.labelText("Base Color", color_str);

            // Show texture info
            if (material_resource.base_color_texture != null) {
                gui.labelText("Texture", "Assigned");
            } else {
                gui.labelText("Texture", "None");
            }
        }

        // Show apply button if entity is selected
        if (layer_context.renderer.selectedEntity()) |entity_id| {
            gui.dummy(0.0, 8.0);
            if (gui.buttonEx(state.text(.apply_material), gui.contentRegionAvail()[0], 0.0)) {
                _ = try applyMaterialAssetToEntity(state, layer_context, entry, entity_id);
            }
        }
    } else {
        // Material not loaded - show placeholder
        gui.textWrapped(state.text(.material_asset_not_loaded_in_current_world));
    }

    gui.textWrapped(state.text(.drop_material_here));
}

fn drawMaterialThumbnailPreview(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    texture: ?*const engine.rhi.Texture,
) !void {
    _ = gui.beginChild("project_material_thumbnail", 0.0, 116.0, true);
    defer gui.endChild();

    const available = gui.contentRegionAvail();
    const preview_size = std.math.clamp(@min(available[0], available[1]) - 8.0, 72.0, 104.0);
    const offset_x = @max((available[0] - preview_size) * 0.5, 0.0);
    const offset_y = @max((available[1] - preview_size) * 0.5, 0.0);
    gui.setCursorPos(.{ offset_x, offset_y });

    if (texture) |resolved| {
        gui.image(resolved, preview_size, preview_size);
        return;
    }

    const fallback_size = preview_size * 0.62;
    const fallback_offset_x = @max((available[0] - fallback_size) * 0.5, 0.0);
    const fallback_offset_y = @max((available[1] - fallback_size) * 0.5, 0.0);
    gui.setCursorPos(.{ fallback_offset_x, fallback_offset_y });
    const fallback_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.toolbar.material,
        fallback_size,
        assetIconTint(.material),
    );
    gui.image(fallback_texture, fallback_size, fallback_size);
}

pub fn applyMaterialAssetToEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
    entity_id: engine.scene.EntityId,
) !bool {
    const material_handle = materialHandleForAssetEntry(layer_context, entry) orelse {
        if (!builtin.is_test and entry.kind == .material) {
            std.log.warn("material asset '{s}' is not loaded into the current world", .{entry.path});
        }
        return false;
    };
    if (state.editor_camera != null and entity_id == state.editor_camera.?) {
        return false;
    }
    if (utils.isEntityFrozen(state, entity_id) or utils.isEntitySelectionLocked(state, entity_id)) {
        return false;
    }

    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const material_resource = layer_context.world.assets().material(material_handle) orelse return false;
    if (!syncEntityMaterialFromResource(entity, material_handle, material_resource)) {
        return false;
    }

    try history.captureSnapshot(state, layer_context);
    return true;
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
        const kind = assetKindForRecordType(record.type) orelse continue;

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
        const root_directory = try allocator.dupe(u8, "assets");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
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
        const root_directory = try allocator.dupe(u8, "assets");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
    }
}

fn appendDirectoryIfMissing(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.asset_directories.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            return;
        }
    }
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try state.asset_directories.append(allocator, owned_path);
}

fn lessThanDirectory(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn clearAssetBrowser(state: *EditorState) void {
    clearMaterialThumbnailRequestQueue(state);
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

fn queueAndResolveMaterialThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) !?*const engine.rhi.Texture {
    if (entry.kind != .material) {
        return null;
    }
    try queueMaterialThumbnailRequest(state, entry.id);
    return layer_context.renderer.materialThumbnailTexture(entry.id);
}

fn queueMaterialThumbnailRequest(state: *EditorState, asset_id: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |existing| {
        if (std.mem.eql(u8, existing, asset_id)) {
            return;
        }
    }
    const queued_asset_id = try allocator.dupe(u8, asset_id);
    errdefer allocator.free(queued_asset_id);
    try state.material_thumbnail_queue.append(allocator, queued_asset_id);
}

pub fn flushMaterialThumbnailRequests(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        defer allocator.free(asset_id);
        try layer_context.renderer.requestMaterialThumbnail(layer_context.scene, asset_id, layer_context.frame_index);
    }
    state.material_thumbnail_queue.clearRetainingCapacity();
}

pub fn clearMaterialThumbnailRequestQueue(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        allocator.free(asset_id);
    }
    state.material_thumbnail_queue.deinit(allocator);
    state.material_thumbnail_queue = .empty;
}

test "material assets map to browser visuals and kinds" {
    try std.testing.expectEqual(AssetKind.material, assetKindForRecordType(.material).?);
    try std.testing.expectEqualStrings(ui_icons.paths.toolbar.material, assetIconPath(.material));
    try std.testing.expectEqual([4]u8{ 186, 228, 196, 255 }, assetIconTint(.material));
}

test "material thumbnail request queue deduplicates asset ids" {
    var state = EditorState{
        .allocator = std.testing.allocator,
    };
    defer clearMaterialThumbnailRequestQueue(&state);

    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://stone");

    try std.testing.expectEqual(@as(usize, 2), state.material_thumbnail_queue.items.len);
    try std.testing.expectEqualStrings("material://brick", state.material_thumbnail_queue.items[0]);
    try std.testing.expectEqualStrings("material://stone", state.material_thumbnail_queue.items[1]);
}

fn makeOwnedMaterialRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !engine.assets.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = .material,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "test-source-hash"),
        .import_settings_hash = try allocator.dupe(u8, "test-import-settings"),
        .import_version = engine.assets.AssetType.material.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(engine.assets.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, engine.assets.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ".guava_material"),
        },
    };
}

test "applyMaterialAssetToEntity assigns loaded material assets to entities" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const material_handle = try world.assets().createMaterial(.{
        .name = "Brick Material",
        .shading = .lambert,
        .base_color_factor = .{ 0.22, 0.41, 0.63, 1.0 },
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedMaterialRecord(std.testing.allocator, "material://brick", "assets/materials/brick.guava_material", "Brick"),
    );

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://brick"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/brick.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Brick"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id));
    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expect(entity.material != null);
    try std.testing.expectEqual(material_handle, entity.material.?.handle.?);
    try std.testing.expectEqual(engine.scene.ShadingModel.lambert, entity.material.?.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.22, 0.41, 0.63, 1.0 }, entity.material.?.base_color_factor);
}

test "applyMaterialAssetToEntity rejects unloaded material assets" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://missing"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/missing.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Missing"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(!(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id)));
    try std.testing.expect(world.getEntityConst(entity_id).?.material == null);
}
