const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const i18n = @import("../../../i18n/mod.zig");
const layout = @import("../../layout.zig");
const props = @import("../../properties.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const EditorViewportState = engine.render.EditorViewportState;
const EditorViewportLutPreset = engine.render.EditorViewportLutPreset;

const QuickAddItem = struct {
    effect: PostProcessEffect,
    label: []const u8,
    hint: []const u8,
};

const PreviewToggleItem = struct {
    label: []const u8,
    hint: []const u8,
    value: *bool,
};

const quick_add_items = [_]QuickAddItem{
    .{ .effect = .bloom, .label = "Bloom", .hint = "Highlight glow" },
    .{ .effect = .tonemap, .label = "Tonemap", .hint = "Exposure and LUT" },
    .{ .effect = .taa, .label = "TAA", .hint = "Temporal resolve" },
    .{ .effect = .ssr, .label = "SSR", .hint = "Screen-space reflections" },
    .{ .effect = .ssgi, .label = "SSGI", .hint = "Screen-space GI" },
    .{ .effect = .dof, .label = "DOF", .hint = "Depth of field" },
};

pub const PostProcessEffect = enum {
    bloom,
    fxaa,
    ssao,
    ssgi,
    ssr,
    taa,
    dof,
    color_grading,
    contact_shadows,
    tonemap,
};

pub const PostProcessEffectNode = struct {
    effect: PostProcessEffect,
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
            .ssgi => "SSGI",
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
            .ssgi => .{ 0.9, 0.6, 0.2, 1.0 },
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
                self.selected_node_index = null;
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
    const open_window = gui.beginWindowOpen(title, &editor_state_.post_process_editor_open);
    floating_window_blocker.registerCurrentWindow("post_process_panel");
    if (!open_window) {
        gui.endWindow();
        return;
    }
    defer gui.endWindow();

    const node_count = editor_state.nodes.items.len;

    drawPipelineToolbar(editor_state_, editor_state, viewport_state, node_count);
    gui.separator();

    const content_region = gui.contentRegionAvail();
    const has_nodes = node_count != 0;
    const graph_width = if (editor_state.show_preview)
        if (has_nodes)
            content_region[0] * editor_state.preview_split
        else
            content_region[0] * 0.56
    else
        content_region[0];

    if (gui.beginChild("pipeline_graph", graph_width, -1.0, true)) {
        drawPipelineGraph(editor_state_, editor_state, has_nodes);
    }
    gui.endChild();

    if (editor_state.show_preview) {
        gui.sameLine();
        if (gui.beginChild("pipeline_preview", -1.0, -1.0, true)) {
            drawPreviewPanel(editor_state_, viewport_state);
        }
        gui.endChild();
    }

    if (editor_state.selected_node_index) |selected_index| {
        if (editor_state.getSelectedNode()) |node| {
            gui.separator();
            drawEffectParameters(editor_state_, editor_state, viewport_state, selected_index, node);
        }
    } else if (node_count != 0) {
        gui.separator();
        drawEmptySelectionState(editor_state_);
    }
}

fn drawPipelineToolbar(
    state: *const EditorState,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
    node_count: usize,
) void {
    if (gui.button(state.text(.post_process_add_effect))) {
        gui.openPopup("add_effect_popup");
    }

    if (gui.beginPopup("add_effect_popup")) {
        defer gui.endPopup();

        const effects = [_]PostProcessEffect{
            .bloom,
            .fxaa,
            .ssao,
            .ssgi,
            .ssr,
            .taa,
            .dof,
            .color_grading,
            .contact_shadows,
            .tonemap,
        };

        for (effects) |effect| {
            var name_buf: [48]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}", .{nodeLabel(effect)}) catch continue;
            if (gui.selectable(name, false, false, 0, 0)) {
                const x = @as(f32, @floatFromInt(editor_state.nodes.items.len)) * 180.0;
                _ = addNodeAndSelect(editor_state, effect, x, 96.0);
            }
        }
    }

    gui.sameLine();

    if (gui.button(state.text(.post_process_clear_all))) {
        clearAllNodes(editor_state);
        setAllPreviewEffects(viewport_state, false);
    }

    gui.sameLine();
    gui.text(state.text(.post_process_preview));
    gui.sameLine();
    var preview_toggle_buffer: [96]u8 = undefined;
    const preview_toggle_label = std.fmt.bufPrint(
        &preview_toggle_buffer,
        "{s}##show_preview",
        .{state.text(.post_process_preview)},
    ) catch "##show_preview";
    _ = gui.checkbox(preview_toggle_label, &editor_state.show_preview);

    gui.dummy(0.0, 6.0);
    var summary_buf: [128]u8 = undefined;
    const summary_text = i18n.bufPrintMessage(
        &summary_buf,
        .post_process_graph_nodes_fmt,
        state.language,
        .{node_count},
    ) catch state.text(.post_process_pipeline);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, summary_text);

    if (node_count == 0) {
        gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_toolbar_empty_hint));
    } else {
        gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_toolbar_reorder_hint));
    }
}

