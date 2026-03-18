const std = @import("std");
const engine = @import("guava");
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
    _ = engine.ui.ImGui.beginWindowFlags(
        "Toolbar###toolbar_panel",
        engine.ui.ImGui.WindowFlags.no_title_bar |
            engine.ui.ImGui.WindowFlags.no_scrollbar |
            engine.ui.ImGui.WindowFlags.no_resize |
            engine.ui.ImGui.WindowFlags.no_collapse,
    );
    defer engine.ui.ImGui.endWindow();

    const content_width = engine.ui.ImGui.contentRegionAvail()[0];

    engine.ui.ImGui.pushStyleVarVec2(.item_spacing, .{ 6.0, 6.0 });
    defer engine.ui.ImGui.popStyleVar(1);

    // Centered playback controls
    const play_button_size: f32 = 28.0;
    const spacing: f32 = 6.0;
    const total_playback_width = play_button_size * 3.0 + spacing * 2.0;
    const center_start = (content_width - total_playback_width) * 0.5;

    engine.ui.ImGui.dummy(0.0, 1.0);
    engine.ui.ImGui.sameLineEx(center_start, 0.0);

    // Play button - green background when active
    const is_playing = state.playback_state == .playing;
    const play_palette = if (is_playing) ui_icons.palettes.toolbar_accent else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, "toolbar_play", ui_icons.paths.toolbar.play, play_palette)) {
        setPlaybackState(state, layer_context, .playing);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.run));
    }
    engine.ui.ImGui.sameLine();

    // Pause button
    const is_paused = state.playback_state == .paused;
    const pause_palette = if (is_paused) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, "toolbar_pause", ui_icons.paths.toolbar.pause, pause_palette)) {
        setPlaybackState(state, layer_context, .paused);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.pause));
    }
    engine.ui.ImGui.sameLine();

    // Step button
    if (try drawPlaybackButton(state, layer_context, "toolbar_step", ui_icons.paths.toolbar.step, ui_icons.palettes.toolbar_idle)) {
        stepPlayback(state, layer_context);
    }
    if (engine.ui.ImGui.isItemHovered()) {
        engine.ui.ImGui.setTooltip(state.text(.step));
    }
}
