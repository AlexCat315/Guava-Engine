const std = @import("std");
const engine = @import("guava");

const EditorState = @import("../core/state.zig").EditorState;

const SnapshotConfig = struct {
    output_dir: []const u8 = "dist/ai_debug",
    auto_capture: bool = true,
    capture_interval_frames: usize = 300,
};

var config: SnapshotConfig = .{};
var frame_counter: usize = 0;

pub fn setConfig(new_config: SnapshotConfig) void {
    config = new_config;
}

pub fn shouldAutoCapture() bool {
    if (!config.auto_capture) return false;
    if (config.capture_interval_frames == 0) return true;
    frame_counter += 1;
    return frame_counter >= config.capture_interval_frames;
}

pub fn resetFrameCounter() void {
    frame_counter = 0;
}

pub fn captureAndSaveSnapshot(allocator: std.mem.Allocator, editor_st: *EditorState, layer_context: *engine.core.LayerContext) anyerror!void {
    const timestamp_val = std.time.timestamp();
    const ts: u64 = @intCast(timestamp_val);
    const year: u64 = 1970 + ts / 31536000;
    const remaining: u64 = ts % 31536000;
    const day: u64 = remaining / 86400;
    const hour: u64 = (remaining % 86400) / 3600;
    const min: u64 = (remaining % 3600) / 60;
    const sec: u64 = remaining % 60;

    const timestamp_str = try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}Z", .{
        year,
        (day / 30) + 1,
        (day % 30) + 1,
        hour,
        min,
        sec,
    });
    defer allocator.free(timestamp_str);

    const full_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.output_dir, timestamp_str });
    defer allocator.free(full_dir);

    std.fs.cwd().makeDir(config.output_dir) catch {};
    std.fs.cwd().makeDir(full_dir) catch {};

    try writeManifest(full_dir, timestamp_str, layer_context);
    try exportWorldState(full_dir);
    try exportSelectionState(full_dir, editor_st);
    try exportIntegrityReport(full_dir, layer_context.world, editor_st);
    try exportGapClosureStatus(full_dir);

    std.log.info("[AI Bridge] Snapshot: {s}", .{full_dir});
}

fn writeManifest(dir: []const u8, timestamp_str: []const u8, layer_context: *engine.core.LayerContext) anyerror!void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/manifest.json", .{dir});
    defer std.heap.page_allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const window = layer_context.window;
    const world = layer_context.world;

    const content = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"schema":"guava.ai_debug.manifest","version":1,"captured_at_utc":"{s}","runtime":{{"platform":"macos","graphics_api":"vulkan","window_logical_size":[{},{}],"window_drawable_size":[{},{}],"entity_count":{},"frame_index":{}}}}}
    , .{
        timestamp_str,
        window.logical_width,
        window.logical_height,
        window.drawable_width,
        window.drawable_height,
        world.entities.items.len,
        layer_context.frame_index,
    });
    defer std.heap.page_allocator.free(content);

    try file.writeAll(content);
}

fn exportWorldState(dir: []const u8) anyerror!void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/world.json", .{dir});
    defer std.heap.page_allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const content = "{\"schema\":\"guava.ai_debug.world\",\"version\":1}";
    try file.writeAll(content);
}

fn exportSelectionState(dir: []const u8, editor_state: *EditorState) anyerror!void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/selection.json", .{dir});
    defer std.heap.page_allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const primary = editor_state.manipulation_entity;
    const content = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"schema":"guava.ai_debug.selection","version":1,"primary_selection":{}}}
    , .{
        if (primary) |p| p else 0,
    });
    defer std.heap.page_allocator.free(content);

    try file.writeAll(content);
}

fn exportIntegrityReport(dir: []const u8, world: *engine.scene.World, editor_state: *EditorState) anyerror!void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/integrity_report.json", .{dir});
    defer std.heap.page_allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const has_camera = world.primaryCameraEntity() != null;
    const has_issues = editor_state.viewport_extent[0] == 0 or editor_state.viewport_extent[1] == 0;

    const content = try std.fmt.allocPrint(std.heap.page_allocator,
        \\{{"schema":"guava.ai_debug.integrity_report","version":1,"primary_camera_exists":{},"viewport_ok":{}}}
    , .{
        has_camera,
        !has_issues,
    });
    defer std.heap.page_allocator.free(content);

    try file.writeAll(content);
}

fn exportGapClosureStatus(dir: []const u8) anyerror!void {
    const file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/gap_closure_status.json", .{dir});
    defer std.heap.page_allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    const content = "{\"schema\":\"guava.ai_debug.gap_closure_status\",\"version\":1,\"current_phase\":\"p2_scene_extraction\",\"status\":\"in_progress\"}";
    try file.writeAll(content);
}
