const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const utils = @import("../../../common/utils.zig");
const history = @import("../../../actions/history.zig");
const content_browser = @import("../../../assets/browser.zig");
const inspector = @import("../scene/inspector.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");

const MaterialTextureSlot = enum {
    base_color,
    metallic_roughness,
    normal,
    occlusion,
    emissive,
};

pub fn drawMaterialEditorWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .material_editor, "material_editor_popup");
    var open = state.material_editor_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.material_editor_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("material_editor_popup");

    if (!open) return;

    layout.beginSectionBody();
    defer layout.endSectionBody();

    const selected = layer_context.renderer.selectedEntity() orelse {
        gui.text(state.text(.no_entity_selected));
        return;
    };

    const entity = layer_context.world.getEntity(selected) orelse {
        gui.text(state.text(.selection_is_stale));
        return;
    };

    if (entity.material == null) {
        gui.text(state.text(.entity_has_no_material));
        if (gui.buttonEx(state.text(.add_material_component), gui.contentRegionAvail()[0], 0.0)) {
            try inspector.addMaterialComponent(state, layer_context, entity);
        }
        return;
    }

    const material_component = &entity.material.?;

    gui.text(state.text(.material));
    gui.sameLine();
    var material_name: []const u8 = state.text(.embedded);
    if (material_component.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            material_name = material_resource.name;
        }
    }
    gui.text(material_name);

    gui.separator();

    var shading = material_component.shading;
    gui.text(state.text(.shading));
    gui.sameLine();
    if (gui.beginMenu(utils.shadingLabel(state, shading))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.unlit), null, shading == .unlit, true)) shading = .unlit;
        if (gui.menuItem(state.text(.lambert), null, shading == .lambert, true)) shading = .lambert;
        if (gui.menuItem(state.text(.pbr), null, shading == .pbr_metallic_roughness, true)) shading = .pbr_metallic_roughness;
    }
    if (shading != material_component.shading) {
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.shading = shading;
            material_component.shading = shading;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
        try history.captureSnapshot(state, layer_context);
    }

    gui.dummy(0.0, 8.0);

    var base_color = material_component.base_color_factor;
    var base_rgb: [3]f32 = .{ base_color[0], base_color[1], base_color[2] };
    gui.text(state.text(.base_color));
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat3("##material_base_color", &base_rgb, 0.01, 0.0, 1.0)) {
        base_color[0] = std.math.clamp(base_rgb[0], 0.0, 1.0);
        base_color[1] = std.math.clamp(base_rgb[1], 0.0, 1.0);
        base_color[2] = std.math.clamp(base_rgb[2], 0.0, 1.0);
        material_component.base_color_factor = base_color;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.base_color_factor = base_color;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var opacity = base_color[3];
    gui.text(state.text(.opacity));
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_opacity", &opacity, 0.01, 0.0, 1.0)) {
        base_color[3] = std.math.clamp(opacity, 0.0, 1.0);
        material_component.base_color_factor = base_color;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.base_color_factor = base_color;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var metallic = material_component.metallic_factor;
    gui.text("Metallic");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_metallic", &metallic, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(metallic, 0.0, 1.0);
        material_component.metallic_factor = clamped;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.metallic_factor = clamped;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var roughness = material_component.roughness_factor;
    gui.text("Roughness");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_roughness", &roughness, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(roughness, 0.0, 1.0);
        material_component.roughness_factor = clamped;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.roughness_factor = clamped;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var emissive = material_component.emissive_factor;
    gui.text("Emissive");
    gui.setNextItemWidth(-1.0);
    if (gui.colorEdit3("##material_emissive", &emissive, .{})) {
        material_component.emissive_factor = emissive;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.emissive_factor = emissive;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
        try history.captureSnapshot(state, layer_context);
    }

    gui.dummy(0.0, 8.0);

    var alpha_cutoff = material_component.alpha_cutoff;
    gui.text("Alpha Cutoff");
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##material_alpha_cutoff", &alpha_cutoff, 0.01, 0.0, 1.0)) {
        const clamped = std.math.clamp(alpha_cutoff, 0.0, 1.0);
        material_component.alpha_cutoff = clamped;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.alpha_cutoff = clamped;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (gui.isItemDeactivatedAfterEdit()) try history.captureSnapshot(state, layer_context);

    gui.dummy(0.0, 8.0);

    var double_sided = material_component.double_sided;
    if (gui.checkbox("Double Sided", &double_sided)) {
        material_component.double_sided = double_sided;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.double_sided = double_sided;
            material_component.handle = inspector.materialHandleForEntity(state, entity);
        }
        try history.captureSnapshot(state, layer_context);
    }

    gui.separator();
    gui.text("Preview");

    if (gui.buttonEx("Use Sphere Preview Mesh", -1.0, 0.0)) {
        try applyPreviewPrimitive(layer_context, entity, .sphere);
        try history.captureSnapshot(state, layer_context);
    }
    if (gui.buttonEx("Use Plane Preview Mesh", -1.0, 0.0)) {
        try applyPreviewPrimitive(layer_context, entity, .plane);
        try history.captureSnapshot(state, layer_context);
    }
    if (gui.buttonEx("Apply Checker To Base Color", -1.0, 0.0)) {
        const checker = try ensureMaterialPreviewCheckerTexture(layer_context);
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.base_color_texture = checker;
            entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
            try history.captureSnapshot(state, layer_context);
        }
    }

    gui.separator();
    gui.text("Texture Slots");

    if (try drawTextureSlot(state, layer_context, entity, .base_color)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .metallic_roughness)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .normal)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .occlusion)) try history.captureSnapshot(state, layer_context);
    if (try drawTextureSlot(state, layer_context, entity, .emissive)) try history.captureSnapshot(state, layer_context);
}

