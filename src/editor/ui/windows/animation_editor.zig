const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../../core/state.zig").EditorState;
const utils = @import("../../common/utils.zig");
const history = @import("../../actions/history.zig");
const inspector = @import("inspector.zig");
const ui_icons = @import("../icons.zig");
const layout = @import("../layout.zig");
const animation_graph_mod = engine.animation.animation_graph;
const animation_clip_mod = engine.assets.animation_clip_resource;
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
        interpolation: animation_clip_mod.Interpolation,
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.keyframes.deinit(allocator);
        self.* = undefined;
    }
};

pub const AnimationEditorState = struct {
    selected_clip: ?handles.AnimationClipHandle = null,
    selected_graph: ?*animation_graph_mod.AnimationGraph = null,
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

    pub fn loadClip(self: *@This(), allocator: std.mem.Allocator, clip: *const animation_clip_mod.AnimationClipResource) !void {
        self.clearTracks(allocator);

        for (clip.translation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Translation_{}", .{track.target_entity_index}),
                .type = .translation,
                .target_index = track.target_entity_index,
                .keyframes = std.ArrayList(TimelineTrack.Keyframe).init(allocator),
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(.{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(timeline_track);
        }

        for (clip.rotation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Rotation_{}", .{track.target_entity_index}),
                .type = .rotation,
                .target_index = track.target_entity_index,
                .keyframes = std.ArrayList(TimelineTrack.Keyframe).init(allocator),
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(.{
                    .time = time,
                    .value = .{ .quat = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(timeline_track);
        }

        for (clip.scale_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Scale_{}", .{track.target_entity_index}),
                .type = .scale,
                .target_index = track.target_entity_index,
                .keyframes = std.ArrayList(TimelineTrack.Keyframe).init(allocator),
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(.{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(timeline_track);
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

    layout.beginSectionBody();
    defer layout.endSectionBody();

    if (engine.ui.ImGui.beginChild("animation_editor_main", .{-1, -engine.ui.ImGui.getFrameHeight() - 8}, false, engine.ui.ImGui.WindowFlags.none)) {
        defer engine.ui.ImGui.endChild();

        if (engine.ui.ImGui.beginTable("animation_editor_layout", 2, engine.ui.ImGui.TableFlags.resizable | engine.ui.ImGui.TableFlags.borders_innerV)) {
            defer engine.ui.ImGui.endTable();

            engine.ui.ImGui.tableSetupColumn("Tracks", engine.ui.ImGui.TableColumnFlags.width_stretch, 0.3);
            engine.ui.ImGui.tableSetupColumn("Timeline", engine.ui.ImGui.TableColumnFlags.width_stretch, 0.7);

            engine.ui.ImGui.tableNextRow();
            engine.ui.ImGui.tableNextColumn();

            drawTrackList(state, editor_state, layer_context);

            engine.ui.ImGui.tableNextColumn();

            drawTimeline(state, editor_state, layer_context);
        }
    }

    drawTimelineControls(state, editor_state, layer_context);
}

fn drawTrackList(state: *EditorState, editor_state: *AnimationEditorState, _: *engine.core.LayerContext) void {
    engine.ui.ImGui.text(state.text(.animation_tracks));
    engine.ui.ImGui.separator();

    if (engine.ui.ImGui.beginChild("track_list", .{-1, -1}, false, engine.ui.ImGui.WindowFlags.none)) {
        defer engine.ui.ImGui.endChild();

        for (editor_state.tracks.items, 0..) |track, index| {
            const is_selected = editor_state.selected_track == @as(u32, @intCast(index));
            
            var track_label: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&track_label, "{s}##track_{}", .{ track.name, index }) catch continue;

            if (engine.ui.ImGui.selectableEx(label, is_selected, engine.ui.ImGui.SelectableFlags.none, .{-1, 22})) {
                editor_state.selected_track = @intCast(index);
            }

            if (engine.ui.ImGui.beginPopupContextItem()) {
                defer engine.ui.ImGui.endPopup();

                if (engine.ui.ImGui.menuItem(state.text(.delete_track), null, false, true)) {
                    // TODO: Implement track deletion
                }
            }
        }

        if (editor_state.tracks.items.len == 0) {
            engine.ui.ImGui.textWrapped(state.text(.no_animation_tracks_loaded));
        }
    }
}

fn drawTimeline(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    engine.ui.ImGui.text(state.text(.animation_timeline));
    engine.ui.ImGui.separator();

    const clip = if (editor_state.selected_clip) |clip_handle|
        layer_context.world.resources.animationClip(clip_handle)
    else
        null;

    const duration = clip orelse 1.0;
    const pixels_per_second = 50.0 * editor_state.timeline_scale;

    if (engine.ui.ImGui.beginChild("timeline_area", .{-1, -1}, true, engine.ui.ImGui.WindowFlags.none)) {
        defer engine.ui.ImGui.endChild();

        const content_height = engine.ui.ImGui.contentRegionAvail()[1];
        const track_height = 24.0;
        const max_tracks = @max(1, @min(editor_state.tracks.items.len, @as(usize, @intFromFloat(content_height / track_height))));

        if (engine.ui.ImGui.beginChild("timeline_ruler", .{-1, 24}, false, engine.ui.ImGui.WindowFlags.none)) {
            defer engine.ui.ImGui.endChild();

            const canvas_width = engine.ui.ImGui.contentRegionAvail()[0];

            var draw_list = engine.ui.ImGui.getWindowDrawList();
            const cursor_pos = engine.ui.ImGui.cursorScreenPos();

            const major_tick_height = 12.0;
            const minor_tick_height = 6.0;
            const time_interval = if (pixels_per_second > 30.0) 0.1 else if (pixels_per_second > 10.0) 0.5 else 1.0;

            var time: f32 = 0.0;
            while (time <= duration) : (time += time_interval) {
                const x = cursor_pos[0] + time * pixels_per_second - editor_state.timeline_offset;
                if (x >= cursor_pos[0] and x <= cursor_pos[0] + canvas_width) {
                    const is_major = @abs(@mod(time, 1.0)) < 0.01 or time == 0.0;
                    const tick_height = if (is_major) major_tick_height else minor_tick_height;
                    
                    draw_list.addLine(
                        .{ x, cursor_pos[1] + 2 },
                        .{ x, cursor_pos[1] + tick_height },
                        engine.ui.ImGui.colorConvertFloat4ToU32(.{ 0.7, 0.7, 0.7, 1.0 }),
                        1.0
                    );

                    if (is_major and time < duration) {
                        var time_label: [16]u8 = undefined;
                        const label = std.fmt.bufPrint(&time_label, "{d:.1}s", .{time}) catch continue;
                        draw_list.addText(.{ x + 2, cursor_pos[1] + 2 }, 
                            engine.ui.ImGui.colorConvertFloat4ToU32(.{ 0.8, 0.8, 0.8, 1.0 }), 
                            label);
                    }
                }
            }

            const current_time_x = cursor_pos[0] + editor_state.current_time * pixels_per_second - editor_state.timeline_offset;
            if (current_time_x >= cursor_pos[0] and current_time_x <= cursor_pos[0] + canvas_width) {
                draw_list.addLine(
                    .{ current_time_x, cursor_pos[1] },
                    .{ current_time_x, cursor_pos[1] + 22 },
                    engine.ui.ImGui.colorConvertFloat4ToU32(.{ 0.9, 0.3, 0.3, 1.0 }),
                    2.0
                );
            }
        }

        if (engine.ui.ImGui.beginChild("timeline_tracks", .{-1, -1}, false, engine.ui.ImGui.WindowFlags.none)) {
            defer engine.ui.ImGui.endChild();

            for (editor_state.tracks.items, 0..) |track, track_index| {
                if (track_index >= max_tracks) break;

                engine.ui.ImGui.pushID(@as(i32, @intCast(track_index)));
                defer engine.ui.ImGui.popID();

                if (engine.ui.ImGui.beginChild("track", .{-1, track_height}, true, engine.ui.ImGui.WindowFlags.none)) {
                    defer engine.ui.ImGui.endChild();

                    const cursor_pos = engine.ui.ImGui.cursorScreenPos();
                    const canvas_width = engine.ui.ImGui.contentRegionAvail()[0];
                    var draw_list = engine.ui.ImGui.getWindowDrawList();

                    draw_list.addRectFilled(
                        cursor_pos,
                        .{ cursor_pos[0] + canvas_width, cursor_pos[1] + track_height },
                        engine.ui.ImGui.colorConvertFloat4ToU32(.{ 0.15, 0.15, 0.15, 1.0 }),
                        0,
                        0
                    );

                    for (track.keyframes.items) |keyframe| {
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
                                engine.ui.ImGui.colorConvertFloat4ToU32(keyframe_color),
                                8
                            );

                            if (i == 0) {
                                draw_list.addLine(
                                    .{ cursor_pos[0], cursor_pos[1] + track_height * 0.5 },
                                    .{ x, cursor_pos[1] + track_height * 0.5 },
                                    engine.ui.ImGui.colorConvertFloat4ToU32(keyframe_color),
                                    1.0
                                );
                            }

                            if (i < track.keyframes.items.len - 1) {
                                const next_keyframe = track.keyframes.items[i + 1];
                                const next_x = cursor_pos[0] + next_keyframe.time * pixels_per_second - editor_state.timeline_offset;
                                
                                if (next_x >= cursor_pos[0] and next_x <= cursor_pos[0] + canvas_width) {
                                    draw_list.addLine(
                                        .{ x, cursor_pos[1] + track_height * 0.5 },
                                        .{ next_x, cursor_pos[1] + track_height * 0.5 },
                                        engine.ui.ImGui.colorConvertFloat4ToU32(keyframe_color),
                                        1.0
                                    );
                                }
                            }
                        }
                    }

                    engine.ui.ImGui.setCursorScreenPos(.{ cursor_pos[0] + 4, cursor_pos[1] + 2 });
                    engine.ui.ImGui.text(track.name);
                }
            }
        }
    }
}

fn drawTimelineControls(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    if (engine.ui.ImGui.button(state.text(.play_pause))) {
        editor_state.is_playing = !editor_state.is_playing;
    }
    
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.stop))) {
        editor_state.is_playing = false;
        editor_state.current_time = 0.0;
    }
    
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(100.0);
    _ = engine.ui.ImGui.dragFloat("##current_time", &editor_state.current_time, 0.01, 0.0, 100.0, "%.2f");
    
    engine.ui.ImGui.sameLine();
    engine.ui.ImGui.setNextItemWidth(100.0);
    _ = engine.ui.ImGui.dragFloat("##timeline_scale", &editor_state.timeline_scale, 0.01, 0.1, 10.0, "Scale: %.2fx");
    
    engine.ui.ImGui.sameLine();
    if (engine.ui.ImGui.button(state.text(.load_clip))) {
        if (layer_context.renderer.selectedEntity()) |entity_id| {
            const entity = layer_context.world.getEntity(entity_id) orelse return;
            if (entity.animator) |animator| {
                if (animator.default_clip_handle) |clip_handle| {
                    editor_state.selected_clip = clip_handle;
                    if (layer_context.world.resources.animationClip(clip_handle)) |clip| {
                        editor_state.loadClip(layer_context.world.allocator orelse std.heap.page_allocator, clip) catch |err| {
                            std.log.err("Failed to load animation clip: {}", .{err});
                        };
                    }
                }
            }
        }
    }
}

pub fn createAnimationEditorState(allocator: std.mem.Allocator) !AnimationEditorState {
    return AnimationEditorState{
        .tracks = std.ArrayList(TimelineTrack).init(allocator),
    };
}

pub fn destroyAnimationEditorState(editor_state: *AnimationEditorState, allocator: std.mem.Allocator) void {
    editor_state.deinit(allocator);
}

const i = @import("../../i18n/message_id.zig");

pub const MessageId = enum(u32) {
    animation_editor = i.text_common_end,
    animation_tracks,
    animation_timeline,
    play_pause,
    stop,
    load_clip,
    no_animation_tracks_loaded,
    delete_track,

    pub const en_us = .{
        .animation_editor = "Animation Editor",
        .animation_tracks = "Animation Tracks",
        .animation_timeline = "Timeline",
        .play_pause = "Play/Pause",
        .stop = "Stop",
        .load_clip = "Load Selected Clip",
        .no_animation_tracks_loaded = "No animation tracks loaded. Select an entity with an Animator component.",
        .delete_track = "Delete Track",
    };

    pub const zh_cn = .{
        .animation_editor = "动画编辑器",
        .animation_tracks = "动画轨道",
        .animation_timeline = "时间轴",
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
