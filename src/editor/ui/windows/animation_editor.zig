const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");
const inspector = @import("inspector.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");
const animation_graph_mod = engine.animation.animation_graph;
const handles = engine.assets.handles;
const i18n = @import("../../i18n/message_id.zig");

const TimelineTrack = struct {
    name: []const u8,
    type: enum { translation, rotation, scale },
    target_index: u32,
    keyframes: std.ArrayList(Keyframe),

    const Keyframe = struct {
        time: f32,
        value: union(enum) {
            vec3: [3]f32,
            quat: [4]f32,
        },
        interpolation: engine.assets.AnimationInterpolation,
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.keyframes.deinit(allocator);
        self.* = undefined;
    }
};

pub const AnimationEditorState = struct {
    selected_entity: ?engine.scene.EntityId = null,
    selected_clip: ?handles.AnimationClipHandle = null,
    selected_graph: ?*const animation_graph_mod.AnimationGraph = null,
    selected_runtime: ?animation_graph_mod.RuntimeClipBlend = null,
    timeline_scale: f32 = 1.0,
    timeline_offset: f32 = 0.0,
    current_time: f32 = 0.0,
    is_playing: bool = false,
    selected_track: ?u32 = null,
    selected_keyframe: ?u32 = null,
    tracks: std.ArrayList(TimelineTrack),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.tracks.items) |*track| {
            track.deinit(allocator);
        }
        self.tracks.deinit(allocator);
        self.* = undefined;
    }

    pub fn loadClip(self: *@This(), allocator: std.mem.Allocator, clip: *const engine.assets.AnimationClipResource) !void {
        self.clearTracks(allocator);
        self.current_time = 0.0;
        self.selected_track = null;
        self.selected_keyframe = null;

        for (clip.translation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Translation_{}", .{track.target_entity_index}),
                .type = .translation,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }

        for (clip.rotation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Rotation_{}", .{track.target_entity_index}),
                .type = .rotation,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .quat = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }

        for (clip.scale_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Scale_{}", .{track.target_entity_index}),
                .type = .scale,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }
    }

    fn clearTracks(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.tracks.items) |*track| {
            track.deinit(allocator);
        }
        self.tracks.clearRetainingCapacity();
    }
};

pub fn drawAnimationEditorWindow(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .animation_editor, "animation_editor_popup");
    var open = state.animation_editor_open;
    _ = engine.ui.ImGui.beginWindowFlagsOpen(title, &open, engine.ui.ImGui.WindowFlags.no_docking);
    state.animation_editor_open = open;
    defer engine.ui.ImGui.endWindow();

    if (!open) {
        return;
    }

    try syncAnimationSource(layer_context, editor_state);
    const runtime_driven = editor_state.selected_graph != null and editor_state.selected_runtime != null;

    if (runtime_driven) {
        editor_state.is_playing = false;
        editor_state.current_time = editor_state.selected_runtime.?.primary.sample_time;
    } else if (editor_state.is_playing) {
        const clip_duration = if (editor_state.selected_clip) |clip_handle|
            if (layer_context.world.resources.animationClip(clip_handle)) |clip| @max(clip.duration, 0.001) else 0.0
        else
            0.0;
        if (clip_duration > 0.0) {
            editor_state.current_time = @mod(editor_state.current_time + layer_context.delta_seconds, clip_duration);
        }
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    if (engine.ui.ImGui.beginChild("animation_graph_runtime_panel", -1.0, 184.0, true)) {
        defer engine.ui.ImGui.endChild();
        drawGraphRuntimePanel(state, layer_context, editor_state);
    }

    if (engine.ui.ImGui.beginChild("animation_editor_main", -1.0, -48.0, false)) {
        defer engine.ui.ImGui.endChild();

        if (engine.ui.ImGui.beginTable("animation_editor_layout", 2)) {
            engine.ui.ImGui.tableSetupColumn("Tracks", true, 0.3);
            engine.ui.ImGui.tableSetupColumn("Timeline", true, 0.7);

            engine.ui.ImGui.tableNextRow();
            engine.ui.ImGui.tableNextColumn();

            drawTrackList(state, editor_state, layer_context);

            engine.ui.ImGui.tableNextColumn();

            drawTimeline(state, editor_state, layer_context);

            engine.ui.ImGui.endTable();
        }
    }

    try drawTimelineControls(state, editor_state, layer_context);
}

