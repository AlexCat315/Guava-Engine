const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const EditorState = @import("../core/state.zig").EditorState;
const PlaybackState = @import("../core/state.zig").PlaybackState;
const ui_icons = @import("icons.zig");

fn setPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext, playback_state: PlaybackState) void {
    state.playback_state = playback_state;
    layer_context.playback_controller.setState(playback_state);
}

fn stepPlayback(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.playback_state = .paused;
    layer_context.playback_controller.requestStep();
}

fn drawPlaybackButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    palette: ui_icons.ButtonPalette,
) !bool {
    return ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        20.0,
        .{ 255, 255, 255, 255 },
        palette,
    );
}

pub fn drawToolbarWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = gui.beginWindowFlags(
        "Toolbar###toolbar_panel",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_collapse,
    );
    defer gui.endWindow();

    const content_width = gui.contentRegionAvail()[0];

    gui.pushStyleVarVec2(.item_spacing, .{ 6.0, 6.0 });
    defer gui.popStyleVar(1);

    // Centered playback controls
    const play_button_size: f32 = 28.0;
    const spacing: f32 = 6.0;
    const total_playback_width = play_button_size * 3.0 + spacing * 2.0;
    const center_start = (content_width - total_playback_width) * 0.5;

    gui.dummy(0.0, 1.0);
    gui.sameLineEx(center_start, 0.0);

    // Play button - green background when active
    const is_playing = state.playback_state == .playing;
    const play_palette = if (is_playing) ui_icons.palettes.toolbar_accent else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, "toolbar_play", ui_icons.paths.toolbar.play, play_palette)) {
        setPlaybackState(state, layer_context, .playing);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.run));
    }
    gui.sameLine();

    // Pause button
    const is_paused = state.playback_state == .paused;
    const pause_palette = if (is_paused) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, "toolbar_pause", ui_icons.paths.toolbar.pause, pause_palette)) {
        setPlaybackState(state, layer_context, .paused);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.pause));
    }
    gui.sameLine();

    // Step button
    if (try drawPlaybackButton(state, layer_context, "toolbar_step", ui_icons.paths.toolbar.step, ui_icons.palettes.toolbar_idle)) {
        stepPlayback(state, layer_context);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.step));
    }
}
