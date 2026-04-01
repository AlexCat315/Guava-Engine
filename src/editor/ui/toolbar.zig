const engine = @import("guava");
const gui = @import("gui.zig");
const theme = @import("theme.zig");
const EditorState = @import("../core/state.zig").EditorState;
const playback_session = @import("../core/playback_session.zig");
const ui_icons = @import("icons.zig");

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
        theme.Spacing.toolbar_playback_icon_size,
        theme.Spacing.toolbar_playback_white_tint,
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

    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.toolbar_playback_item_spacing, theme.Spacing.toolbar_playback_item_spacing });
    defer gui.popStyleVar(1);

    // Centered playback controls
    const play_button_size: f32 = theme.Spacing.toolbar_playback_button_size;
    const spacing: f32 = theme.Spacing.toolbar_playback_item_spacing;
    const total_playback_width = play_button_size * 3.0 + spacing * 2.0;
    const center_start = (content_width - total_playback_width) * 0.5;

    gui.dummy(0.0, theme.Spacing.toolbar_window_control_height);
    gui.sameLineEx(center_start, 0.0);

    const session_active = state.play_mode_active or state.playback_state != .stopped;
    const is_playing = state.playback_state == .playing;
    const is_paused = state.playback_state == .paused;
    const run_stop_tooltip_id: @import("../i18n/message_id.zig").MessageId = if (session_active) .stop else .run;
    const pause_resume_tooltip_id: @import("../i18n/message_id.zig").MessageId = if (is_paused) .resume_playback else .pause;
    const run_stop_id = if (session_active) "toolbar_stop_toggle" else "toolbar_run_toggle";
    const run_stop_path = if (session_active) ui_icons.paths.toolbar.stop else ui_icons.paths.toolbar.play;
    const run_stop_palette = if (is_playing)
        ui_icons.palettes.toolbar_accent
    else if (session_active)
        ui_icons.palettes.toolbar_active
    else
        ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, run_stop_id, run_stop_path, run_stop_palette)) {
        if (session_active) {
            playback_session.stop(state, layer_context);
        } else {
            try playback_session.play(state, layer_context);
        }
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(run_stop_tooltip_id));
    }
    gui.sameLine();

    const pause_resume_id = if (is_paused) "toolbar_resume" else "toolbar_pause";
    const pause_resume_path = if (is_paused) ui_icons.paths.toolbar.play else ui_icons.paths.toolbar.pause;
    const pause_resume_palette = if (is_paused) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, pause_resume_id, pause_resume_path, pause_resume_palette)) {
        if (is_paused) {
            try playback_session.play(state, layer_context);
        } else {
            playback_session.pause(state, layer_context);
        }
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(pause_resume_tooltip_id));
    }
    gui.sameLine();

    // Step button
    if (try drawPlaybackButton(state, layer_context, "toolbar_step", ui_icons.paths.toolbar.step, ui_icons.palettes.toolbar_idle)) {
        try playback_session.step(state, layer_context);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.step));
    }
}