fn drawTrackList(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    engine.ui.ImGui.text(localText(state, .animation_tracks));
    engine.ui.ImGui.separator();

    if (engine.ui.ImGui.beginChild("track_list", -1.0, -1.0, false)) {
        defer engine.ui.ImGui.endChild();

        for (editor_state.tracks.items, 0..) |track, index| {
            const is_selected = editor_state.selected_track == @as(u32, @intCast(index));

            var track_label: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&track_label, "{s}##track_{}", .{ track.name, index }) catch continue;

            if (engine.ui.ImGui.selectable(label, is_selected, false, -1.0, 22.0)) {
                editor_state.selected_track = @intCast(index);
            }

            if (engine.ui.ImGui.beginPopupContextItem(null)) {
                defer engine.ui.ImGui.endPopup();

                if (engine.ui.ImGui.menuItem(localText(state, .delete_track), null, false, true)) {
                    deleteTrack(
                        editor_state,
                        state.allocator orelse layer_context.world.allocator,
                        index,
                    );
                }
            }
        }

        if (editor_state.tracks.items.len == 0) {
            engine.ui.ImGui.textWrapped(localText(state, .no_animation_tracks_loaded));
        }
    }
}

fn drawTimeline(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    engine.ui.ImGui.text(localText(state, .animation_timeline));
    engine.ui.ImGui.separator();

    const clip = if (editor_state.selected_clip) |clip_handle|
        layer_context.world.resources.animationClip(clip_handle)
    else
        null;

    const duration: f32 = if (clip) |clip_resource| clip_resource.duration else 1.0;
    const pixels_per_second = 50.0 * editor_state.timeline_scale;

    if (engine.ui.ImGui.beginChild("timeline_area", -1.0, -1.0, true)) {
        defer engine.ui.ImGui.endChild();

        const track_height = 24.0;
        const track_spacing = 2.0;

        if (engine.ui.ImGui.beginChild("timeline_ruler", -1.0, 24.0, false)) {
            defer engine.ui.ImGui.endChild();

            const canvas_width = engine.ui.ImGui.contentRegionAvail()[0];

            var draw_list = engine.ui.ImGui.getWindowDrawList();
            const cursor_pos = engine.ui.ImGui.cursorScreenPos();

            const major_tick_height: f32 = 12.0;
            const minor_tick_height: f32 = 6.0;
            const time_interval: f32 = if (pixels_per_second > 30.0) 0.1 else if (pixels_per_second > 10.0) 0.5 else 1.0;

            var time: f32 = 0.0;
            while (time <= duration) : (time += time_interval) {
                const x = cursor_pos[0] + time * pixels_per_second - editor_state.timeline_offset;
                if (x >= cursor_pos[0] and x <= cursor_pos[0] + canvas_width) {
                    const is_major = @abs(@mod(time, 1.0)) < 0.01 or time == 0.0;
                    const tick_height: f32 = if (is_major) major_tick_height else minor_tick_height;

                    draw_list.addLine(.{ x, cursor_pos[1] + 2 }, .{ x, cursor_pos[1] + tick_height }, engine.ui.ImGui.getColorU32(.{ 0.7, 0.7, 0.7, 1.0 }), 1.0);

                    if (is_major and time < duration) {
                        var time_label: [16]u8 = undefined;
                        const label = std.fmt.bufPrint(&time_label, "{d:.1}s", .{time}) catch continue;
                        draw_list.addText(.{ x + 2, cursor_pos[1] + 2 }, engine.ui.ImGui.getColorU32(.{ 0.8, 0.8, 0.8, 1.0 }), label);
                    }
                }
            }

            const current_time_x = cursor_pos[0] + editor_state.current_time * pixels_per_second - editor_state.timeline_offset;
            if (current_time_x >= cursor_pos[0] and current_time_x <= cursor_pos[0] + canvas_width) {
                draw_list.addLine(.{ current_time_x, cursor_pos[1] }, .{ current_time_x, cursor_pos[1] + 22 }, engine.ui.ImGui.getColorU32(.{ 0.9, 0.3, 0.3, 1.0 }), 2.0);
            }
        }

        if (engine.ui.ImGui.beginChild("timeline_tracks", -1.0, -1.0, false)) {
            defer engine.ui.ImGui.endChild();

            const canvas_width = engine.ui.ImGui.contentRegionAvail()[0];
            var draw_list = engine.ui.ImGui.getWindowDrawList();

            for (editor_state.tracks.items, 0..) |track, track_index| {
                engine.ui.ImGui.pushIdU64(track_index);
                defer engine.ui.ImGui.popId();

                const cursor_pos = engine.ui.ImGui.cursorScreenPos();
                const is_selected = editor_state.selected_track == @as(u32, @intCast(track_index));
                if (engine.ui.ImGui.invisibleButton("track_row", canvas_width, track_height)) {
                    editor_state.selected_track = @intCast(track_index);
                }

                const background_color: [4]f32 = if (is_selected)
                    .{ 0.18, 0.23, 0.30, 1.0 }
                else
                    .{ 0.15, 0.15, 0.15, 1.0 };
                draw_list.addRectFilled(
                    cursor_pos,
                    .{ cursor_pos[0] + canvas_width, cursor_pos[1] + track_height },
                    engine.ui.ImGui.getColorU32(background_color),
                    0,
                    0,
                );
                draw_list.addLine(
                    .{ cursor_pos[0], cursor_pos[1] + track_height - 1.0 },
                    .{ cursor_pos[0] + canvas_width, cursor_pos[1] + track_height - 1.0 },
                    engine.ui.ImGui.getColorU32(.{ 0.24, 0.24, 0.24, 1.0 }),
                    1.0,
                );

                const current_time_x = cursor_pos[0] + editor_state.current_time * pixels_per_second - editor_state.timeline_offset;
                if (current_time_x >= cursor_pos[0] and current_time_x <= cursor_pos[0] + canvas_width) {
                    draw_list.addLine(
                        .{ current_time_x, cursor_pos[1] },
                        .{ current_time_x, cursor_pos[1] + track_height },
                        engine.ui.ImGui.getColorU32(.{ 0.9, 0.3, 0.3, 1.0 }),
                        1.0,
                    );
                }

                for (track.keyframes.items, 0..) |keyframe, keyframe_index| {
                    const x = cursor_pos[0] + keyframe.time * pixels_per_second - editor_state.timeline_offset;
                    if (x >= cursor_pos[0] and x <= cursor_pos[0] + canvas_width) {
                        const keyframe_color = switch (track.type) {
                            .translation => [4]f32{ 0.2, 0.6, 0.9, 1.0 },
                            .rotation => [4]f32{ 0.9, 0.6, 0.2, 1.0 },
                            .scale => [4]f32{ 0.2, 0.9, 0.6, 1.0 },
                        };

                        draw_list.addCircleFilled(
                            .{ x, cursor_pos[1] + track_height * 0.5 },
                            4.0,
                            engine.ui.ImGui.getColorU32(keyframe_color),
                            8,
                        );

                        if (keyframe_index == 0) {
                            draw_list.addLine(
                                .{ cursor_pos[0], cursor_pos[1] + track_height * 0.5 },
                                .{ x, cursor_pos[1] + track_height * 0.5 },
                                engine.ui.ImGui.getColorU32(keyframe_color),
                                1.0,
                            );
                        }

                        if (keyframe_index < track.keyframes.items.len - 1) {
                            const next_keyframe = track.keyframes.items[keyframe_index + 1];
                            const next_x = cursor_pos[0] + next_keyframe.time * pixels_per_second - editor_state.timeline_offset;

                            if (next_x >= cursor_pos[0] and next_x <= cursor_pos[0] + canvas_width) {
                                draw_list.addLine(
                                    .{ x, cursor_pos[1] + track_height * 0.5 },
                                    .{ next_x, cursor_pos[1] + track_height * 0.5 },
                                    engine.ui.ImGui.getColorU32(keyframe_color),
                                    1.0,
                                );
                            }
                        }
                    }
                }

                engine.ui.ImGui.dummy(0.0, track_spacing);
            }
        }
    }
}