fn drawTextureSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    slot: MaterialTextureSlot,
) !bool {
    gui.text(textureSlotLabel(slot));

    var has_texture = false;
    var texture_slot_text: []const u8 = state.text(.embedded);
    if (entity.material.?.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            texture_slot_text = state.text(.none);
            if (textureHandleForSlot(material_resource, slot)) |texture_handle| {
                if (layer_context.world.assets().texture(texture_handle)) |texture_resource| {
                    texture_slot_text = texture_resource.name;
                    has_texture = true;
                }
            }
        }
    }

    var changed = false;
    if (gui.buttonEx(texture_slot_text, -1.0, 0.0)) {
        if (content_browser.selectedAssetCanUseAsTexture(state)) {
            changed = (try assignSelectedTextureToMaterialSlot(state, layer_context, entity, slot)) or changed;
        }
    }

    var dropped_texture: u64 = 0;
    if (gui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &dropped_texture)) {
        const asset_index: usize = @intCast(dropped_texture);
        if (asset_index < state.asset_entries.items.len) {
            changed = (try assignTextureEntryToMaterialSlot(state, layer_context, entity, &state.asset_entries.items[asset_index], slot)) or changed;
        }
    }

    if (has_texture) {
        gui.sameLine();
        if (gui.buttonEx(state.text(.clear_texture), 0.0, 0.0)) {
            if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
                setTextureHandleForSlot(material_resource, slot, null);
                entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
                changed = true;
            }
        }
    }

    gui.dummy(0.0, 6.0);
    return changed;
}

fn assignSelectedTextureToMaterialSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    slot: MaterialTextureSlot,
) !bool {
    const entry = content_browser.selectedAsset(state) orelse return false;
    return assignTextureEntryToMaterialSlot(state, layer_context, entity, entry, slot);
}

fn assignTextureEntryToMaterialSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    entry: *const state_mod.AssetEntry,
    slot: MaterialTextureSlot,
) !bool {
    if (entry.kind != .texture) return false;

    const texture_handle = try inspector.importTextureAsset(state, layer_context, entry.id, entry.path);
    if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
        setTextureHandleForSlot(material_resource, slot, texture_handle);
        entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
        return true;
    }
    return false;
}

fn textureHandleForSlot(material: *const engine.assets.MaterialResource, slot: MaterialTextureSlot) ?engine.assets.TextureHandle {
    return switch (slot) {
        .base_color => material.base_color_texture,
        .metallic_roughness => material.metallic_roughness_texture,
        .normal => material.normal_texture,
        .occlusion => material.occlusion_texture,
        .emissive => material.emissive_texture,
    };
}

fn setTextureHandleForSlot(material: *engine.assets.MaterialResource, slot: MaterialTextureSlot, texture: ?engine.assets.TextureHandle) void {
    switch (slot) {
        .base_color => material.base_color_texture = texture,
        .metallic_roughness => material.metallic_roughness_texture = texture,
        .normal => material.normal_texture = texture,
        .occlusion => material.occlusion_texture = texture,
        .emissive => material.emissive_texture = texture,
    }
}

fn textureSlotLabel(slot: MaterialTextureSlot) []const u8 {
    return switch (slot) {
        .base_color => "Base Color",
        .metallic_roughness => "Metallic/Roughness",
        .normal => "Normal",
        .occlusion => "Occlusion",
        .emissive => "Emissive",
    };
}

fn applyPreviewPrimitive(
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    primitive: engine.scene.Primitive,
) !void {
    const mesh_handle = try layer_context.world.assets().ensurePrimitiveMesh(primitive);
    if (entity.mesh) |*mesh_component| {
        mesh_component.primitive = primitive;
        mesh_component.handle = mesh_handle;
    } else {
        entity.mesh = .{
            .primitive = primitive,
            .handle = mesh_handle,
        };
    }
}

fn ensureMaterialPreviewCheckerTexture(layer_context: *engine.core.LayerContext) !engine.assets.TextureHandle {
    const checker_name = "__material_preview_checker__";
    for (layer_context.world.assets().textures.items, 0..) |texture, index| {
        if (std.mem.eql(u8, texture.name, checker_name)) {
            return @enumFromInt(index + 1);
        }
    }

    var pixels: [16 * 16 * 4]u8 = undefined;
    var y: usize = 0;
    while (y < 16) : (y += 1) {
        var x: usize = 0;
        while (x < 16) : (x += 1) {
            const tile = ((x / 4) + (y / 4)) % 2 == 0;
            const idx = (y * 16 + x) * 4;
            if (tile) {
                pixels[idx] = 210;
                pixels[idx + 1] = 210;
                pixels[idx + 2] = 210;
                pixels[idx + 3] = 255;
            } else {
                pixels[idx] = 56;
                pixels[idx + 1] = 56;
                pixels[idx + 2] = 56;
                pixels[idx + 3] = 255;
            }
        }
    }

    return try layer_context.world.assets().createTexture(.{
        .name = checker_name,
        .width = 16,
        .height = 16,
        .pixels = pixels[0..],
    });
}
