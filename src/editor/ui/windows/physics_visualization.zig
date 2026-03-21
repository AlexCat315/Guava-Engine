const std = @import("std");
const engine = @import("guava");
const layout = @import("../layout.zig");

pub const PhysicsVisualizationSettings = struct {
    show_collision_shapes: bool = true,
    show_rigidbodies: bool = true,
    show_triggers: bool = true,
    show_constraints: bool = false,
    show_velocity_vectors: bool = false,
    show_sleep_state: bool = false,
    show_aabbs: bool = false,
    wireframe_only: bool = true,
    opacity: f32 = 0.8,
    velocity_scale: f32 = 1.0,
    color_static: [4]f32 = .{ 0.0, 0.8, 0.0, 0.8 },
    color_dynamic: [4]f32 = .{ 0.0, 0.4, 1.0, 0.8 },
    color_kinematic: [4]f32 = .{ 1.0, 0.5, 0.0, 0.8 },
    color_trigger: [4]f32 = .{ 1.0, 1.0, 0.0, 0.5 },
    color_sleeping: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },
    color_constraint: [4]f32 = .{ 1.0, 0.0, 1.0, 0.8 },
};

pub const PhysicsDebugDrawMode = enum {
    off,
    selection_only,
    all,
};

pub fn drawPhysicsVisualizationPanel(settings: *PhysicsVisualizationSettings, mode: *PhysicsDebugDrawMode) void {
    if (engine.ui.ImGui.begin("Physics Visualization")) {
        defer engine.ui.ImGui.end();

        if (layout.beginInspectorPropertyTable("physics_viz_settings", 0.34)) {
            defer layout.endInspectorPropertyTable();

            layout.drawInspectorPropertyRow("Draw Mode", null);
            if (engine.ui.ImGui.beginCombo("##draw_mode", modeName(mode.*), .{})) {
                defer engine.ui.ImGui.endCombo();
                const modes = [_]PhysicsDebugDrawMode{ .off, .selection_only, .all };
                for (modes) |m| {
                    const is_selected = mode.* == m;
                    if (engine.ui.ImGui.selectable(modeName(m), is_selected)) {
                        mode.* = m;
                    }
                    if (is_selected) {
                        engine.ui.ImGui.setItemDefaultFocus();
                    }
                }
            }

            if (mode.* != .off) {
                layout.drawInspectorPropertyRow("Opacity", null);
                _ = engine.ui.ImGui.dragFloat("##opacity", &settings.opacity, 0.01, 0.1, 1.0);

                layout.drawInspectorPropertyRow("Wireframe", null);
                _ = engine.ui.ImGui.checkbox("##wireframe", &settings.wireframe_only);

                engine.ui.ImGui.separator();
                engine.ui.ImGui.text("Show:");
                engine.ui.ImGui.separator();

                layout.drawInspectorPropertyRow("Collision Shapes", null);
                _ = engine.ui.ImGui.checkbox("##show_collision", &settings.show_collision_shapes);

                layout.drawInspectorPropertyRow("Rigidbodies", null);
                _ = engine.ui.ImGui.checkbox("##show_rigidbodies", &settings.show_rigidbodies);

                layout.drawInspectorPropertyRow("Triggers", null);
                _ = engine.ui.ImGui.checkbox("##show_triggers", &settings.show_triggers);

                layout.drawInspectorPropertyRow("Constraints", null);
                _ = engine.ui.ImGui.checkbox("##show_constraints", &settings.show_constraints);

                layout.drawInspectorPropertyRow("Velocity Vectors", null);
                _ = engine.ui.ImGui.checkbox("##show_velocity", &settings.show_velocity_vectors);

                if (settings.show_velocity_vectors) {
                    layout.drawInspectorPropertyRow("Velocity Scale", null);
                    _ = engine.ui.ImGui.dragFloat("##velocity_scale", &settings.velocity_scale, 0.1, 0.1, 10.0);
                }

                layout.drawInspectorPropertyRow("Sleep State", null);
                _ = engine.ui.ImGui.checkbox("##show_sleep", &settings.show_sleep_state);

                layout.drawInspectorPropertyRow("AABBs", null);
                _ = engine.ui.ImGui.checkbox("##show_aabbs", &settings.show_aabbs);

                engine.ui.ImGui.separator();
                engine.ui.ImGui.text("Colors:");
                engine.ui.ImGui.separator();

                layout.drawInspectorPropertyRow("Static", null);
                _ = engine.ui.ImGui.colorEdit4("##color_static", &settings.color_static, .{});

                layout.drawInspectorPropertyRow("Dynamic", null);
                _ = engine.ui.ImGui.colorEdit4("##color_dynamic", &settings.color_dynamic, .{});

                layout.drawInspectorPropertyRow("Kinematic", null);
                _ = engine.ui.ImGui.colorEdit4("##color_kinematic", &settings.color_kinematic, .{});

                layout.drawInspectorPropertyRow("Trigger", null);
                _ = engine.ui.ImGui.colorEdit4("##color_trigger", &settings.color_trigger, .{});

                layout.drawInspectorPropertyRow("Sleeping", null);
                _ = engine.ui.ImGui.colorEdit4("##color_sleeping", &settings.color_sleeping, .{});

                layout.drawInspectorPropertyRow("Constraint", null);
                _ = engine.ui.ImGui.colorEdit4("##color_constraint", &settings.color_constraint, .{});
            }
        }
    }
}

fn modeName(mode: PhysicsDebugDrawMode) []const u8 {
    return switch (mode) {
        .off => "Off",
        .selection_only => "Selection Only",
        .all => "All",
    };
}