fn drawTimelineControls(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) !void {
    const runtime_driven = editor_state.selected_graph != null and editor_state.selected_runtime != null;

    if (runtime_driven) {
        engine.ui.ImGui.textWrapped(localText(state, .runtime_driven_timeline));
    }

    if (engine.ui.ImGui.button(localText(state, .play_pause))) {
        if (!runtime_driven) {
            editor_state.is_playing = !editor_state.is_playing;
        }
    }

    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(localText(state, .stop))) {
        if (!runtime_driven) {
            editor_state.is_playing = false;
            editor_state.current_time = 0.0;
        }
    }

    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(100.0);
    _ = engine.ui.ImGui.dragFloat("##current_time", &editor_state.current_time, 0.01, 0.0, 100.0);

    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(100.0);
    _ = engine.ui.ImGui.dragFloat("##timeline_scale", &editor_state.timeline_scale, 0.01, 0.1, 10.0);

    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(localText(state, .load_clip))) {
        try syncAnimationSource(layer_context, editor_state);
    }
}

pub fn createAnimationEditorState(allocator: std.mem.Allocator) !AnimationEditorState {
    _ = allocator;
    return AnimationEditorState{
        .tracks = .empty,
    };
}

pub fn destroyAnimationEditorState(editor_state: *AnimationEditorState, allocator: std.mem.Allocator) void {
    editor_state.deinit(allocator);
}

