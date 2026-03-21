const std = @import("std");
const engine = @import("guava");
const layout = @import("../layout.zig");

const EditorViewportState = engine.render.EditorViewportState;

pub const PostProcessEffect = enum {
    bloom,
    fxaa,
    ssao,
    ssr,
    taa,
    dof,
    color_grading,
};

pub const PostProcessEffectNode = struct {
    effect: PostProcessEffect,
    enabled: bool = true,
    position: [2]f32 = .{ 0, 0 },
    input_connections: std.ArrayList(usize),
    output_connections: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, effect: PostProcessEffect) PostProcessEffectNode {
        return .{
            .effect = effect,
            .input_connections = std.ArrayList(usize).init(allocator),
            .output_connections = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *PostProcessEffectNode) void {
        self.input_connections.deinit();
        self.output_connections.deinit();
        self.* = undefined;
    }

    pub fn getName(self: *const PostProcessEffectNode) []const u8 {
        return switch (self.effect) {
            .bloom => "Bloom",
            .fxaa => "FXAA",
            .ssao => "SSAO",
            .ssr => "SSR",
            .taa => "TAA",
            .dof => "DOF",
            .color_grading => "Color Grading",
        };
    }

    pub fn getColor(self: *const PostProcessEffectNode) [4]f32 {
        return switch (self.effect) {
            .bloom => .{ 1.0, 0.8, 0.2, 1.0 },
            .fxaa => .{ 0.2, 0.8, 1.0, 1.0 },
            .ssao => .{ 0.8, 0.4, 0.8, 1.0 },
            .ssr => .{ 0.4, 0.8, 0.8, 1.0 },
            .taa => .{ 0.6, 0.6, 1.0, 1.0 },
            .dof => .{ 0.8, 0.6, 0.4, 1.0 },
            .color_grading => .{ 1.0, 0.6, 0.8, 1.0 },
        };
    }
};

pub const PostProcessPipelineEditorState = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(PostProcessEffectNode),
    selected_node_index: ?usize = null,
    view_pan: [2]f32 = .{ 0, 0 },
    view_zoom: f32 = 1.0,
    dragging_node: ?usize = null,
    connecting_from: ?usize = null,
    show_preview: bool = true,
    preview_split: f32 = 0.5,

    pub fn init(allocator: std.mem.Allocator) PostProcessPipelineEditorState {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(PostProcessEffectNode).init(allocator),
        };
    }

    pub fn deinit(self: *PostProcessPipelineEditorState) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit();
        self.* = undefined;
    }

    pub fn addNode(self: *PostProcessPipelineEditorState, effect: PostProcessEffect, x: f32, y: f32) !usize {
        var node = PostProcessEffectNode.init(self.allocator, effect);
        node.position = .{ x, y };
        try self.nodes.append(node);
        return self.nodes.items.len - 1;
    }

    pub fn removeNode(self: *PostProcessPipelineEditorState, index: usize) bool {
        if (index >= self.nodes.items.len) return false;
        var node = self.nodes.orderedRemove(index);
        node.deinit();
        if (self.selected_node_index) |*si| {
            if (si.* == index) {
                si.* = null;
            } else if (si.* > index) {
                si.* -= 1;
            }
        }
        return true;
    }

    pub fn connect(self: *PostProcessPipelineEditorState, from_index: usize, to_index: usize) !void {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) return;
        if (from_index == to_index) return;

        try self.nodes.items[from_index].output_connections.append(to_index);
        try self.nodes.items[to_index].input_connections.append(from_index);
    }

    pub fn getSelectedNode(self: *PostProcessPipelineEditorState) ?*PostProcessEffectNode {
        if (self.selected_node_index) |index| {
            if (index < self.nodes.items.len) {
                return &self.nodes.items[index];
            }
        }
        return null;
    }
};

pub fn drawPostProcessPipelineEditor(
    state: *engine.AppState,
    layer_context: *engine.LayerContext,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
) void {
    _ = layer_context;

    if (engine.ui.ImGui.begin("Post Process Pipeline")) {
        defer engine.ui.ImGui.end();

        drawPipelineToolbar(state, editor_state);

        engine.ui.ImGui.separator();

        const content_region = engine.ui.ImGui.contentRegionAvail();
        const graph_width = if (editor_state.show_preview) content_region[0] * editor_state.preview_split else content_region[0];

        if (engine.ui.ImGui.beginChild("pipeline_graph", graph_width, -1.0, true)) {
            drawPipelineGraph(editor_state);
        }
        engine.ui.ImGui.endChild();

        if (editor_state.show_preview) {
            engine.ui.ImGui.sameLine();
            if (engine.ui.ImGui.beginChild("pipeline_preview", -1.0, -1.0, true)) {
                drawPreviewPanel(viewport_state);
            }
            engine.ui.ImGui.endChild();
        }

        if (editor_state.getSelectedNode()) |node| {
            engine.ui.ImGui.separator();
            drawEffectParameters(viewport_state, node);
        }
    }
}