fn drawPipelineGraph(state: *const EditorState, editor_state: *PostProcessPipelineEditorState, has_nodes: bool) void {
    const canvas_pos = gui.cursorScreenPos();
    const canvas_size = gui.contentRegionAvail();

    _ = gui.invisibleButton("canvas", canvas_size[0], canvas_size[1]);

    if (!has_nodes) {
        drawEmptyPipelineCanvas(state, editor_state, canvas_size);
        return;
    }

    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_graph_role_hint));

    for (editor_state.nodes.items, 0..) |*node, index| {
        const is_selected = editor_state.selected_node_index != null and editor_state.selected_node_index.? == index;

        const node_pos = [2]f32{
            canvas_pos[0] + node.position[0] + editor_state.view_pan[0],
            canvas_pos[1] + node.position[1] + editor_state.view_pan[1],
        };

        gui.setCursorScreenPos(node_pos);

        const node_width: f32 = 164.0;
        const node_height: f32 = 74.0;

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
            var detail_buf: [64]u8 = undefined;
            const detail_text = std.fmt.bufPrint(
                &detail_buf,
                "In {d}  Out {d}",
                .{ node.input_connections.items.len, node.output_connections.items.len },
            ) catch "";
            gui.textColored(.{ 0.65, 0.68, 0.73, 1.0 }, detail_text);
            if (is_selected) {
                gui.textColored(.{ 0.92, 0.97, 0.80, 1.0 }, "Selected");
            }
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

fn drawEmptyPipelineCanvas(state: *const EditorState, editor_state: *PostProcessPipelineEditorState, canvas_size: [2]f32) void {
    const spacer = @max(canvas_size[1] * 0.12, 16.0);
    gui.dummy(0.0, spacer);

    gui.textColored(.{ 0.92, 0.95, 0.98, 1.0 }, state.text(.post_process_graph_empty_title));
    gui.textWrapped(state.text(.post_process_graph_empty_desc));

    gui.dummy(0.0, 10.0);
    const columns = layout.responsiveButtonColumns(quick_add_items.len, 128.0);
    const width = layout.responsiveButtonWidth(columns);
    for (quick_add_items, 0..) |item, index| {
        if (index > 0) {
            layout.advanceResponsiveRow(index, columns);
        }
        if (drawAccentButton(item.label, width, item.hint, false)) {
            _ = addNodeAndSelect(editor_state, item.effect, @as(f32, @floatFromInt(editor_state.nodes.items.len)) * 180.0, 96.0);
        }
    }

    gui.dummy(0.0, 10.0);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_graph_empty_tip));
}

fn drawPreviewPanel(state: *const EditorState, viewport_state: *EditorViewportState) void {
    gui.text(state.text(.post_process_live_preview_title));
    gui.separator();
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_live_preview_legend));

    gui.dummy(0.0, 6.0);
    gui.text(state.text(.post_process_core));
    drawPreviewCoreControls(viewport_state);

    gui.dummy(0.0, 6.0);
    gui.text(state.text(.post_process_screen_space));
    drawPreviewScreenControls(viewport_state);

    gui.dummy(0.0, 8.0);
    var status_buf: [96]u8 = undefined;
    const status_text = i18n.bufPrintMessage(
        &status_buf,
        .post_process_live_preview_enabled_fmt,
        state.language,
        .{enabledEffectCount(viewport_state)},
    ) catch state.text(.post_process_live_preview_title);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, status_text);

    gui.dummy(0.0, 8.0);
    if (gui.button(state.text(.post_process_enable_all))) {
        setAllPreviewEffects(viewport_state, true);
    }
    gui.sameLine();
    if (gui.button(state.text(.post_process_disable_all))) {
        setAllPreviewEffects(viewport_state, false);
    }
}