pub const MessageId = enum {
    animation_editor,
    animation_graph,
    animation_tracks,
    animation_timeline,
    bound_graph,
    current_state,
    next_state,
    transition_progress,
    graph_parameters,
    graph_transitions,
    no_animator_selected,
    no_animation_graph_bound,
    no_graph_parameters,
    no_graph_transitions,
    runtime_driven_timeline,
    play_pause,
    stop,
    load_clip,
    no_animation_tracks_loaded,
    delete_track,

    pub const en_us = .{
        .animation_editor = "Animation Editor",
        .animation_graph = "Animation Graph",
        .animation_tracks = "Animation Tracks",
        .animation_timeline = "Timeline",
        .bound_graph = "Bound Graph",
        .current_state = "Current State",
        .next_state = "Next State",
        .transition_progress = "Transition",
        .graph_parameters = "Parameters",
        .graph_transitions = "Transitions",
        .no_animator_selected = "Select an entity with an Animator component to inspect runtime animation data.",
        .no_animation_graph_bound = "The selected Animator is using clip playback only; no animation graph is bound.",
        .no_graph_parameters = "This animation graph does not define any runtime parameters.",
        .no_graph_transitions = "This animation graph does not define any transitions.",
        .runtime_driven_timeline = "Timeline is following the selected animator runtime because this entity is graph-driven.",
        .play_pause = "Play/Pause",
        .stop = "Stop",
        .load_clip = "Load Selected Clip",
        .no_animation_tracks_loaded = "No animation tracks loaded. Select an entity with an Animator component.",
        .delete_track = "Delete Track",
    };

    pub const zh_cn = .{
        .animation_editor = "动画编辑器",
        .animation_graph = "动画图",
        .animation_tracks = "动画轨道",
        .animation_timeline = "时间轴",
        .bound_graph = "绑定动画图",
        .current_state = "当前状态",
        .next_state = "下一状态",
        .transition_progress = "过渡进度",
        .graph_parameters = "参数",
        .graph_transitions = "过渡",
        .no_animator_selected = "请选择带有 Animator 组件的实体以查看运行时动画数据。",
        .no_animation_graph_bound = "当前选中的 Animator 仍在使用 clip 播放，没有绑定动画图。",
        .no_graph_parameters = "该动画图没有定义运行时参数。",
        .no_graph_transitions = "该动画图没有定义过渡。",
        .runtime_driven_timeline = "该实体由动画图驱动，时间轴会跟随当前运行时状态。",
        .play_pause = "播放/暂停",
        .stop = "停止",
        .load_clip = "加载选中动画",
        .no_animation_tracks_loaded = "未加载动画轨道。请选择带有 Animator 组件的实体。",
        .delete_track = "删除轨道",
    };
};

pub const text_map = .{
    .en_us = &MessageId.en_us,
    .zh_cn = &MessageId.zh_cn,
};

