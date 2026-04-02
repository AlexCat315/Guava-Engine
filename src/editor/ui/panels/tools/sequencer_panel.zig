const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const layout = @import("../../layout.zig");
const cinematic = engine.cinematic;

// ---------------------------------------------------------------------------
// Sequencer editor state
// ---------------------------------------------------------------------------

pub const SequencerEditorState = struct {
    /// Currently loaded sequence (owned).
    sequence: ?cinematic.Sequence = null,
    /// Playback controller.
    playback: ?cinematic.SequencePlayback = null,

    /// Timeline view parameters.
    timeline_scale: f32 = 80.0, // pixels per second
    timeline_scroll: f32 = 0.0, // horizontal scroll offset in pixels
    current_time: f32 = 0.0,

    /// Selection.
    selected_track: ?u32 = null,

    /// File path of the currently loaded sequence (for save).
    file_path_buffer: [256]u8 = [_]u8{0} ** 256,
    file_path_len: usize = 0,

    /// New sequence name buffer.
    seq_name_buffer: [128]u8 = [_]u8{0} ** 128,

    /// Track-add combo state.
    new_track_kind: u8 = 0, // 0=camera_path, 1=animation, 2=audio, 3=event, 4=property

    /// New track target name.
    new_track_target_buffer: [128]u8 = [_]u8{0} ** 128,

    pub fn deinit(self: *SequencerEditorState, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.sequence) |*seq| seq.deinit();
        self.* = undefined;
    }

    pub fn ensurePlayback(self: *SequencerEditorState) void {
        if (self.sequence) |*seq| {
            if (self.playback == null) {
                self.playback = cinematic.SequencePlayback.init(seq);
            }
        }
    }
};

pub fn createSequencerEditorState(_: std.mem.Allocator) !SequencerEditorState {
    return .{};
}

pub fn destroySequencerEditorState(state: *SequencerEditorState, allocator: std.mem.Allocator) void {
    state.deinit(allocator);
}

// ---------------------------------------------------------------------------
// I18n (panel-local)
// ---------------------------------------------------------------------------

const MessageId = enum {
    sequencer,
    new_sequence,
    load_sequence,
    save_sequence,
    add_track,
    remove_track,
    no_sequence_loaded,
    sequence_name,
    duration,
    fps,
    track_type,
    target_entity,
    play,
    pause,
    stop_playback,
    time,

    const en_us = .{
        .sequencer = "Sequencer",
        .new_sequence = "New Sequence",
        .load_sequence = "Load",
        .save_sequence = "Save",
        .add_track = "Add Track",
        .remove_track = "Remove",
        .no_sequence_loaded = "No sequence loaded. Create a new one or load an existing .guava_sequence file.",
        .sequence_name = "Name",
        .duration = "Duration",
        .fps = "FPS",
        .track_type = "Track Type",
        .target_entity = "Target Entity",
        .play = "Play",
        .pause = "Pause",
        .stop_playback = "Stop",
        .time = "Time",
    };

    const zh_cn = .{
        .sequencer = "序列编辑器",
        .new_sequence = "新建序列",
        .load_sequence = "加载",
        .save_sequence = "保存",
        .add_track = "添加轨道",
        .remove_track = "删除",
        .no_sequence_loaded = "尚未加载序列。请新建或加载 .guava_sequence 文件。",
        .sequence_name = "名称",
        .duration = "时长",
        .fps = "帧率",
        .track_type = "轨道类型",
        .target_entity = "目标实体",
        .play = "播放",
        .pause = "暂停",
        .stop_playback = "停止",
        .time = "时间",
    };
};

fn localText(state: *const EditorState, id: MessageId) []const u8 {
    return switch (state.language) {
        .en_us => switch (id) {
            inline else => |tag| @field(MessageId.en_us, @tagName(tag)),
        },
        .zh_cn => switch (id) {
            inline else => |tag| @field(MessageId.zh_cn, @tagName(tag)),
        },
    };
}

// ---------------------------------------------------------------------------
// Main draw entry
// ---------------------------------------------------------------------------