fn drawPreviewCoreControls(viewport_state: *EditorViewportState) void {
    const items = [_]PreviewToggleItem{
        .{ .label = "Manual Exposure", .hint = "HDR preview", .value = &viewport_state.exposure_enabled },
        .{ .label = "Bloom", .hint = "Glow pass", .value = &viewport_state.bloom_enabled },
        .{ .label = "Color Grading", .hint = "Tone shaping", .value = &viewport_state.color_grading_enabled },
        .{ .label = "FXAA", .hint = "Fallback AA", .value = &viewport_state.fxaa_enabled },
        .{ .label = "TAA", .hint = "Temporal AA", .value = &viewport_state.taa_enabled },
        .{ .label = "LUT", .hint = "Look-up table", .value = &viewport_state.lut_enabled },
    };
    drawPreviewToggleGrid(items[0..], 138.0);
}

fn drawPreviewScreenControls(viewport_state: *EditorViewportState) void {
    const items = [_]PreviewToggleItem{
        .{ .label = "SSAO", .hint = "Ambient occlusion", .value = &viewport_state.ssao_enabled },
        .{ .label = "SSGI", .hint = "Global illumination", .value = &viewport_state.ssgi_enabled },
        .{ .label = "SSR", .hint = "Screen-space reflections", .value = &viewport_state.ssr_enabled },
        .{ .label = "DOF", .hint = "Lens blur", .value = &viewport_state.dof_enabled },
        .{ .label = "Contact Shadows", .hint = "Small-scale occlusion", .value = &viewport_state.contact_shadows_enabled },
        .{ .label = "RT Shadows", .hint = "Hardware shadow path", .value = &viewport_state.rt_shadows_enabled },
    };
    drawPreviewToggleGrid(items[0..], 138.0);
}

fn drawPreviewToggleGrid(items: []const PreviewToggleItem, min_width_hint: f32) void {
    const columns = layout.responsiveButtonColumns(items.len, min_width_hint);
    const width = layout.responsiveButtonWidth(columns);
    for (items, 0..) |item, index| {
        if (index > 0) {
            layout.advanceResponsiveRow(index, columns);
        }
        const active = item.value.*;
        if (drawToggleChip(item.label, width, item.hint, active)) {
            item.value.* = !active;
        }
    }
}