fn localText(state: *const EditorState, id: MessageId) []const u8 {
    return switch (state.language) {
        .en_us => switch (id) {
            .animation_editor => MessageId.en_us.animation_editor,
            .animation_graph => MessageId.en_us.animation_graph,
            .animation_tracks => MessageId.en_us.animation_tracks,
            .animation_timeline => MessageId.en_us.animation_timeline,
            .bound_graph => MessageId.en_us.bound_graph,
            .current_state => MessageId.en_us.current_state,
            .next_state => MessageId.en_us.next_state,
            .transition_progress => MessageId.en_us.transition_progress,
            .graph_parameters => MessageId.en_us.graph_parameters,
            .graph_transitions => MessageId.en_us.graph_transitions,
            .no_animator_selected => MessageId.en_us.no_animator_selected,
            .no_animation_graph_bound => MessageId.en_us.no_animation_graph_bound,
            .no_graph_parameters => MessageId.en_us.no_graph_parameters,
            .no_graph_transitions => MessageId.en_us.no_graph_transitions,
            .runtime_driven_timeline => MessageId.en_us.runtime_driven_timeline,
            .play_pause => MessageId.en_us.play_pause,
            .stop => MessageId.en_us.stop,
            .load_clip => MessageId.en_us.load_clip,
            .no_animation_tracks_loaded => MessageId.en_us.no_animation_tracks_loaded,
            .delete_track => MessageId.en_us.delete_track,
        },
        .zh_cn => switch (id) {
            .animation_editor => MessageId.zh_cn.animation_editor,
            .animation_graph => MessageId.zh_cn.animation_graph,
            .animation_tracks => MessageId.zh_cn.animation_tracks,
            .animation_timeline => MessageId.zh_cn.animation_timeline,
            .bound_graph => MessageId.zh_cn.bound_graph,
            .current_state => MessageId.zh_cn.current_state,
            .next_state => MessageId.zh_cn.next_state,
            .transition_progress => MessageId.zh_cn.transition_progress,
            .graph_parameters => MessageId.zh_cn.graph_parameters,
            .graph_transitions => MessageId.zh_cn.graph_transitions,
            .no_animator_selected => MessageId.zh_cn.no_animator_selected,
            .no_animation_graph_bound => MessageId.zh_cn.no_animation_graph_bound,
            .no_graph_parameters => MessageId.zh_cn.no_graph_parameters,
            .no_graph_transitions => MessageId.zh_cn.no_graph_transitions,
            .runtime_driven_timeline => MessageId.zh_cn.runtime_driven_timeline,
            .play_pause => MessageId.zh_cn.play_pause,
            .stop => MessageId.zh_cn.stop,
            .load_clip => MessageId.zh_cn.load_clip,
            .no_animation_tracks_loaded => MessageId.zh_cn.no_animation_tracks_loaded,
            .delete_track => MessageId.zh_cn.delete_track,
        },
    };
}

fn blendQuat(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var qa = engine.math.quat.normalize(a);
    var qb = engine.math.quat.normalize(b);
    var dot_value = qa[0] * qb[0] + qa[1] * qb[1] + qa[2] * qb[2] + qa[3] * qb[3];

    if (dot_value < 0.0) {
        qb = .{ -qb[0], -qb[1], -qb[2], -qb[3] };
        dot_value = -dot_value;
    }

    if (dot_value > 0.9995) {
        qa = .{
            std.math.lerp(qa[0], qb[0], t),
            std.math.lerp(qa[1], qb[1], t),
            std.math.lerp(qa[2], qb[2], t),
            std.math.lerp(qa[3], qb[3], t),
        };
        return engine.math.quat.normalize(qa);
    }

    const theta_0 = std.math.acos(std.math.clamp(dot_value, -1.0, 1.0));
    const theta = theta_0 * t;
    const sin_theta = std.math.sin(theta);
    const sin_theta_0 = std.math.sin(theta_0);

    const s0 = std.math.cos(theta) - dot_value * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;
    return .{
        qa[0] * s0 + qb[0] * s1,
        qa[1] * s0 + qb[1] * s1,
        qa[2] * s0 + qb[2] * s1,
        qa[3] * s0 + qb[3] * s1,
    };
}

fn syncAnimationSource(layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) !void {
    const selected_entity = layer_context.renderer.selectedEntity();
    editor_state.selected_entity = selected_entity;
    editor_state.selected_graph = null;
    editor_state.selected_runtime = null;

    const entity_id = selected_entity orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };
    const entity = layer_context.world.getEntityConst(entity_id) orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };
    const animator = entity.animator orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };

    if (layer_context.world.animatorGraph(entity_id)) |graph| {
        editor_state.selected_graph = graph;
        if (layer_context.world.animatorGraphInstanceConst(entity_id)) |instance| {
            editor_state.selected_runtime = instance.runtimeClipBlend();
        }
    }

    const desired_clip = if (editor_state.selected_runtime) |runtime|
        runtime.primary.clip_handle
    else
        animator.default_clip_handle;

    try loadSelectedClipIfNeeded(editor_state, layer_context.world.allocator, layer_context, desired_clip);
}

