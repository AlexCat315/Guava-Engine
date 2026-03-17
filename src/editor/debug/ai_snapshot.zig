const std = @import("std");
const engine = @import("guava");
const fs = std.fs;
const path = std.path;

pub fn captureAndSaveSnapshot(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext) anyerror!void {
    // Create a timestamped directory for the snapshot
    var timestamp_buf: [64]u8 = undefined;
    const timestamp = try std.time.nowMillis();
    const timestamp_str = try std.fmt.bufPrintAlloc(allocator, "d", .{timestamp}) catch return error.OutOfMemory;
    defer allocator.free(timestamp_str);

    const snapshot_dir = try allocator.dupe(u8, "dist/ai_debug/");
    defer allocator.free(snapshot_dir);
    const full_dir = try path.join(allocator, snapshot_dir, timestamp_str);
    defer allocator.free(full_dir);

    // Create the directory
    try fs.cwd().createDirRecursive(full_dir, .{});

    // Create manifest.json
    const manifest_file = try path.join(allocator, full_dir, "manifest.json");
    defer allocator.free(manifest_file);
    try writeManifest(allocator, manifest_file, timestamp, layer_context);

    // Export world state
    const world_file = try path.join(allocator, full_dir, "world.json");
    defer allocator.free(world_file);
    try exportWorldState(allocator, world_file, layer_context);

    // Export selection state
    const selection_file = try path.join(allocator, full_dir, "selection.json");
    defer allocator.free(selection_file);
    try exportSelectionState(allocator, selection_file, layer_context);

    // Export viewport state
    const viewport_file = try path.join(allocator, full_dir, "viewport_state.json");
    defer allocator.free(viewport_file);
    try exportViewportState(allocator, viewport_file, layer_context);

    // Export window state
    const window_file = try path.join(allocator, full_dir, "window_state.json");
    defer allocator.free(window_file);
    try exportWindowState(allocator, window_file, layer_context);

    // Export render graph and frame report (reuse existing exports)
    const render_graph_file = try path.join(allocator, full_dir, "render_graph.json");
    defer allocator.free(render_graph_file);
    try exportRenderGraph(allocator, render_graph_file, layer_context);

    const frame_report_file = try path.join(allocator, full_dir, "frame_report.json");
    defer allocator.free(frame_report_file);
    try exportFrameReport(allocator, frame_report_file, layer_context);

    // Export render state
    const render_state_file = try path.join(allocator, full_dir, "render_state.json");
    defer allocator.free(render_state_file);
    try exportRenderState(allocator, render_state_file, layer_context);

    // Export console logs
    const console_file = try path.join(allocator, full_dir, "console.jsonl");
    defer allocator.free(console_file);
    try exportConsoleLogs(allocator, console_file, layer_context);

    // Export integrity report
    const integrity_file = try path.join(allocator, full_dir, "integrity_report.json");
    defer allocator.free(integrity_file);
    try exportIntegrityReport(allocator, integrity_file, layer_context);

    // TODO: Export UI windows and items (phase 2)
    // TODO: Export viewport image (phase 2)

    _ = try std.log.info("AI Debug snapshot saved to: {s}", .{full_dir});
}

fn writeManifest(allocator: std.mem.Allocator, file: []u8, timestamp: u64, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    const utc_time = try std.time.fromMillis(timestamp);
    const utc_str = try std.time.formatAlloc(allocator, "%Y-%m-%dT%H:%M:%SZ", .{utc_time}) catch return error.OutOfMemory;
    defer allocator.free(utc_str);

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.manifest\"," +
        "  \"version\": 1," +
        "  \"captured_at_utc\": \"{s}\"," +
        "  \"trigger\": {" +
        "    \"kind\": \"manual_hotkey\"," +
        "    \"reason\": \"manual_capture\"" +
        "  }," +
        "  \"build\": {" +
        "    \"git_commit\": \"unknown\"," +
        "    \"git_branch\": \"unknown\"," +
        "    \"config\": \"debug\"" +
        "  }," +
        "  \"runtime\": {" +
        "    \"platform\": \"{s}\"," +
        "    \"graphics_api\": \"{s}\"," +
        "    \"window_logical_size\": [{d}, {d}]," +
        "    \"window_drawable_size\": [{d}, {d}]," +
        "    \"frame_index\": {d}" +
        "  }," +
        "  \"entry_files\": {" +
        "    \"world\": \"world.json\"," +
        "    \"selection\": \"selection.json\"," +
        "    \"viewport_state\": \"viewport_state.json\"," +
        "    \"window_state\": \"window_state.json\"," +
        "    \"render_graph\": \"render_graph.json\"," +
        "    \"frame_report\": \"frame_report.json\"," +
        "    \"render_state\": \"render_state.json\"," +
        "    \"console\": \"console.jsonl\"," +
        "    \"integrity_report\": \"integrity_report.json\"" +
        "  }," +
        "  \"capture_capabilities\": {" +
        "    \"full_texture_readback\": false," +
        "    \"ui_item_rects\": false," +
        "    \"command_bridge_enabled\": false" +
        "  }" +
        "\n}}"s,
        .{
            utc_str,
            "unknown", // platform - we should get from layer_context or engine
            "unknown", // graphics_api
            0, 0, // logical size - placeholder
            0, 0, // drawable size - placeholder
            0, // frame index - placeholder
        }
    ) catch |err| {
        return err;
    };
}

