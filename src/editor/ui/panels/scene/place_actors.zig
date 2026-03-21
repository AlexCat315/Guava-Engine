const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const MessageId = @import("../../../i18n/message_id.zig").MessageId;
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const history = @import("../../../actions/history.zig");
const camera = @import("../../../interaction/camera.zig");
const utils = @import("../../../common/utils.zig");

const PlaceActorEntry = struct {
    kind: state_mod.PlaceActorKind,
    label_id: MessageId,
    description_id: MessageId,
    icon_path: []const u8,
};

const category_button_height: f32 = 28.0;
const place_actor_row_height: f32 = 32.0;
const place_actor_card_rounding: f32 = 3.0;
const place_actor_list_icon_size: f32 = 18.0;
const place_actor_card_icon_tint = [4]u8{ 210, 215, 220, 255 };
const place_actor_card_text_muted = [4]f32{ 0.55, 0.58, 0.62, 1.0 };
const place_actor_drag_preview_icon_size: f32 = 22.0;
const place_actor_card_idle = ui_icons.ButtonPalette{
    .button = .{ 0.16, 0.17, 0.18, 0.64 },
    .hovered = .{ 0.20, 0.21, 0.22, 0.82 },
    .active = .{ 0.14, 0.15, 0.16, 0.92 },
};
const place_actor_card_active = ui_icons.ButtonPalette{
    .button = .{ 0.16, 0.59, 0.44, 0.8 },
    .hovered = .{ 0.20, 0.69, 0.52, 0.9 },
    .active = .{ 0.12, 0.49, 0.36, 1.0 },
};

const categories = [_]struct {
    id: state_mod.PlaceActorCategory,
    label_id: MessageId,
}{
    .{ .id = .basics, .label_id = .basics },
    .{ .id = .lights, .label_id = .lights },
    .{ .id = .shapes, .label_id = .shapes },
    .{ .id = .vfx, .label_id = .vfx },
};

const basics_entries = [_]PlaceActorEntry{
    .{
        .kind = .empty,
        .label_id = .empty,
        .description_id = .empty_actor_description,
        .icon_path = ui_icons.paths.place_actors.empty,
    },
    .{
        .kind = .camera,
        .label_id = .camera,
        .description_id = .camera_actor_description,
        .icon_path = ui_icons.paths.place_actors.camera,
    },
};

const lights_entries = [_]PlaceActorEntry{
    .{
        .kind = .point_light,
        .label_id = .point_light,
        .description_id = .point_light_actor_description,
        .icon_path = ui_icons.paths.place_actors.point_light,
    },
    .{
        .kind = .spot_light,
        .label_id = .spot_light,
        .description_id = .spot_light_actor_description,
        .icon_path = ui_icons.paths.place_actors.spot_light,
    },
    .{
        .kind = .directional_light,
        .label_id = .directional_light,
        .description_id = .directional_light_actor_description,
        .icon_path = ui_icons.paths.place_actors.directional_light,
    },
};

const shapes_entries = [_]PlaceActorEntry{
    .{
        .kind = .cube,
        .label_id = .cube,
        .description_id = .cube_actor_description,
        .icon_path = ui_icons.paths.place_actors.cube,
    },
    .{
        .kind = .sphere,
        .label_id = .sphere,
        .description_id = .sphere_actor_description,
        .icon_path = ui_icons.paths.place_actors.sphere,
    },
    .{
        .kind = .plane,
        .label_id = .plane,
        .description_id = .plane_actor_description,
        .icon_path = ui_icons.paths.place_actors.plane,
    },
};

const vfx_entries = [_]PlaceActorEntry{
    .{
        .kind = .vfx_fountain,
        .label_id = .vfx_fountain,
        .description_id = .vfx_fountain_actor_description,
        .icon_path = ui_icons.paths.place_actors.vfx_fountain,
    },
    .{
        .kind = .vfx_orbit,
        .label_id = .vfx_orbit,
        .description_id = .vfx_orbit_actor_description,
        .icon_path = ui_icons.paths.place_actors.vfx_orbit,
    },
};

fn getEntriesForCategory(category: state_mod.PlaceActorCategory) []const PlaceActorEntry {
    return switch (category) {
        .basics => basics_entries[0..],
        .lights => lights_entries[0..],
        .shapes => shapes_entries[0..],
        .vfx => vfx_entries[0..],
    };
}

fn drawPlaceActorDragPreview(
    state: *EditorState,
    kind: state_mod.PlaceActorKind,
    label: []const u8,
    description: []const u8,
    icon_texture: *engine.rhi.Texture,
) void {
    if (!gui.beginDragDropSourceU64(state_mod.place_actor_drag_payload, @intFromEnum(kind))) {
        return;
    }
    defer gui.endDragDropSource();

    state.active_drag_payload = .{
        .kind = .place_actor,
        .actor_kind = kind,
    };

    var preview_buffer: [320]u8 = undefined;
    const preview_text = std.fmt.bufPrint(&preview_buffer, "{s}\n{s}", .{ label, description }) catch label;

    gui.image(icon_texture, place_actor_drag_preview_icon_size, place_actor_drag_preview_icon_size);
    gui.sameLine();
    gui.text(preview_text);
}