fn clearLoadedClip(editor_state: *AnimationEditorState, allocator: std.mem.Allocator) void {
    editor_state.selected_clip = null;
    editor_state.selected_graph = null;
    editor_state.selected_runtime = null;
    editor_state.current_time = 0.0;
    editor_state.selected_track = null;
    editor_state.selected_keyframe = null;
    editor_state.clearTracks(allocator);
}

fn loadSelectedClipIfNeeded(
    editor_state: *AnimationEditorState,
    allocator: std.mem.Allocator,
    layer_context: *engine.core.LayerContext,
    clip_handle: ?handles.AnimationClipHandle,
) !void {
    if (editor_state.selected_clip == clip_handle) {
        return;
    }
    if (clip_handle) |handle| {
        const clip = layer_context.world.resources.animationClip(handle) orelse {
            clearLoadedClip(editor_state, allocator);
            return;
        };
        editor_state.selected_clip = handle;
        try editor_state.loadClip(allocator, clip);
        if (editor_state.selected_runtime) |runtime| {
            editor_state.current_time = runtime.primary.sample_time;
        } else {
            editor_state.current_time = 0.0;
        }
        return;
    }
    clearLoadedClip(editor_state, allocator);
}

fn drawGraphRuntimePanel(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) void {
    const selected_entity = editor_state.selected_entity orelse {
        engine.ui.ImGui.textWrapped(localText(state, .no_animator_selected));
        return;
    };
    const entity = layer_context.world.getEntityConst(selected_entity) orelse {
        engine.ui.ImGui.textWrapped(localText(state, .no_animator_selected));
        return;
    };
    if (entity.animator == null) {
        engine.ui.ImGui.textWrapped(localText(state, .no_animator_selected));
        return;
    }

    engine.ui.ImGui.text(localText(state, .animation_graph));
    engine.ui.ImGui.separator();

    const graph = editor_state.selected_graph orelse {
        engine.ui.ImGui.textWrapped(localText(state, .no_animation_graph_bound));
        return;
    };

    engine.ui.ImGui.text(localText(state, .bound_graph));
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.pushStyleColor(.text, .{ 0.32, 0.82, 0.58, 1.0 });
    engine.ui.ImGui.text(graph.name);
    engine.ui.ImGui.popStyleColor(1);

    const runtime = editor_state.selected_runtime;
    if (engine.ui.ImGui.collapsingHeader(localText(state, .animation_graph), true)) {
        if (layout.beginInspectorPropertyTable("animation_graph_runtime_summary", 0.34)) {
            defer layout.endInspectorPropertyTable();

            layout.drawInspectorPropertyRow(localText(state, .current_state), null);
            drawRuntimeStateName(graph, if (runtime) |value| value.primary.state_index else null, .{ 0.36, 0.84, 0.60, 1.0 });

            layout.drawInspectorPropertyRow(localText(state, .next_state), null);
            drawRuntimeStateName(
                graph,
                if (runtime) |value| if (value.secondary) |secondary| secondary.state_index else null else null,
                .{ 0.92, 0.74, 0.28, 1.0 },
            );

            layout.drawInspectorPropertyRow(localText(state, .transition_progress), null);
            if (runtime) |value| {
                if (value.secondary != null) {
                    var progress_buffer: [32]u8 = undefined;
                    const progress_text = std.fmt.bufPrint(
                        &progress_buffer,
                        "{d:.0}% ({d:.2}s / {d:.2}s)",
                        .{ value.blend_factor * 100.0, value.transition_time, value.transition_duration },
                    ) catch "-";
                    engine.ui.ImGui.text(progress_text);
                } else {
                    engine.ui.ImGui.text("-");
                }
            } else {
                engine.ui.ImGui.text("-");
            }
        }
    }

    if (engine.ui.ImGui.collapsingHeader(localText(state, .graph_parameters), true)) {
        drawGraphParameterControls(state, layer_context, editor_state, graph);
    }

    if (engine.ui.ImGui.collapsingHeader(localText(state, .graph_transitions), false)) {
        drawGraphTransitionsList(state, editor_state, graph);
    }
}