fn drawPipelineToolbar(state: *engine.AppState, editor_state: *PostProcessPipelineEditorState) void {
    _ = state;

    if (engine.ui.ImGui.button("Add Effect")) {
        engine.ui.ImGui.openPopup("add_effect_popup");
    }

    if (engine.ui.ImGui.beginPopup("add_effect_popup")) {
        defer engine.ui.ImGui.endPopup();

        const effects = [_]PostProcessEffect{
            .bloom,
            .fxaa,
            .ssao,
            .ssr,
            .taa,
            .dof,
            .color_grading,
        };

        for (effects) |effect| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}", .{@tagName(effect)}) catch continue;
            if (engine.ui.ImGui.selectable(name, false)) {
                const x = @as(f32, @floatFromInt(editor_state.nodes.items.len)) * 200.0;
                _ = editor_state.addNode(effect, x, 100.0) catch {};
            }
        }
    }

    engine.ui.ImGui.sameLine();

    if (engine.ui.ImGui.button("Clear All")) {
        for (editor_state.nodes.items) |*node| {
            node.deinit();
        }
        editor_state.nodes.clearRetainingCapacity();
        editor_state.selected_node_index = null;
    }

    engine.ui.ImGui.sameLine();

    engine.ui.ImGui.text("Preview:");
    engine.ui.ImGui.sameLine();
    _ = engine.ui.ImGui.checkbox("##show_preview", &editor_state.show_preview);

    engine.ui.ImGui.sameLine();

    engine.ui.ImGui.text("Nodes:");
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.text("{}", .{editor_state.nodes.items.len});
}

fn drawPipelineGraph(editor_state: *PostProcessPipelineEditorState) void {
    const canvas_pos = engine.ui.ImGui.cursorScreenPos();
    const canvas_size = engine.ui.ImGui.contentRegionAvail();

    engine.ui.ImGui.invisibleButton("canvas", canvas_size[0], canvas_size[1], .{
        .mouse_button_left = true,
        .mouse_button_right = true,
    });

    for (editor_state.nodes.items, 0..) |*node, index| {
        const is_selected = editor_state.selected_node_index != null and editor_state.selected_node_index.? == index;

        const node_pos = [2]f32{
            canvas_pos[0] + node.position[0] + editor_state.view_pan[0],
            canvas_pos[1] + node.position[1] + editor_state.view_pan[1],
        };

        engine.ui.ImGui.setCursorScreenPos(node_pos);

        const node_width: f32 = 120.0;
        const node_height: f32 = 60.0;

        const color = node.getColor();
        engine.ui.ImGui.pushStyleColor(.child_bg, if (is_selected) .{ color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, 1.0 } else color);
        defer engine.ui.ImGui.popStyleColor(1);

        var name_buf: [64]u8 = undefined;
        const node_name = std.fmt.bufPrint(&name_buf, "{s}##node_{}", .{ node.getName(), index }) catch continue;

        if (engine.ui.ImGui.beginChild(node_name, node_width, node_height, true)) {
            engine.ui.ImGui.text(node.getName());

            engine.ui.ImGui.text("Enabled:");
            engine.ui.ImGui.sameLine();
            _ = engine.ui.ImGui.checkbox("##enabled", &node.enabled);
        }
        engine.ui.ImGui.endChild();

        if (engine.ui.ImGui.isItemClicked()) {
            editor_state.selected_node_index = index;
        }

        if (engine.ui.ImGui.isItemActive() and engine.ui.ImGui.isMouseDragging(.left)) {
            const drag_delta = engine.ui.ImGui.mouseDragDelta(.left);
            node.position[0] += drag_delta[0];
            node.position[1] += drag_delta[1];
            engine.ui.ImGui.resetMouseDragDelta(.left);
        }
    }
}

