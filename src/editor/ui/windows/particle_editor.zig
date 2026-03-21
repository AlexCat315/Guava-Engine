const std = @import("std");
const engine = @import("guava");
const layout = @import("../layout.zig");

const Vfx = engine.scene.Vfx;
const VfxKind = engine.scene.VfxKind;

pub const ParticleEditorState = struct {
    selected_vfx_entity: ?engine.scene.EntityId = null,
    preview_vfx: ?Vfx = null,
    is_previewing: bool = false,
    preset_name_buffer: [64]u8 = [_]u8{0} ** 64,
    show_emission_curve: bool = false,
    show_color_gradient: bool = false,
    show_size_curve: bool = false,
    curve_preview_t: f32 = 0.0,
    emission_curve_start: f32 = 1.0,
    emission_curve_mid: f32 = 1.0,
    emission_curve_end: f32 = 1.0,
    size_curve_start: f32 = 1.0,
    size_curve_mid: f32 = 1.0,
    size_curve_end: f32 = 1.0,
    color_gradient_start: [3]f32 = .{ 1.0, 1.0, 1.0 },
    color_gradient_end: [3]f32 = .{ 1.0, 1.0, 1.0 },
    simulation_speed: f32 = 1.0,
    auto_reset: bool = true,
    reset_timer: f32 = 0.0,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }
};

pub fn drawParticleEditor(
    state: *engine.AppState,
    layer_context: *engine.LayerContext,
    editor_state: *ParticleEditorState,
) void {
    _ = layer_context;

    if (engine.ui.ImGui.begin("Particle Editor")) {
        defer engine.ui.ImGui.end();

        drawParticleToolbar(state, editor_state);

        engine.ui.ImGui.separator();

        if (editor_state.preview_vfx) |*vfx| {
            drawParticlePreview(editor_state);
            engine.ui.ImGui.separator();
            drawParticleParameters(vfx);
            engine.ui.ImGui.separator();
            drawParticleCurves(vfx, editor_state);
        } else {
            engine.ui.ImGui.text("Select a VFX entity or create a new particle system");
            if (engine.ui.ImGui.button("Create Particle System")) {
                editor_state.preview_vfx = engine.scene.defaultVfx(.fountain);
            }
        }
    }
}

fn drawParticleToolbar(state: *engine.AppState, editor_state: *ParticleEditorState) void {
    _ = state;

    if (engine.ui.ImGui.button("New")) {
        editor_state.preview_vfx = engine.scene.defaultVfx(.fountain);
    }
    engine.ui.ImGui.sameLine();

    if (editor_state.preview_vfx != null) {
        if (engine.ui.ImGui.button("Reset")) {
            editor_state.reset_timer = 0.0;
        }
        engine.ui.ImGui.sameLine();

        if (engine.ui.ImGui.button(if (editor_state.is_previewing) "Pause" else "Play")) {
            editor_state.is_previewing = !editor_state.is_previewing;
        }
        engine.ui.ImGui.sameLine();

        engine.ui.ImGui.text("Speed:");
        engine.ui.ImGui.sameLine();
        _ = engine.ui.ImGui.dragFloat("##sim_speed", &editor_state.simulation_speed, 0.1, 0.1, 5.0);
    }

    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.text("Preset:");
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.beginCombo("##preset", "Select...", .{})) {
        defer engine.ui.ImGui.endCombo();

        const presets = [_]struct { name: []const u8, kind: VfxKind }{
            .{ .name = "Fountain", .kind = .fountain },
            .{ .name = "Orbit", .kind = .orbit },
        };

        for (presets) |preset| {
            if (engine.ui.ImGui.selectable(preset.name, false)) {
                editor_state.preview_vfx = engine.scene.defaultVfx(preset.kind);
            }
        }
    }
}

fn drawParticlePreview(editor_state: *ParticleEditorState) void {
    const preview_size = engine.ui.ImGui.contentRegionAvail();
    const preview_height = @min(preview_size[1] * 0.4, 200);

    if (engine.ui.ImGui.beginChild("particle_preview", -1.0, preview_height, true)) {
        engine.ui.ImGui.text("Particle Preview");
        engine.ui.ImGui.separator();

        if (editor_state.is_previewing) {
            editor_state.reset_timer += 0.016 * editor_state.simulation_speed;
            if (editor_state.reset_timer > 5.0 and editor_state.auto_reset) {
                editor_state.reset_timer = 0.0;
            }
        }

        if (editor_state.preview_vfx) |vfx| {
            var info_buf: [256]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "Particles: {} | Rate: {d:.1}/s | Lifetime: {d:.2}s", .{
                vfx.max_particles,
                vfx.emission_rate,
                vfx.particle_lifetime,
            }) catch "";
            engine.ui.ImGui.text(info);
        }
    }
    engine.ui.ImGui.endChild();
}