pub fn drawSequencerWindow(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *SequencerEditorState) !void {
    _ = layer_context;

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .sequencer, "sequencer_panel");
    var open = state.sequencer_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.sequencer_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("sequencer_panel");

    if (!open) return;

    layout.beginSectionBody();
    defer layout.endSectionBody();

    // -- Toolbar row ---
    drawToolbar(state, editor_state);

    gui.separator();

    if (editor_state.sequence == null) {
        gui.textWrapped(localText(state, .no_sequence_loaded));
        return;
    }

    // -- Main area: track list (left) + timeline (right) ---
    {
        const child_visible = gui.beginChild("sequencer_main", -1.0, -48.0, false);
        defer gui.endChild();
        if (child_visible) {
            if (gui.beginTable("sequencer_layout", 2)) {
                gui.tableSetupColumn("TrackList", true, 0.25);
                gui.tableSetupColumn("Timeline", true, 0.75);
                gui.tableNextRow();
                gui.tableNextColumn();
                drawTrackList(state, editor_state);
                gui.tableNextColumn();
                drawTimeline(state, editor_state);
                gui.endTable();
            }
        }
    }

    // -- Playback controls ---
    drawPlaybackControls(state, editor_state);
}

// ---------------------------------------------------------------------------
// Toolbar: New / Load / Save / Sequence properties
// ---------------------------------------------------------------------------

fn drawToolbar(state: *const EditorState, editor_state: *SequencerEditorState) void {
    if (gui.button(localText(state, .new_sequence))) {
        // Create a fresh empty sequence.
        if (editor_state.sequence) |*old| old.deinit();
        editor_state.sequence = cinematic.Sequence.init(std.heap.page_allocator);
        editor_state.playback = null;
        editor_state.selected_track = null;
        editor_state.current_time = 0;
        @memset(editor_state.file_path_buffer[0..], 0);
        editor_state.file_path_len = 0;
    }
    gui.sameLine();

    if (gui.button(localText(state, .load_sequence))) {
        const path = std.mem.sliceTo(&editor_state.file_path_buffer, 0);
        if (path.len > 0) {
            if (cinematic.loadFromPath(std.heap.page_allocator, path)) |loaded| {
                if (editor_state.sequence) |*old| old.deinit();
                editor_state.sequence = loaded;
                editor_state.playback = null;
                editor_state.selected_track = null;
                editor_state.current_time = 0;
            } else |_| {}
        }
    }
    gui.sameLine();

    if (gui.button(localText(state, .save_sequence))) {
        if (editor_state.sequence) |*seq| {
            const path = std.mem.sliceTo(&editor_state.file_path_buffer, 0);
            if (path.len > 0) {
                cinematic.saveToPath(seq, seq.allocator, path) catch {};
            }
        }
    }
    gui.sameLine();

    // File path input
    gui.setNextItemWidth(240.0);
    _ = gui.inputText("##seq_path", &editor_state.file_path_buffer);

    if (editor_state.sequence) |*seq| {
        gui.sameLine();
        gui.setNextItemWidth(100.0);
        _ = gui.inputText("##seq_name", &editor_state.seq_name_buffer);

        gui.sameLine();
        gui.text("FPS:");
        gui.sameLine();
        gui.setNextItemWidth(60.0);
        _ = gui.dragFloat("##seq_fps", &seq.fps, 1.0, 1.0, 240.0);

        gui.sameLine();
        gui.text("Dur:");
        gui.sameLine();
        gui.setNextItemWidth(80.0);
        _ = gui.dragFloat("##seq_dur", &seq.duration, 0.1, 0.0, 3600.0);
    }
}

// ---------------------------------------------------------------------------
// Track list (left column)
// ---------------------------------------------------------------------------

const track_kind_labels = [_][]const u8{ "Camera Path", "Animation", "Audio", "Event", "Property" };