// Placeholder implementations for the export functions - to be implemented based on actual engine structures
fn exportWorldState(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.world\"," +
        "  \"version\": 1," +
        "  \"summary\": {" +
        "    \"entity_count\": 0," +
        "    \"mesh_entity_count\": 0," +
        "    \"light_entity_count\": 0," +
        "    \"camera_entity_count\": 0" +
        "  }," +
        "  \"entities\": []" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportSelectionState(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.selection\"," +
        "  \"version\": 1," +
        "  \"primary_selection\": null," +
        "  \"selection_list\": []" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportViewportState(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.viewport_state\"," +
        "  \"version\": 1," +
        "  \"render_mode\": \"unknown\"," +
        "  \"show_grid\": false," +
        "  \"show_bones\": false," +
        "  \"show_collision\": false," +
        "  \"viewport_hovered\": false," +
        "  \"viewport_focused\": false," +
        "  \"viewport_origin\": [0, 0]," +
        "  \"viewport_extent\": [0, 0]," +
        "  \"viewport_has_image\": false," +
        "  \"view_preset\": \"unknown\"" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportWindowState(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.window_state\"," +
        "  \"version\": 1," +
        "  \"logical_size\": [0, 0]," +
        "  \"drawable_size\": [0, 0]," +
        "  \"hidpi\": false," +
        "  \"native_titlebar_controls\": false," +
        "  \"platform\": \"unknown\"" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportRenderGraph(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    // We would reuse the existing render graph export functionality
    // For now, create a placeholder
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.render_graph\"," +
        "  \"version\": 1," +
        "  \"passes\": []" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportFrameReport(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    // We would reuse the existing frame report export functionality
    // For now, create a placeholder
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.frame_report\"," +
        "  \"version\": 1," +
        "  \"frames\": 0," +
        "  \"passes\": 0," +
        "  \"draw_calls\": 0," +
        "  \"triangles_drawn\": 0," +
        "  \"scene\": {" +
        "    \"entity_count\": 0," +
        "    \"mesh_count\": 0," +
        "    \"light_count\": 0" +
        "  }" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportRenderState(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.render_state\"," +
        "  \"version\": 1," +
        "  \"scene_viewport\": {" +
        "    \"active\": false," +
        "    \"width\": 0," +
        "    \"height\": 0," +
        "    \"color_target\": {" +
        "      \"format\": \"unknown\"" +
        "    }," +
        "    \"depth_target\": {" +
        "      \"format\": \"unknown\"" +
        "    }" +
        "  }," +
        "  \"id_pass\": {" +
        "    \"ready\": false," +
        "    \"width\": 0," +
        "    \"height\": 0," +
        "    \"format\": \"unknown\"" +
        "  }," +
        "  \"prepared_scene\": {" +
        "    \"draw_item_count\": 0," +
        "    \"camera_world_position\": [0.0, 0.0, 0.0]," +
        "    \"main_light\": {" +
        "      \"kind\": \"unknown\"," +
        "      \"direction\": [0.0, 0.0, 0.0]" +
        "    }" +
        "  }" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportConsoleLogs(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    // We would get the actual logs from the console system
    // For now, write a placeholder
    try writer.print(
        "{{"s\n" +
        "  \"index\": 0," +
        "  \"level\": \"info\"," +
        "  \"scope\": \"ai_bridge\"," +
        "  \"message\": \"AI Debug Bridge initialized\"" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}

fn exportIntegrityReport(allocator: std.mem.Allocator, file: []u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_handle = try fs.cwd().openFile(file, .{ .write = true, .create = .never });
    defer file_handle.close();
    var writer = file_handle.writer();

    try writer.print(
        "{{"s\n" +
        "  \"schema\": \"guava.ai_debug.integrity_report\"," +
        "  \"version\": 1," +
        "  \"issues\": []" +
        "\n}}"s,
        .{}
    ) catch |err| {
        return err;
    };
}