fn categoryTabWidth(available_width: f32, category_count: usize) f32 {
    if (category_count == 0) {
        return 0.0;
    }
    return (available_width - @as(f32, @floatFromInt(category_count - 1)) * 4.0) / @as(f32, @floatFromInt(category_count));
}

fn drawCategoryButton(state: *EditorState, category: state_mod.PlaceActorCategory, label: []const u8, width: f32) bool {
    const active = state.place_actor_category == category;
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.regular_icon_button_rounding);

    if (active) {
        gui.pushStyleColor(.text, .{ 0.20, 0.60, 0.45, 1.0 });
    }

    const clicked = gui.buttonEx(label, width, category_button_height);

    if (active) {
        gui.popStyleColor(1);
    }

    gui.popStyleVar(1);
    gui.popStyleColor(3);
    return clicked;
}

fn triggerPlaceActorEntry(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    kind: state_mod.PlaceActorKind,
) !void {
    switch (kind) {
        .empty => try history.spawnEmptyEntity(state, layer_context),
        .camera => try history.spawnCameraEntity(state, layer_context),
        .cube => try history.spawnPrimitive(state, layer_context, .cube),
        .sphere => try history.spawnPrimitive(state, layer_context, .sphere),
        .plane => try history.spawnPrimitive(state, layer_context, .plane),
        .point_light => try history.spawnPointLight(state, layer_context),
        .spot_light => try history.spawnSpotLight(state, layer_context),
        .directional_light => try history.spawnDirectionalLight(state, layer_context),
        .vfx_fountain => try history.spawnVfxEntity(state, layer_context, .fountain),
        .vfx_orbit => try history.spawnVfxEntity(state, layer_context, .orbit),
    }
}

pub fn drawPlaceActorsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .place_actors, "place_actors_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    layout.beginSectionBody();

    // Category tabs
    const available_width = gui.contentRegionAvail()[0];
    const category_count = categories.len;
    const tab_width = categoryTabWidth(available_width, category_count);

    for (categories, 0..) |category, i| {
        if (i > 0) {
            gui.sameLine();
        }
        const label = state.text(category.label_id);
        if (drawCategoryButton(state, category.id, label, tab_width)) {
            state.place_actor_category = category.id;
        }
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    // Filter input
    gui.setNextItemWidth(-1.0);
    _ = gui.inputTextWithHint("##place_actors_filter", state.text(.search_place_actors), state.place_actor_filter_buffer[0..]);

    gui.dummy(0.0, 8.0);

    // Actor entries
    const entries = getEntriesForCategory(state.place_actor_category);
    const filter_text = std.mem.sliceTo(state.place_actor_filter_buffer[0..], 0);
    const filter_active = filter_text.len > 0;

    for (entries) |entry| {
        try drawPlaceActorEntry(state, layer_context, entry, filter_active, filter_text);
    }

    layout.endSectionBody();
}

fn drawPlaceActorEntry(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: PlaceActorEntry,
    filter_active: bool,
    filter_text: []const u8,
) !void {
    const label = std.mem.sliceTo(state.text(entry.label_id), 0);
    const description = std.mem.sliceTo(state.text(entry.description_id), 0);

    // Skip if filter is active and doesn't match
    if (filter_active) {
        const label_matches = utils.startsWith(label, filter_text);
        const desc_matches = utils.startsWith(description, filter_text);
        if (!label_matches and !desc_matches) {
            return;
        }
    }

    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        entry.icon_path,
        place_actor_list_icon_size,
        place_actor_card_icon_tint,
    );

    {
        // Compact list row (like hierarchy)
        const row_width = @max(gui.contentRegionAvail()[0], 1.0);
        var row_button_id_buffer: [72]u8 = undefined;
        const row_button_id = try std.fmt.bufPrint(&row_button_id_buffer, "##place_actor_row_{d}", .{@intFromEnum(entry.kind)});
        gui.pushStyleColor(.button, place_actor_card_idle.button);
        gui.pushStyleColor(.button_hovered, place_actor_card_idle.hovered);
        gui.pushStyleColor(.button_active, place_actor_card_active.button);
        gui.pushStyleVarVec2(.frame_padding, .{ 4.0, 2.0 });
        gui.pushStyleVarFloat(.frame_rounding, place_actor_card_rounding);
        const row_clicked = gui.buttonEx(row_button_id, row_width, place_actor_row_height);
        const row_hovered = gui.isItemHovered();
        defer {
            gui.popStyleVar(2);
            gui.popStyleColor(3);
        }

        if (row_clicked) {
            try triggerPlaceActorEntry(state, layer_context, entry.kind);
        }

        if (row_hovered) {
            drawPlaceActorDragPreview(state, entry.kind, label, description, icon_texture);
        }

        // Compact layout: icon on left, label on right
        gui.image(icon_texture, place_actor_list_icon_size, place_actor_list_icon_size);
        gui.sameLine();
        gui.text(label);
    }
}

test "categoryTabWidth distributes category buttons evenly" {
    try std.testing.expectApproxEqAbs(@as(f32, 106.0), categoryTabWidth(436.0, 4), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), categoryTabWidth(320.0, 0), 0.01);
}
