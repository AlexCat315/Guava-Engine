const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");
const inspector = @import("inspector.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");

pub fn drawMaterialEditorWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .material_editor, "material_editor_popup");
    var open = state.material_editor_open;
    _ = engine.ui.ImGui.beginWindowFlagsOpen(title, &open, engine.ui.ImGui.WindowFlags.no_docking);
    state.material_editor_open = open;
    defer engine.ui.ImGui.endWindow();

    if (!open) {
        return;
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    // Get selected entity with material
    const selected = layer_context.renderer.selectedEntity() orelse {
        engine.ui.ImGui.text(state.text(.no_entity_selected));
        return;
    };

    const entity = layer_context.world.getEntity(selected) orelse {
        engine.ui.ImGui.text(state.text(.selection_is_stale));
        return;
    };

    if (entity.material == null) {
        engine.ui.ImGui.text(state.text(.entity_has_no_material));
        if (engine.ui.ImGui.buttonEx(state.text(.add_material_component), engine.ui.ImGui.contentRegionAvail()[0], 0.0)) {
            try inspector.addMaterialComponent(state, layer_context, entity);
        }
        return;
    }

    // Get material info - use pointer for mutability
    var effective_shading = entity.material.?.shading;
    var effective_color = entity.material.?.base_color_factor;

    // Material name
    engine.ui.ImGui.text(state.text(.material));
    engine.ui.ImGui.sameLine();
    var material_name_buffer: [64]u8 = undefined;
    if (entity.material.?.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            _ = std.fmt.bufPrint(&material_name_buffer, "{s}", .{material_resource.name}) catch {};
        }
    }
    engine.ui.ImGui.text(material_name_buffer[0..]);

    engine.ui.ImGui.separator();

    // Shading mode
    engine.ui.ImGui.text(state.text(.shading));
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.beginMenu(utils.shadingLabel(state, effective_shading))) {
        defer engine.ui.ImGui.endMenu();
        if (engine.ui.ImGui.menuItem(state.text(.unlit), null, effective_shading == .unlit, true)) {
            effective_shading = .unlit;
        }
        if (engine.ui.ImGui.menuItem(state.text(.lambert), null, effective_shading == .lambert, true)) {
            effective_shading = .lambert;
        }
        if (engine.ui.ImGui.menuItem(state.text(.pbr), null, effective_shading == .pbr_metallic_roughness, true)) {
            effective_shading = .pbr_metallic_roughness;
        }
    }

    if (effective_shading != entity.material.?.shading) {
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.shading = effective_shading;
            entity.material.?.shading = effective_shading;
            entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
        }
        try history.captureSnapshot(state, layer_context);
    }

    engine.ui.ImGui.dummy(0.0, 8.0);

    // Base color (R/G/B)
    var base_color: [3]f32 = .{ effective_color[0], effective_color[1], effective_color[2] };
    engine.ui.ImGui.text(state.text(.base_color));
    engine.ui.ImGui.setNextItemWidth(-1.0);
    if (engine.ui.ImGui.dragFloat3("##material_base_color", &base_color, 0.01, 0.0, 1.0)) {
        effective_color[0] = std.math.clamp(base_color[0], 0.0, 1.0);
        effective_color[1] = std.math.clamp(base_color[1], 0.0, 1.0);
        effective_color[2] = std.math.clamp(base_color[2], 0.0, 1.0);
        entity.material.?.base_color_factor = effective_color;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.base_color_factor = effective_color;
            entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
        try history.captureSnapshot(state, layer_context);
    }

    engine.ui.ImGui.dummy(0.0, 8.0);

    // Opacity
    var alpha = effective_color[3];
    engine.ui.ImGui.text(state.text(.opacity));
    engine.ui.ImGui.setNextItemWidth(-1.0);
    if (engine.ui.ImGui.dragFloat("##material_opacity", &alpha, 0.01, 0.0, 1.0)) {
        effective_color[3] = std.math.clamp(alpha, 0.0, 1.0);
        entity.material.?.base_color_factor = effective_color;
        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
            material_resource.base_color_factor = effective_color;
            entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
        }
    }
    if (engine.ui.ImGui.isItemDeactivatedAfterEdit()) {
        try history.captureSnapshot(state, layer_context);
    }

    engine.ui.ImGui.dummy(0.0, 8.0);

    // Texture slot
    engine.ui.ImGui.text(state.text(.texture));
    if (entity.material.?.handle) |material_handle| {
        if (layer_context.world.assets().material(material_handle)) |material_resource| {
            if (material_resource.base_color_texture) |texture_handle| {
                if (layer_context.world.assets().texture(texture_handle)) |texture_resource| {
                    engine.ui.ImGui.text(texture_resource.name);
                    engine.ui.ImGui.sameLine();
                    if (engine.ui.ImGui.buttonEx(state.text(.clear_texture), 0.0, 0.0)) {
                        if (try inspector.ensureEditableMaterialResource(state, layer_context, entity)) |mat_res| {
                            mat_res.base_color_texture = null;
                            entity.material.?.handle = inspector.materialHandleForEntity(state, entity);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                }
            } else {
                engine.ui.ImGui.text(state.text(.none));
            }
        }
    } else {
        engine.ui.ImGui.text(state.text(.embedded));
    }
}