fn drawEffectParameters(
    state: *const EditorState,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
    selected_index: usize,
    node: *PostProcessEffectNode,
) void {
    gui.text(state.text(.post_process_effect_parameters));
    gui.sameLine();
    if (gui.button(state.text(.post_process_remove_node))) {
        _ = editor_state.removeNode(selected_index);
        return;
    }
    gui.separator();

    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, node.getName());
    gui.textWrapped(state.text(.post_process_effect_parameters_desc));

    if (props.beginPropertyGrid("effect_params")) {
        defer props.endPropertyGrid();

        switch (node.effect) {
            .bloom => {
                _ = props.float("Threshold", &viewport_state.bloom_threshold, 0.1, 0.0, 10.0);
                _ = props.float("Intensity", &viewport_state.bloom_intensity, 0.1, 0.0, 5.0);
            },
            .ssao => {
                _ = props.float("Radius", &viewport_state.ssao_radius, 0.1, 0.0, 5.0);
                _ = props.float("Bias", &viewport_state.ssao_bias, 0.01, 0.0, 1.0);
                _ = props.float("Intensity", &viewport_state.ssao_intensity, 0.1, 0.0, 5.0);
                _ = props.float("Power", &viewport_state.ssao_power, 0.1, 0.0, 10.0);
            },
            .ssgi => {
                _ = props.float("Radius", &viewport_state.ssgi_radius, 0.1, 0.1, 10.0);
                _ = props.float("Intensity", &viewport_state.ssgi_intensity, 0.1, 0.0, 10.0);
                _ = props.float("Bias", &viewport_state.ssgi_bias, 0.01, 0.0, 1.0);
                var ray_count: i32 = @intCast(viewport_state.ssgi_ray_count);
                if (props.int("Ray Count", &ray_count, 1.0, 1, 64)) {
                    viewport_state.ssgi_ray_count = @intCast(std.math.clamp(ray_count, 1, 64));
                }
                var step_count: i32 = @intCast(viewport_state.ssgi_step_count);
                if (props.int("Step Count", &step_count, 1.0, 1, 64)) {
                    viewport_state.ssgi_step_count = @intCast(std.math.clamp(step_count, 1, 64));
                }
            },
            .ssr => {
                _ = props.float("Intensity", &viewport_state.ssr_intensity, 0.1, 0.0, 2.0);
                _ = props.float("Ray Step", &viewport_state.ssr_ray_step, 0.01, 0.01, 1.0);
                _ = props.float("Max Distance", &viewport_state.ssr_ray_max_distance, 1.0, 10.0, 500.0);
                _ = props.float("Ray Thickness", &viewport_state.ssr_ray_thickness, 0.01, 0.01, 2.0);
                _ = props.float("Fade Distance", &viewport_state.ssr_fade_distance, 0.1, 0.0, 100.0);
                _ = props.float("Edge Fade", &viewport_state.ssr_edge_fade, 0.01, 0.0, 1.0);
                _ = props.float("Roughness Blur", &viewport_state.ssr_roughness_blur_strength, 0.1, 0.0, 8.0);
            },
            .taa => {
                _ = props.float("Blend Factor", &viewport_state.taa_blend_factor, 0.01, 0.0, 1.0);
                _ = props.float("Motion Blur Scale", &viewport_state.taa_motion_blur_scale, 0.01, 0.0, 2.0);
                _ = props.float("Feedback Min", &viewport_state.taa_feedback_min, 0.01, 0.0, 1.0);
                _ = props.float("Feedback Max", &viewport_state.taa_feedback_max, 0.01, 0.0, 1.0);
            },
            .dof => {
                _ = props.float("Focus Distance", &viewport_state.dof_focus_distance, 1.0, 0.0, 100.0);
                _ = props.float("Focus Range", &viewport_state.dof_focus_range, 0.5, 0.0, 50.0);
                _ = props.float("Blur Radius", &viewport_state.dof_blur_radius, 1.0, 0.0, 50.0);
                _ = props.float("Bokeh Radius", &viewport_state.dof_bokeh_radius, 0.5, 0.0, 32.0);
                _ = props.float("Near Blur", &viewport_state.dof_near_blur, 0.1, 0.0, 50.0);
                _ = props.float("Far Blur", &viewport_state.dof_far_blur, 0.5, 0.0, 250.0);
                var quality: i32 = @intCast(viewport_state.dof_quality);
                if (props.int("Quality", &quality, 1.0, 1, 8)) {
                    viewport_state.dof_quality = @intCast(std.math.clamp(quality, 1, 8));
                }
            },
            .fxaa => {
                gui.textWrapped("No additional parameters.");
            },
            .color_grading => {
                _ = props.float("Saturation", &viewport_state.color_grading_saturation, 0.01, 0.0, 2.0);
                _ = props.float("Contrast", &viewport_state.color_grading_contrast, 0.01, 0.5, 2.0);
                _ = props.float("Gamma", &viewport_state.color_grading_gamma, 0.01, 0.5, 2.0);
            },
            .contact_shadows => {
                _ = props.float("Distance", &viewport_state.contact_shadows_distance, 0.05, 0.05, 2.0);
                _ = props.float("Thickness", &viewport_state.contact_shadows_thickness, 0.01, 0.01, 0.5);
                _ = props.float("Intensity", &viewport_state.contact_shadows_intensity, 0.05, 0.0, 1.0);
                _ = props.float("Bias", &viewport_state.contact_shadows_bias, 0.005, 0.0, 0.1);
                var steps: i32 = @intCast(viewport_state.contact_shadows_steps);
                if (props.int("Steps", &steps, 1.0, 1, 64)) {
                    viewport_state.contact_shadows_steps = @intCast(std.math.clamp(steps, 1, 64));
                }
            },
            .tonemap => {
                _ = props.boolean("Manual Exposure", &viewport_state.exposure_enabled);
                _ = props.float("Exposure", &viewport_state.exposure, 0.01, 0.1, 8.0);
                _ = props.boolean("LUT", &viewport_state.lut_enabled);
                _ = props.float("LUT Intensity", &viewport_state.lut_intensity, 0.01, 0.0, 1.0);
                drawLutPresetProperty(viewport_state);
            },
        }
    }
}

fn drawEmptySelectionState(state: *const EditorState) void {
    gui.text(state.text(.post_process_empty_selection_title));
    gui.textWrapped(state.text(.post_process_empty_selection_desc));
}

fn drawToggleChip(label: []const u8, width: f32, hint: []const u8, active: bool) bool {
    const bg: [4]f32 = if (active)
        .{ 0.20, 0.53, 0.36, 0.92 }
    else
        .{ 0.14, 0.16, 0.18, 0.82 };
    const hovered: [4]f32 = if (active)
        .{ 0.24, 0.62, 0.42, 0.96 }
    else
        .{ 0.20, 0.22, 0.25, 0.92 };
    const pressed: [4]f32 = if (active)
        .{ 0.12, 0.42, 0.28, 1.0 }
    else
        .{ 0.18, 0.20, 0.23, 1.0 };

    gui.pushStyleColor(.button, bg);
    gui.pushStyleColor(.button_hovered, hovered);
    gui.pushStyleColor(.button_active, pressed);
    defer gui.popStyleColor(3);

    const clicked = gui.buttonEx(label, width, 0.0);
    if (gui.isItemHovered() and hint.len != 0) {
        gui.setTooltip(hint);
    }
    return clicked;
}

