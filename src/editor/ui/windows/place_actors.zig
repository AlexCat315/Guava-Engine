const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const state_mod = @import("../../core/state.zig");
const MessageId = @import("../../i18n/message_id.zig").MessageId;
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");
const history = @import("../../actions/history.zig");
const camera = @import("../../interaction/camera.zig");
const utils = @import("../../common/utils.zig");

const PlaceActorEntry = struct {
    kind: state_mod.PlaceActorKind,
    label_id: MessageId,
    description_id: MessageId,
    icon_path: []const u8,
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

fn getEntriesForCategory(category: state_mod.PlaceActorCategory) []const PlaceActorEntry {
    return switch (category) {
        .basics => basics_entries[0..],
        .lights => lights_entries[0..],
        .shapes => shapes_entries[0..],
        .vfx => &.{},
    };
}

pub fn drawPlaceActorsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .place_actors, "place_actors_panel");
    _ = engine.ui.ImGui.beginWindow(title);
    defer engine.ui.ImGui.endWindow();

    layout.beginSectionBody();

    // Category tabs
    const available_width = engine.ui.ImGui.contentRegionAvail()[0];
    const category_count = categories.len;
    const tab_width = (available_width - @as(f32, @floatFromInt(category_count - 1)) * 4.0) / @as(f32, @floatFromInt(category_count));

    for (categories, 0..) |category, i| {
        if (i > 0) {
            engine.ui.ImGui.sameLine();
        }
        const is_selected = state.place_actor_category == category.id;
        const label = state.text(category.label_id);
        if (engine.ui.ImGui.buttonEx(label, tab_width, 28.0)) {
            state.place_actor_category = category.id;
        }

        if (is_selected) {
            engine.ui.ImGui.pushStyleColor(.button, .{ 0.24, 0.41, 0.60, 0.84 });
            engine.ui.ImGui.pushStyleColor(.button_hovered, .{ 0.28, 0.48, 0.69, 0.92 });
            engine.ui.ImGui.pushStyleColor(.button_active, .{ 0.21, 0.35, 0.52, 0.96 });
            defer engine.ui.ImGui.popStyleColor(3);
        }
    }

    engine.ui.ImGui.dummy(0.0, 8.0);
    engine.ui.ImGui.separator();
    engine.ui.ImGui.dummy(0.0, 8.0);

    // Filter input
    engine.ui.ImGui.setNextItemWidth(-1.0);
    _ = engine.ui.ImGui.inputTextWithHint("##place_actors_filter", state.text(.search_place_actors), state.place_actor_filter_buffer[0..]);

    engine.ui.ImGui.dummy(0.0, 8.0);

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
        const label_matches = std.mem.startsWith(u8, label, filter_text);
        const desc_matches = std.mem.startsWith(u8, description, filter_text);
        if (!label_matches and !desc_matches) {
            return;
        }
    }

    // Preload the icon texture
    const icon_size: f32 = 20.0;
    const tint = [4]u8{ 176, 196, 220, 255 };
    _ = try ui_icons.ensureTintedIconTexture(state, layer_context, entry.icon_path, icon_size, tint);

    // Draw a selectable for the entry (supports drag-drop)
    const entry_height: f32 = 40.0;
    const available_width = engine.ui.ImGui.contentRegionAvail()[0];

    if (engine.ui.ImGui.selectable(label, false, false, available_width, entry_height)) {
        // Clicked - spawn at default location
        switch (entry.kind) {
            .empty => try history.spawnEmptyEntity(state, layer_context),
            .camera => try history.spawnCameraEntity(state, layer_context),
            .cube => try history.spawnPrimitive(state, layer_context, .cube),
            .sphere => try history.spawnPrimitive(state, layer_context, .sphere),
            .plane => try history.spawnPrimitive(state, layer_context, .plane),
            .point_light => {
                var transform = history.spawnTransform(state, layer_context);
                transform.translation[1] += 1.0;
                const entity_id = try layer_context.world.createLightEntity(.point, transform, 24.0);
                try layer_context.renderer.replaceSelection(entity_id);
                utils.syncInspectorNameBuffer(state, layer_context);
                camera.focusSelection(state, layer_context);
                try history.captureSnapshot(state, layer_context);
            },
            .spot_light => {
                var transform = history.spawnTransform(state, layer_context);
                transform.translation[1] += 1.0;
                const entity_id = try layer_context.world.createLightEntity(.spot, transform, 24.0);
                try layer_context.renderer.replaceSelection(entity_id);
                utils.syncInspectorNameBuffer(state, layer_context);
                camera.focusSelection(state, layer_context);
                try history.captureSnapshot(state, layer_context);
            },
            .directional_light => {
                const transform = history.spawnTransform(state, layer_context);
                const entity_id = try layer_context.world.createLightEntity(.directional, transform, 3.0);
                try layer_context.renderer.replaceSelection(entity_id);
                utils.syncInspectorNameBuffer(state, layer_context);
                camera.focusSelection(state, layer_context);
                try history.captureSnapshot(state, layer_context);
            },
        }
    }

    // Draw description
    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.contentRegionAvail()[0];
    engine.ui.ImGui.text(description);

    // Emit drag payload when hovering and dragging
    if (engine.ui.ImGui.isItemHovered()) {
        const kind_int = @intFromEnum(entry.kind);
        _ = engine.ui.ImGui.dragDropSourceU64(state_mod.place_actor_drag_payload, kind_int, label);
    }

    engine.ui.ImGui.dummy(0.0, 4.0);
}