fn drawParticleParameters(vfx: *Vfx) void {
    if (layout.beginInspectorPropertyTable("particle_params", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("Kind", null);
        if (engine.ui.ImGui.beginCombo("##kind", @tagName(vfx.kind), .{})) {
            defer engine.ui.ImGui.endCombo();
            inline for (.{
                .fountain,
                .orbit,
            }) |kind| {
                const is_selected = vfx.kind == kind;
                if (engine.ui.ImGui.selectable(@tagName(kind), is_selected)) {
                    vfx.* = engine.scene.defaultVfx(kind);
                }
                if (is_selected) {
                    engine.ui.ImGui.setItemDefaultFocus();
                }
            }
        }

        layout.drawInspectorPropertyRow("Looping", null);
        _ = engine.ui.ImGui.checkbox("##looping", &vfx.looping);

        layout.drawInspectorPropertyRow("Emission Rate", null);
        _ = engine.ui.ImGui.dragFloat("##emission_rate", &vfx.emission_rate, 1.0, 1.0, 200.0);

        layout.drawInspectorPropertyRow("Particle Lifetime", null);
        _ = engine.ui.ImGui.dragFloat("##lifetime", &vfx.particle_lifetime, 0.1, 0.1, 10.0);

        layout.drawInspectorPropertyRow("Speed", null);
        _ = engine.ui.ImGui.dragFloat("##speed", &vfx.speed, 0.1, 0.1, 20.0);

        layout.drawInspectorPropertyRow("Max Particles", null);
        _ = engine.ui.ImGui.dragInt("##max_particles", &@as(*i32, @ptrCast(&vfx.max_particles)), 1.0, 1, 1000);

        layout.drawInspectorPropertyRow("Radius", null);
        _ = engine.ui.ImGui.dragFloat("##radius", &vfx.radius, 0.05, 0.0, 5.0);

        layout.drawInspectorPropertyRow("Spread", null);
        _ = engine.ui.ImGui.dragFloat("##spread", &vfx.spread, 0.05, 0.0, 3.14159);

        layout.drawInspectorPropertyRow("Size", null);
        _ = engine.ui.ImGui.dragFloat("##size", &vfx.size, 0.01, 0.01, 2.0);

        layout.drawInspectorPropertyRow("Color", null);
        _ = engine.ui.ImGui.colorEdit3("##color", &vfx.color, .{});
    }
}

fn drawParticleCurves(vfx: *Vfx, editor_state: *ParticleEditorState) void {
    engine.ui.ImGui.text("Advanced Curves");
    engine.ui.ImGui.separator();

    _ = engine.ui.ImGui.dragFloat("Preview Lifetime T", &editor_state.curve_preview_t, 0.01, 0.0, 1.0);

    if (engine.ui.ImGui.collapsingHeader("Emission Curve", false)) {
        editor_state.show_emission_curve = true;
        _ = engine.ui.ImGui.dragFloat("Start##emission", &editor_state.emission_curve_start, 0.01, 0.0, 5.0);
        _ = engine.ui.ImGui.dragFloat("Mid##emission", &editor_state.emission_curve_mid, 0.01, 0.0, 5.0);
        _ = engine.ui.ImGui.dragFloat("End##emission", &editor_state.emission_curve_end, 0.01, 0.0, 5.0);

        const t = editor_state.curve_preview_t;
        const sampled_multiplier = if (t < 0.5)
            std.math.lerp(editor_state.emission_curve_start, editor_state.emission_curve_mid, t * 2.0)
        else
            std.math.lerp(editor_state.emission_curve_mid, editor_state.emission_curve_end, (t - 0.5) * 2.0);
        var info_buf: [128]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "Sampled Rate: {d:.2}/s", .{vfx.emission_rate * sampled_multiplier}) catch "";
        engine.ui.ImGui.text(info);
    }

    if (engine.ui.ImGui.collapsingHeader("Color Gradient", false)) {
        editor_state.show_color_gradient = true;
        _ = engine.ui.ImGui.colorEdit3("Start Color", &editor_state.color_gradient_start, .{});
        _ = engine.ui.ImGui.colorEdit3("End Color", &editor_state.color_gradient_end, .{});

        const t = editor_state.curve_preview_t;
        var sampled = [3]f32{
            std.math.lerp(editor_state.color_gradient_start[0], editor_state.color_gradient_end[0], t),
            std.math.lerp(editor_state.color_gradient_start[1], editor_state.color_gradient_end[1], t),
            std.math.lerp(editor_state.color_gradient_start[2], editor_state.color_gradient_end[2], t),
        };
        _ = engine.ui.ImGui.colorEdit3("Sampled##color_preview", &sampled, .{});
        if (engine.ui.ImGui.button("Apply Sampled To Base Color")) {
            vfx.color = sampled;
        }
    }

    if (engine.ui.ImGui.collapsingHeader("Size Curve", false)) {
        editor_state.show_size_curve = true;
        _ = engine.ui.ImGui.dragFloat("Start##size", &editor_state.size_curve_start, 0.01, 0.01, 5.0);
        _ = engine.ui.ImGui.dragFloat("Mid##size", &editor_state.size_curve_mid, 0.01, 0.01, 5.0);
        _ = engine.ui.ImGui.dragFloat("End##size", &editor_state.size_curve_end, 0.01, 0.01, 5.0);

        const t = editor_state.curve_preview_t;
        const sampled_multiplier = if (t < 0.5)
            std.math.lerp(editor_state.size_curve_start, editor_state.size_curve_mid, t * 2.0)
        else
            std.math.lerp(editor_state.size_curve_mid, editor_state.size_curve_end, (t - 0.5) * 2.0);
        var size_buf: [128]u8 = undefined;
        const sampled_size = @max(vfx.size * sampled_multiplier, 0.01);
        const size_text = std.fmt.bufPrint(&size_buf, "Sampled Size: {d:.3}", .{sampled_size}) catch "";
        engine.ui.ImGui.text(size_text);
        if (engine.ui.ImGui.button("Apply Sampled To Base Size")) {
            vfx.size = sampled_size;
        }
    }
}