fn drawRuntimeStateName(
    graph: *const animation_graph_mod.AnimationGraph,
    state_index: ?u32,
    color: [4]f32,
) void {
    if (state_index) |index| {
        if (index < graph.states.items.len) {
            engine.ui.ImGui.pushStyleColor(.text, color);
            defer engine.ui.ImGui.popStyleColor(1);
            engine.ui.ImGui.text(graph.states.items[index].name);
            return;
        }
    }
    engine.ui.ImGui.text("-");
}

fn drawGraphParameterControls(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    if (graph.parameters.items.len == 0) {
        engine.ui.ImGui.textWrapped(localText(state, .no_graph_parameters));
        return;
    }

    const entity_id = editor_state.selected_entity orelse return;
    const instance = layer_context.world.animatorGraphInstance(entity_id) orelse return;
    if (layout.beginInspectorPropertyTable("animation_graph_parameters_table", 0.34)) {
        defer layout.endInspectorPropertyTable();

        for (graph.parameters.items, 0..) |parameter, index| {
            layout.drawInspectorPropertyRow(parameter.name, null);

            var widget_id_buffer: [64]u8 = undefined;
            const widget_id = std.fmt.bufPrint(&widget_id_buffer, "##anim_graph_param_{}", .{index}) catch continue;

            var changed = false;
            switch (instance.parameters.items[index]) {
                .float => |current_value| {
                    var value = current_value;
                    changed = engine.ui.ImGui.dragFloat(widget_id, &value, 0.01, -1000.0, 1000.0);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .float = value }) catch {};
                    }
                },
                .bool => |current_value| {
                    var value = current_value;
                    changed = engine.ui.ImGui.checkbox(widget_id, &value);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .bool = value }) catch {};
                    }
                },
                .int => |current_value| {
                    var value = @as(f32, @floatFromInt(current_value));
                    changed = engine.ui.ImGui.dragFloat(widget_id, &value, 1.0, -1000.0, 1000.0);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .int = @as(i32, @intFromFloat(@round(value))) }) catch {};
                    }
                },
            }

            if (changed) {
                instance.update(0.0);
                syncAnimationSource(layer_context, editor_state) catch |err| {
                    std.log.err("Failed to refresh animation editor after graph parameter edit: {}", .{err});
                };
            }
        }
    }
}

fn drawGraphTransitionsList(
    state: *EditorState,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    if (graph.transitions.items.len == 0) {
        engine.ui.ImGui.textWrapped(localText(state, .no_graph_transitions));
        return;
    }

    const active_transition = if (editor_state.selected_runtime) |runtime|
        if (runtime.secondary) |secondary|
            [2]u32{ runtime.primary.state_index, secondary.state_index }
        else
            null
    else
        null;

    for (graph.transitions.items) |transition| {
        const from_name = if (transition.from_state < graph.states.items.len) graph.states.items[transition.from_state].name else "?";
        const to_name = if (transition.to_state < graph.states.items.len) graph.states.items[transition.to_state].name else "?";
        const is_active = active_transition != null and active_transition.?[0] == transition.from_state and active_transition.?[1] == transition.to_state;

        if (is_active) {
            engine.ui.ImGui.pushStyleColor(.text, .{ 0.92, 0.74, 0.28, 1.0 });
            defer engine.ui.ImGui.popStyleColor(1);
        }

        var transition_buffer: [256]u8 = undefined;
        const transition_text = std.fmt.bufPrint(
            &transition_buffer,
            "{s} -> {s} ({d:.2}s)",
            .{ from_name, to_name, transition.duration },
        ) catch continue;
        engine.ui.ImGui.text(transition_text);
    }
}

fn deleteTrack(editor_state: *AnimationEditorState, allocator: std.mem.Allocator, index: usize) void {
    if (index >= editor_state.tracks.items.len) {
        return;
    }

    const index_u32: u32 = @intCast(index);
    var removed = editor_state.tracks.orderedRemove(index);
    removed.deinit(allocator);

    if (editor_state.selected_track) |selected_track| {
        if (selected_track == index_u32) {
            editor_state.selected_track = null;
            editor_state.selected_keyframe = null;
        } else if (selected_track > index_u32) {
            editor_state.selected_track = selected_track - 1;
        }
    }
}