fn drawPreviewPanel(viewport_state: *EditorViewportState) void {
    engine.ui.ImGui.text("Preview");
    engine.ui.ImGui.separator();

    if (layout.beginInspectorPropertyTable("preview_settings", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("Bloom", null);
        _ = engine.ui.ImGui.checkbox("##bloom_enabled", &viewport_state.bloom_enabled);

        layout.drawInspectorPropertyRow("FXAA", null);
        _ = engine.ui.ImGui.checkbox("##fxaa_enabled", &viewport_state.fxaa_enabled);

        layout.drawInspectorPropertyRow("SSAO", null);
        _ = engine.ui.ImGui.checkbox("##ssao_enabled", &viewport_state.ssao_enabled);

        layout.drawInspectorPropertyRow("SSR", null);
        _ = engine.ui.ImGui.checkbox("##ssr_enabled", &viewport_state.ssr_enabled);

        layout.drawInspectorPropertyRow("TAA", null);
        _ = engine.ui.ImGui.checkbox("##taa_enabled", &viewport_state.taa_enabled);

        layout.drawInspectorPropertyRow("DOF", null);
        _ = engine.ui.ImGui.checkbox("##dof_enabled", &viewport_state.dof_enabled);
    }
}

fn drawEffectParameters(viewport_state: *EditorViewportState, node: *PostProcessEffectNode) void {
    engine.ui.ImGui.text("Effect Parameters");
    engine.ui.ImGui.separator();

    if (!node.enabled) {
        engine.ui.ImGui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Effect disabled");
        return;
    }

    if (layout.beginInspectorPropertyTable("effect_params", 0.34)) {
        defer layout.endInspectorPropertyTable();

        switch (node.effect) {
            .bloom => {
                layout.drawInspectorPropertyRow("Threshold", null);
                _ = engine.ui.ImGui.dragFloat("##bloom_threshold", &viewport_state.bloom_threshold, 0.1, 0.0, 10.0);
                layout.drawInspectorPropertyRow("Intensity", null);
                _ = engine.ui.ImGui.dragFloat("##bloom_intensity", &viewport_state.bloom_intensity, 0.1, 0.0, 5.0);
                layout.drawInspectorPropertyRow("Radius", null);
                _ = engine.ui.ImGui.dragFloat("##bloom_radius", &viewport_state.bloom_radius, 0.1, 0.0, 10.0);
            },
            .ssao => {
                layout.drawInspectorPropertyRow("Radius", null);
                _ = engine.ui.ImGui.dragFloat("##ssao_radius", &viewport_state.ssao_radius, 0.1, 0.0, 5.0);
                layout.drawInspectorPropertyRow("Bias", null);
                _ = engine.ui.ImGui.dragFloat("##ssao_bias", &viewport_state.ssao_bias, 0.01, 0.0, 1.0);
                layout.drawInspectorPropertyRow("Intensity", null);
                _ = engine.ui.ImGui.dragFloat("##ssao_intensity", &viewport_state.ssao_intensity, 0.1, 0.0, 5.0);
                layout.drawInspectorPropertyRow("Power", null);
                _ = engine.ui.ImGui.dragFloat("##ssao_power", &viewport_state.ssao_power, 0.1, 0.0, 10.0);
            },
            .ssr => {
                layout.drawInspectorPropertyRow("Intensity", null);
                _ = engine.ui.ImGui.dragFloat("##ssr_intensity", &viewport_state.ssr_intensity, 0.1, 0.0, 2.0);
                layout.drawInspectorPropertyRow("Ray Step", null);
                _ = engine.ui.ImGui.dragFloat("##ssr_ray_step", &viewport_state.ssr_ray_step, 0.01, 0.01, 1.0);
                layout.drawInspectorPropertyRow("Max Distance", null);
                _ = engine.ui.ImGui.dragFloat("##ssr_ray_max_distance", &viewport_state.ssr_ray_max_distance, 1.0, 10.0, 500.0);
            },
            .taa => {
                layout.drawInspectorPropertyRow("Blend Factor", null);
                _ = engine.ui.ImGui.dragFloat("##taa_blend_factor", &viewport_state.taa_blend_factor, 0.01, 0.0, 1.0);
                layout.drawInspectorPropertyRow("Feedback Min", null);
                _ = engine.ui.ImGui.dragFloat("##taa_feedback_min", &viewport_state.taa_feedback_min, 0.01, 0.0, 1.0);
                layout.drawInspectorPropertyRow("Feedback Max", null);
                _ = engine.ui.ImGui.dragFloat("##taa_feedback_max", &viewport_state.taa_feedback_max, 0.01, 0.0, 1.0);
            },
            .dof => {
                layout.drawInspectorPropertyRow("Focus Distance", null);
                _ = engine.ui.ImGui.dragFloat("##dof_focus_distance", &viewport_state.dof_focus_distance, 1.0, 0.0, 100.0);
                layout.drawInspectorPropertyRow("Focus Range", null);
                _ = engine.ui.ImGui.dragFloat("##dof_focus_range", &viewport_state.dof_focus_range, 0.5, 0.0, 50.0);
                layout.drawInspectorPropertyRow("Blur Radius", null);
                _ = engine.ui.ImGui.dragFloat("##dof_blur_radius", &viewport_state.dof_blur_radius, 1.0, 0.0, 50.0);
            },
            .fxaa, .color_grading => {
                engine.ui.ImGui.text("No additional parameters");
            },
        }
    }
}