fn drawAccentButton(label: []const u8, width: f32, hint: []const u8, active: bool) bool {
    const bg: [4]f32 = if (active)
        .{ 0.20, 0.53, 0.36, 0.92 }
    else
        .{ 0.17, 0.20, 0.24, 0.88 };
    const hovered: [4]f32 = if (active)
        .{ 0.24, 0.62, 0.42, 0.96 }
    else
        .{ 0.22, 0.26, 0.30, 0.96 };
    const pressed: [4]f32 = if (active)
        .{ 0.12, 0.42, 0.28, 1.0 }
    else
        .{ 0.16, 0.18, 0.21, 1.0 };

    gui.pushStyleColor(.button, bg);
    gui.pushStyleColor(.button_hovered, hovered);
    gui.pushStyleColor(.button_active, pressed);
    defer gui.popStyleColor(3);

    const clicked = gui.buttonEx(label, width, 0.0);
    if (gui.isItemHovered() and hint.len != 0) {
        gui.setTooltip(hint);
    }
    return clicked;
}

fn addNodeAndSelect(editor_state: *PostProcessPipelineEditorState, effect: PostProcessEffect, x: f32, y: f32) bool {
    const index = editor_state.addNode(effect, x, y) catch return false;
    editor_state.selected_node_index = index;
    return true;
}

fn clearAllNodes(editor_state: *PostProcessPipelineEditorState) void {
    for (editor_state.nodes.items) |*node| {
        node.deinit(editor_state.allocator);
    }
    editor_state.nodes.clearRetainingCapacity();
    editor_state.selected_node_index = null;
}

fn setAllPreviewEffects(viewport_state: *EditorViewportState, enabled: bool) void {
    viewport_state.exposure_enabled = enabled;
    viewport_state.bloom_enabled = enabled;
    viewport_state.color_grading_enabled = enabled;
    viewport_state.fxaa_enabled = enabled;
    viewport_state.ssao_enabled = enabled;
    viewport_state.ssgi_enabled = enabled;
    viewport_state.ssr_enabled = enabled;
    viewport_state.taa_enabled = enabled;
    viewport_state.dof_enabled = enabled;
    viewport_state.contact_shadows_enabled = enabled;
    viewport_state.rt_shadows_enabled = enabled;
    viewport_state.lut_enabled = enabled;
}

fn enabledEffectCount(viewport_state: *const EditorViewportState) usize {
    return @intFromBool(viewport_state.exposure_enabled) +
        @intFromBool(viewport_state.bloom_enabled) +
        @intFromBool(viewport_state.color_grading_enabled) +
        @intFromBool(viewport_state.fxaa_enabled) +
        @intFromBool(viewport_state.ssao_enabled) +
        @intFromBool(viewport_state.ssgi_enabled) +
        @intFromBool(viewport_state.ssr_enabled) +
        @intFromBool(viewport_state.taa_enabled) +
        @intFromBool(viewport_state.dof_enabled) +
        @intFromBool(viewport_state.contact_shadows_enabled) +
        @intFromBool(viewport_state.rt_shadows_enabled) +
        @intFromBool(viewport_state.lut_enabled);
}

fn nodeLabel(effect: PostProcessEffect) []const u8 {
    return switch (effect) {
        .bloom => "Bloom",
        .fxaa => "FXAA",
        .ssao => "SSAO",
        .ssgi => "SSGI",
        .ssr => "SSR",
        .taa => "TAA",
        .dof => "DOF",
        .color_grading => "Color Grading",
        .contact_shadows => "Contact Shadows",
        .tonemap => "Tonemap",
    };
}

fn drawLutPresetProperty(viewport_state: *EditorViewportState) void {
    const preview = lutPresetLabel(viewport_state.lut_preset);
    if (!props.combo("LUT Preset", preview)) {
        return;
    }
    defer gui.endCombo();

    const presets = [_]EditorViewportLutPreset{ .neutral, .warm, .cool, .filmic };
    for (presets) |preset| {
        const selected = viewport_state.lut_preset == preset;
        if (gui.selectable(lutPresetLabel(preset), selected, false, 0.0, 0.0)) {
            viewport_state.lut_preset = preset;
        }
    }
}

fn lutPresetLabel(preset: EditorViewportLutPreset) []const u8 {
    return switch (preset) {
        .neutral => "Neutral",
        .warm => "Warm",
        .cool => "Cool",
        .filmic => "Filmic",
    };
}
