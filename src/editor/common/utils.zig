const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;

pub fn assetKindForPath(path: []const u8) ?AssetKind {
    if (std.mem.endsWith(u8, path, ".guava_scene")) {
        return .scene;
    }
    if (std.mem.endsWith(u8, path, ".gltf")) {
        return .model;
    }
    if (std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) {
        return .texture;
    }
    if (std.mem.endsWith(u8, path, ".glsl") or std.mem.endsWith(u8, path, ".spv") or std.mem.endsWith(u8, path, ".json")) {
        return .shader;
    }
    return null;
}

pub fn lessThanAssetEntry(_: void, lhs: AssetEntry, rhs: AssetEntry) bool {
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

pub fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matches = false;
                break;
            }
        }
        if (matches) {
            return true;
        }
    }
    return false;
}

pub fn zeroTerminatedSlice(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

pub fn viewportDrawableSize(window: *const engine.platform.Window, logical_extent: [2]f32) [2]u32 {
    if (logical_extent[0] < 1.0 or logical_extent[1] < 1.0 or window.logical_width == 0 or window.logical_height == 0 or window.drawable_width == 0 or window.drawable_height == 0) {
        return .{ 0, 0 };
    }

    const scale_x = @as(f32, @floatFromInt(window.drawable_width)) / @as(f32, @floatFromInt(window.logical_width));
    const scale_y = @as(f32, @floatFromInt(window.drawable_height)) / @as(f32, @floatFromInt(window.logical_height));
    return .{
        @max(@as(u32, @intFromFloat(@max(logical_extent[0] * scale_x, 0.0))), 1),
        @max(@as(u32, @intFromFloat(@max(logical_extent[1] * scale_y, 0.0))), 1),
    };
}

pub fn swizzleRgbaToBgra(bytes: []u8) void {
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        const r = bytes[index];
        bytes[index] = bytes[index + 2];
        bytes[index + 2] = r;
    }
}

pub fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -1.45, 1.45);
}

pub fn clampDistance(distance: f32) f32 {
    return std.math.clamp(distance, 1.5, 40.0);
}

pub fn clampScale(scale: f32) f32 {
    return std.math.clamp(scale, 0.05, 100.0);
}

pub fn assetKindLabel(state: *const EditorState, kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => state.text(.scene),
        .model => state.text(.model),
        .texture => state.text(.texture),
        .shader => state.text(.shader),
    };
}

pub fn primitiveLabel(state: *const EditorState, primitive: engine.scene.Primitive) []const u8 {
    return switch (primitive) {
        .cube => state.text(.cube),
        .sphere => state.text(.sphere),
        .plane => state.text(.plane),
        .custom => state.text(.custom),
    };
}

pub fn shadingLabel(state: *const EditorState, shading: engine.scene.ShadingModel) []const u8 {
    return switch (shading) {
        .unlit => state.text(.unlit),
        .lambert => state.text(.lambert),
        .pbr_metallic_roughness => state.text(.pbr),
    };
}

pub fn isEntitySelected(_: *const EditorState, layer_context: *const engine.core.LayerContext, entity_id: engine.scene.EntityId) bool {
    for (layer_context.renderer.selectedEntities()) |selected_id| {
        if (selected_id == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn hasVisibleChildren(_: *const EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
    for (world.entities.items) |entity| {
        if (!entity.editor_only and entity.parent == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn shouldShowEntityInSceneTree(state: *const EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
    const filter = zeroTerminatedSlice(state.scene_filter_buffer[0..]);
    if (filter.len == 0) {
        return true;
    }
    return entityMatchesFilterRecursive(state, world, entity_id, filter);
}

pub fn entityMatchesFilterRecursive(
    state: *const EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    filter: []const u8,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    if (containsAsciiInsensitive(entity.name, filter)) {
        return true;
    }
    for (world.entities.items) |child| {
        if (!child.editor_only and child.parent == entity_id and entityMatchesFilterRecursive(state, world, child.id, filter)) {
            return true;
        }
    }
    return false;
}

pub fn assetMatchesFilter(state: *const EditorState, entry: AssetEntry) bool {
    const filter = zeroTerminatedSlice(state.asset_filter_buffer[0..]);
    if (filter.len == 0) {
        return true;
    }
    return containsAsciiInsensitive(entry.name, filter) or containsAsciiInsensitive(entry.path, filter);
}

pub fn syncInspectorNameBuffer(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const selected = layer_context.renderer.selectedEntity();
    if (selected == state.inspector_name_entity) {
        return;
    }

    @memset(state.inspector_name_buffer[0..], 0);
    if (selected) |selected_id| {
        if (layer_context.world.getEntityConst(selected_id)) |entity| {
            const copy_len = @min(entity.name.len, state.inspector_name_buffer.len - 1);
            @memcpy(state.inspector_name_buffer[0..copy_len], entity.name[0..copy_len]);
        }
    }
    state.inspector_name_entity = selected;
}
