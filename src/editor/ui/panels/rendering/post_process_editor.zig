const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const layout = @import("../../layout.zig");
const props = @import("../../properties.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const EditorViewportState = engine.render.EditorViewportState;

pub const PostProcessEffect = enum {
    bloom,
    fxaa,
    ssao,
    ssr,
    taa,
    dof,
    color_grading,
    contact_shadows,
    tonemap,
};

pub const PostProcessEffectNode = struct {
    effect: PostProcessEffect,
    enabled: bool = true,
    position: [2]f32 = .{ 0, 0 },
    input_connections: std.ArrayList(usize),
    output_connections: std.ArrayList(usize),

    pub fn init(effect: PostProcessEffect) PostProcessEffectNode {
        return .{
            .effect = effect,
            .input_connections = .empty,
            .output_connections = .empty,
        };
    }

    pub fn deinit(self: *PostProcessEffectNode, allocator: std.mem.Allocator) void {
        self.input_connections.deinit(allocator);
        self.output_connections.deinit(allocator);
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
            .contact_shadows => "Contact Shadows",
            .tonemap => "Tonemap",
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
            .contact_shadows => .{ 0.5, 0.5, 0.5, 1.0 },
            .tonemap => .{ 1.0, 0.9, 0.5, 1.0 },
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
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *PostProcessPipelineEditorState) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addNode(self: *PostProcessPipelineEditorState, effect: PostProcessEffect, x: f32, y: f32) !usize {
        var node = PostProcessEffectNode.init(effect);
        node.position = .{ x, y };
        try self.nodes.append(self.allocator, node);
        return self.nodes.items.len - 1;
    }

    pub fn removeNode(self: *PostProcessPipelineEditorState, index: usize) bool {
        if (index >= self.nodes.items.len) return false;
        var node = self.nodes.orderedRemove(index);
        node.deinit(self.allocator);
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

        try self.nodes.items[from_index].output_connections.append(self.allocator, to_index);
        try self.nodes.items[to_index].input_connections.append(self.allocator, from_index);
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

pub fn drawPostProcessPipelineEditorWindow(
    editor_state_: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
) !void {
    _ = layer_context;

    var title_buffer: [80]u8 = undefined;
    const title = try editor_state_.windowLabel(&title_buffer, .post_process_pipeline, "post_process_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    drawPipelineToolbar(editor_state);

    gui.separator();

    const content_region = gui.contentRegionAvail();
    const graph_width = if (editor_state.show_preview) content_region[0] * editor_state.preview_split else content_region[0];

    if (gui.beginChild("pipeline_graph", graph_width, -1.0, true)) {
        drawPipelineGraph(editor_state);
    }
    gui.endChild();

    if (editor_state.show_preview) {
        gui.sameLine();
        if (gui.beginChild("pipeline_preview", -1.0, -1.0, true)) {
            drawPreviewPanel(viewport_state);
        }
        gui.endChild();
    }

    if (editor_state.getSelectedNode()) |node| {
        gui.separator();
        drawEffectParameters(viewport_state, node);
    }
}

fn drawPipelineToolbar(editor_state: *PostProcessPipelineEditorState) void {
    if (gui.button("Add Effect")) {
        gui.openPopup("add_effect_popup");
    }

    if (gui.beginPopup("add_effect_popup")) {
        defer gui.endPopup();

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
            if (gui.selectable(name, false, false, 0, 0)) {
                const x = @as(f32, @floatFromInt(editor_state.nodes.items.len)) * 200.0;
                _ = editor_state.addNode(effect, x, 100.0) catch {};
            }
        }
    }

    gui.sameLine();

    if (gui.button("Clear All")) {
        for (editor_state.nodes.items) |*node| {
            node.deinit(editor_state.allocator);
        }
        editor_state.nodes.clearRetainingCapacity();
        editor_state.selected_node_index = null;
    }

    gui.sameLine();

    gui.text("Preview:");
    gui.sameLine();
    _ = gui.checkbox("##show_preview", &editor_state.show_preview);

    gui.sameLine();

    gui.text("Nodes:");
    gui.sameLine();
    var count_buf: [16]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{}", .{editor_state.nodes.items.len}) catch "?";
    gui.text(count_text);
}

fn drawPipelineGraph(editor_state: *PostProcessPipelineEditorState) void {
    const canvas_pos = gui.cursorScreenPos();
    const canvas_size = gui.contentRegionAvail();

    _ = gui.invisibleButton("canvas", canvas_size[0], canvas_size[1]);

    for (editor_state.nodes.items, 0..) |*node, index| {
        const is_selected = editor_state.selected_node_index != null and editor_state.selected_node_index.? == index;

        const node_pos = [2]f32{
            canvas_pos[0] + node.position[0] + editor_state.view_pan[0],
            canvas_pos[1] + node.position[1] + editor_state.view_pan[1],
        };

        gui.setCursorScreenPos(node_pos);

        const node_width: f32 = 120.0;
        const node_height: f32 = 60.0;

        const color = node.getColor();
        const node_bg: [4]f32 = if (is_selected)
            .{ color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, 1.0 }
        else
            color;
        gui.pushStyleColor(.button, node_bg);
        gui.pushStyleColor(.button_hovered, .{ @min(node_bg[0] + 0.08, 1.0), @min(node_bg[1] + 0.08, 1.0), @min(node_bg[2] + 0.08, 1.0), node_bg[3] });
        gui.pushStyleColor(.button_active, .{ @max(node_bg[0] - 0.08, 0.0), @max(node_bg[1] - 0.08, 0.0), @max(node_bg[2] - 0.08, 0.0), node_bg[3] });
        defer gui.popStyleColor(3);

        var name_buf: [64]u8 = undefined;
        const node_name = std.fmt.bufPrint(&name_buf, "{s}##node_{}", .{ node.getName(), index }) catch continue;

        if (gui.beginChild(node_name, node_width, node_height, true)) {
            gui.text(node.getName());

            gui.text("Enabled:");
            gui.sameLine();
            _ = gui.checkbox("##enabled", &node.enabled);
        }
        gui.endChild();

        if (gui.isItemClicked()) {
            editor_state.selected_node_index = index;
        }

        if (gui.isItemActive() and gui.isMouseDragging(.left)) {
            const drag_delta = gui.mouseDragDelta(.left);
            node.position[0] += drag_delta[0];
            node.position[1] += drag_delta[1];
            gui.resetMouseDragDelta(.left);
        }
    }
}

fn drawPreviewPanel(viewport_state: *EditorViewportState) void {
    gui.text("Preview");
    gui.separator();

    if (props.beginPropertyGrid("preview_settings")) {
        defer props.endPropertyGrid();

        _ = props.boolean("Bloom", &viewport_state.bloom_enabled);
        _ = props.boolean("FXAA", &viewport_state.fxaa_enabled);
        _ = props.boolean("SSAO", &viewport_state.ssao_enabled);
        _ = props.boolean("SSR", &viewport_state.ssr_enabled);
        _ = props.boolean("TAA", &viewport_state.taa_enabled);
        _ = props.boolean("DOF", &viewport_state.dof_enabled);
        _ = props.boolean("Contact Shadows", &viewport_state.contact_shadows_enabled);
        _ = props.boolean("RT Shadows", &viewport_state.rt_shadows_enabled);
    }
}

fn drawEffectParameters(viewport_state: *EditorViewportState, node: *PostProcessEffectNode) void {
    gui.text("Effect Parameters");
    gui.separator();

    if (!node.enabled) {
        gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Effect disabled");
        return;
    }

    if (props.beginPropertyGrid("effect_params")) {
        defer props.endPropertyGrid();

        switch (node.effect) {
            .bloom => {
                _ = props.boolean("RHI v2 Path", &viewport_state.bloom_use_rhi_v2);
                _ = props.float("Threshold", &viewport_state.bloom_threshold, 0.1, 0.0, 10.0);
                _ = props.float("Intensity", &viewport_state.bloom_intensity, 0.1, 0.0, 5.0);
            },
            .ssao => {
                _ = props.boolean("Legacy Path", &viewport_state.ssao_use_legacy_path);
                _ = props.float("Radius", &viewport_state.ssao_radius, 0.1, 0.0, 5.0);
                _ = props.float("Bias", &viewport_state.ssao_bias, 0.01, 0.0, 1.0);
                _ = props.float("Intensity", &viewport_state.ssao_intensity, 0.1, 0.0, 5.0);
                _ = props.float("Power", &viewport_state.ssao_power, 0.1, 0.0, 10.0);
            },
            .ssr => {
                _ = props.float("Intensity", &viewport_state.ssr_intensity, 0.1, 0.0, 2.0);
                _ = props.float("Ray Step", &viewport_state.ssr_ray_step, 0.01, 0.01, 1.0);
                _ = props.float("Max Distance", &viewport_state.ssr_ray_max_distance, 1.0, 10.0, 500.0);
            },
            .taa => {
                _ = props.float("Blend Factor", &viewport_state.taa_blend_factor, 0.01, 0.0, 1.0);
                _ = props.float("Feedback Min", &viewport_state.taa_feedback_min, 0.01, 0.0, 1.0);
                _ = props.float("Feedback Max", &viewport_state.taa_feedback_max, 0.01, 0.0, 1.0);
            },
            .dof => {
                _ = props.float("Focus Distance", &viewport_state.dof_focus_distance, 1.0, 0.0, 100.0);
                _ = props.float("Focus Range", &viewport_state.dof_focus_range, 0.5, 0.0, 50.0);
                _ = props.float("Blur Radius", &viewport_state.dof_blur_radius, 1.0, 0.0, 50.0);
                _ = props.boolean("RHI v2 Path", &viewport_state.dof_use_rhi_v2);
            },
            .fxaa => {
                _ = props.boolean("RHI v2 Path", &viewport_state.fxaa_use_rhi_v2);
            },
            .color_grading => {
                gui.text("No additional parameters");
            },
            .contact_shadows => {
                _ = props.float("Distance", &viewport_state.contact_shadows_distance, 0.05, 0.05, 2.0);
                _ = props.float("Thickness", &viewport_state.contact_shadows_thickness, 0.01, 0.01, 0.5);
                _ = props.float("Intensity", &viewport_state.contact_shadows_intensity, 0.05, 0.0, 1.0);
                _ = props.float("Bias", &viewport_state.contact_shadows_bias, 0.005, 0.0, 0.1);
                _ = props.boolean("RHI v2 Path", &viewport_state.contact_shadows_use_rhi_v2);
            },
            .tonemap => {
                _ = props.boolean("RHI v2 Path", &viewport_state.tonemap_use_rhi_v2);
            },
        }
    }
}