fn drawTrackList(state: *const EditorState, editor_state: *SequencerEditorState) void {
    const seq = &(editor_state.sequence orelse return);

    // Track list child
    {
        const list_visible = gui.beginChild("seq_track_list", -1.0, -32.0, true);
        defer gui.endChild();
        if (list_visible) {
            for (seq.tracks.items, 0..) |t, idx| {
                const selected = editor_state.selected_track != null and editor_state.selected_track.? == idx;
                var label_buf: [192]u8 = undefined;
                const kind_str: []const u8 = switch (t) {
                    .camera_path => "CAM",
                    .animation => "ANIM",
                    .audio => "SFX",
                    .event => "EVT",
                    .property => "PROP",
                };
                const target_name = t.name();
                const label = std.fmt.bufPrint(&label_buf, "[{s}] {s}##track_{d}", .{ kind_str, target_name, idx }) catch continue;
                if (gui.selectable(label, selected, false, -1.0, 22.0)) {
                    editor_state.selected_track = @intCast(idx);
                }
            }
        }
    }

    // Add / remove track row
    gui.setNextItemWidth(80.0);
    {
        const preview = track_kind_labels[editor_state.new_track_kind];
        if (gui.beginCombo("##new_track_kind", preview)) {
            for (track_kind_labels, 0..) |label, i| {
                const selected = editor_state.new_track_kind == @as(u8, @intCast(i));
                if (gui.selectable(label, selected, false, -1.0, 0.0)) {
                    editor_state.new_track_kind = @intCast(i);
                }
            }
            gui.endCombo();
        }
    }
    gui.sameLine();
    gui.setNextItemWidth(80.0);
    _ = gui.inputText("##new_track_target", &editor_state.new_track_target_buffer);
    gui.sameLine();
    if (gui.button(localText(state, .add_track))) {
        const target_slice = std.mem.sliceTo(&editor_state.new_track_target_buffer, 0);
        const alloc = seq.allocator;
        const target = alloc.dupe(u8, target_slice) catch "";
        const track: cinematic.Track = switch (editor_state.new_track_kind) {
            0 => .{ .camera_path = .{ .target = target } },
            1 => .{ .animation = .{ .target = target } },
            2 => .{ .audio = .{ .target = target } },
            3 => .{ .event = .{ .target = target } },
            else => .{ .property = .{ .target = target } },
        };
        seq.addTrack(track) catch {};
    }
    gui.sameLine();
    if (gui.button(localText(state, .remove_track))) {
        if (editor_state.selected_track) |sel| {
            if (sel < seq.tracks.items.len) {
                seq.removeTrack(sel);
                editor_state.selected_track = null;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Timeline (right column) — ruler + track colored bars + playhead
// ---------------------------------------------------------------------------

const track_row_height: f32 = 28.0;
const ruler_height: f32 = 24.0;

/// Map a time value to an x pixel position within the timeline canvas.
fn timeToX(t: f32, editor_state: *const SequencerEditorState) f32 {
    return t * editor_state.timeline_scale - editor_state.timeline_scroll;
}

/// Map an x pixel position back to time.
fn xToTime(x: f32, editor_state: *const SequencerEditorState) f32 {
    return (x + editor_state.timeline_scroll) / editor_state.timeline_scale;
}

fn drawTimeline(state: *const EditorState, editor_state: *SequencerEditorState) void {
    _ = state;
    const seq = &(editor_state.sequence orelse return);

    const avail = gui.getContentRegionAvail();
    const canvas_width = avail.x;
    const canvas_height = avail.y;

    // -- Ruler ---
    {
        const ruler_visible = gui.beginChild("seq_ruler", canvas_width, ruler_height, false);
        defer gui.endChild();
        if (ruler_visible) {
            var draw_list = gui.getWindowDrawList();
            const cursor = gui.cursorScreenPos();
            const gray = gui.getColorU32(.{ 0.6, 0.6, 0.6, 1.0 });

            // Draw time ticks
            const step = computeTickStep(editor_state.timeline_scale);
            var t: f32 = 0.0;
            while (t <= seq.duration + step) : (t += step) {
                const x = cursor[0] + timeToX(t, editor_state);
                if (x < cursor[0] or x > cursor[0] + canvas_width) continue;
                draw_list.addLine(.{ x, cursor[1] + ruler_height - 6 }, .{ x, cursor[1] + ruler_height }, gray, 1.0);

                var tick_buf: [16]u8 = undefined;
                const tick_label = std.fmt.bufPrint(&tick_buf, "{d:.1}s", .{t}) catch continue;
                draw_list.addText(.{ x + 2, cursor[1] }, gray, tick_label);
            }

            // Playhead marker in ruler
            const ph_x = cursor[0] + timeToX(editor_state.current_time, editor_state);
            const red = gui.getColorU32(.{ 1.0, 0.2, 0.2, 1.0 });
            draw_list.addLine(.{ ph_x, cursor[1] }, .{ ph_x, cursor[1] + ruler_height }, red, 2.0);

            // Click on ruler to seek — use isMouseDragging(.left) as click proxy
            if (gui.isWindowHovered() and gui.isMouseDragging(.left)) {
                const mouse_x = gui.mousePos()[0] - cursor[0];
                editor_state.current_time = std.math.clamp(xToTime(mouse_x, editor_state), 0.0, seq.duration);
                if (editor_state.playback) |*pb| pb.seekTo(editor_state.current_time);
            }
        }
    }

    // -- Track rows ---
    {
        const tracks_visible = gui.beginChild("seq_tracks", canvas_width, canvas_height - ruler_height, false);
        defer gui.endChild();
        if (tracks_visible) {
            var draw_list = gui.getWindowDrawList();
            const cursor = gui.cursorScreenPos();

            for (seq.tracks.items, 0..) |track, idx| {
                const y = cursor[1] + @as(f32, @floatFromInt(idx)) * track_row_height;
                if (y > cursor[1] + canvas_height) break;

                const color = trackColor(track);
                drawTrackBar(draw_list, track, cursor[0], y, canvas_width, editor_state, color);

                // Draw keyframe indicators
                drawKeyframeMarkers(draw_list, track, cursor[0], y, editor_state);
            }

            // Draw playhead line across tracks
            const ph_x = cursor[0] + timeToX(editor_state.current_time, editor_state);
            const line_color = gui.getColorU32(.{ 1.0, 0.2, 0.2, 0.8 });
            const total_h = @as(f32, @floatFromInt(seq.tracks.items.len)) * track_row_height;
            draw_list.addLine(.{ ph_x, cursor[1] }, .{ ph_x, cursor[1] + total_h }, line_color, 1.5);
        }
    }

    // Scroll / zoom via mouse
    handleTimelineInput(editor_state, canvas_width);
}

fn computeTickStep(scale: f32) f32 {
    if (scale >= 160) return 0.5;
    if (scale >= 60) return 1.0;
    if (scale >= 20) return 5.0;
    return 10.0;
}

fn trackColor(track: cinematic.Track) [4]f32 {
    return switch (track) {
        .camera_path => .{ 0.3, 0.7, 1.0, 0.8 },
        .animation => .{ 0.3, 0.9, 0.4, 0.8 },
        .audio => .{ 0.9, 0.6, 0.2, 0.8 },
        .event => .{ 0.9, 0.3, 0.9, 0.8 },
        .property => .{ 0.6, 0.6, 0.9, 0.8 },
    };
}

fn drawTrackBar(draw_list: anytype, track: cinematic.Track, origin_x: f32, y: f32, canvas_width: f32, editor_state: *const SequencerEditorState, color: [4]f32) void {
    const bar = trackTimeRange(track);
    const x0 = origin_x + timeToX(bar[0], editor_state);
    const x1 = origin_x + timeToX(bar[1], editor_state);
    const clamped_x0 = @max(x0, origin_x);
    const clamped_x1 = @min(x1, origin_x + canvas_width);
    if (clamped_x1 <= clamped_x0) return;

    draw_list.addRectFilled(
        .{ clamped_x0, y + 2 },
        .{ clamped_x1, y + track_row_height - 2 },
        gui.getColorU32(color),
        3.0,
        0,
    );
}

fn trackTimeRange(t: cinematic.Track) [2]f32 {
    return switch (t) {
        .camera_path => |cp| blk: {
            if (cp.keyframes.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ cp.keyframes.items[0].time, cp.keyframes.items[cp.keyframes.items.len - 1].time };
        },
        .animation => |a| .{ a.start_time, a.end_time },
        .audio => |a| .{ a.start_time, a.end_time },
        .event => |ev| blk: {
            if (ev.events.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ ev.events.items[0].time, ev.events.items[ev.events.items.len - 1].time };
        },
        .property => |p| blk: {
            if (p.keyframes.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ p.keyframes.items[0].time, p.keyframes.items[p.keyframes.items.len - 1].time };
        },
    };
}

fn drawKeyframeMarkers(draw_list: anytype, track: cinematic.Track, origin_x: f32, y: f32, editor_state: *const SequencerEditorState) void {
    const mid_y = y + track_row_height * 0.5;
    const diamond_size: f32 = 4.0;
    const white = gui.getColorU32(.{ 1, 1, 1, 0.9 });

    switch (track) {
        .camera_path => |cp| {
            for (cp.keyframes.items) |kf| {
                const x = origin_x + timeToX(kf.time, editor_state);
                drawDiamond(draw_list, x, mid_y, diamond_size, white);
            }
        },
        .event => |ev| {
            for (ev.events.items) |e| {
                const x = origin_x + timeToX(e.time, editor_state);
                drawDiamond(draw_list, x, mid_y, diamond_size, white);
            }
        },
        .property => |p| {
            for (p.keyframes.items) |kf| {
                const x = origin_x + timeToX(kf.time, editor_state);
                drawDiamond(draw_list, x, mid_y, diamond_size, white);
            }
        },
        else => {},
    }
}

fn drawDiamond(draw_list: anytype, cx: f32, cy: f32, size: f32, color: u32) void {
    // No addQuadFilled available — use a small filled circle as keyframe marker.
    draw_list.addCircleFilled(.{ cx, cy }, size, color, 6);
}

fn handleTimelineInput(editor_state: *SequencerEditorState, canvas_width: f32) void {
    _ = canvas_width;
    if (!gui.isWindowHovered()) return;

    // Middle mouse drag for panning
    if (gui.isMouseDragging(.middle)) {
        const delta = gui.mouseDragDelta(.middle);
        editor_state.timeline_scroll -= delta[0];
        gui.resetMouseDragDelta(.middle);
    }
}

// ---------------------------------------------------------------------------
// Playback controls (bottom bar)
// ---------------------------------------------------------------------------

fn drawPlaybackControls(state: *const EditorState, editor_state: *SequencerEditorState) void {
    const seq = &(editor_state.sequence orelse return);

    editor_state.ensurePlayback();

    if (editor_state.playback) |*pb| {
        // Play / Pause
        const is_playing = pb.state == .playing;
        if (gui.button(if (is_playing) localText(state, .pause) else localText(state, .play))) {
            if (is_playing) {
                pb.pause();
            } else {
                pb.play();
            }
        }
        gui.sameLine();

        // Stop
        if (gui.button(localText(state, .stop_playback))) {
            pb.stop();
            editor_state.current_time = 0;
        }
        gui.sameLine();

        // Time display / scrub
        gui.text(localText(state, .time));
        gui.sameLine();
        gui.setNextItemWidth(120.0);
        if (gui.dragFloat("##seq_time", &editor_state.current_time, 0.01, 0.0, seq.duration)) {
            pb.seekTo(editor_state.current_time);
        }

        gui.sameLine();
        var label_buf: [64]u8 = undefined;
        const frame_label = std.fmt.bufPrint(&label_buf, "Frame: {d:.0} / {d:.0}", .{ editor_state.current_time * seq.fps, seq.duration * seq.fps }) catch "";
        gui.text(frame_label);

        // If playing, advance playback and sync time
        if (pb.state == .playing) {
            // Use a fixed time step for editor preview (assuming ~60fps editor)
            _ = pb.advance(1.0 / 60.0);
            editor_state.current_time = pb.current_time;
        }
    }
}
