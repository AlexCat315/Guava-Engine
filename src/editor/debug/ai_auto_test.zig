const std = @import("std");
const engine = @import("guava");

const TestResult = enum {
    passed,
    failed,
    skipped,
    crashed,
};

const TestEntry = struct {
    name: []u8,
    module: []u8,
    result: TestResult,
    message: []u8,
    duration_ns: u64,
};

const TestSuite = struct {
    name: []u8,
    entries: std.ArrayList(TestEntry),
    passed_count: usize = 0,
    failed_count: usize = 0,
    skipped_count: usize = 0,
};

const AutoTestConfig = struct {
    auto_run: bool = false,
    snapshot_on_failure: bool = true,
    max_retries: usize = 3,
    timeout_ms: u64 = 30000,
};

var config: AutoTestConfig = .{};
var current_suite: ?TestSuite = null;
var g_mutex: std.Thread.Mutex = .{};

pub fn setConfig(new_config: AutoTestConfig) void {
    config = new_config;
}

pub fn initTestSuite(name: []u8, allocator: std.mem.Allocator) !*TestSuite {
    const suite = try allocator.create(TestSuite);
    suite.* = .{
        .name = name,
        .entries = std.ArrayList(TestEntry).init(allocator),
    };
    g_mutex.lock();
    current_suite = suite;
    g_mutex.unlock();
    return suite;
}

pub fn recordTestResult(
    name: []u8,
    module: []u8,
    result: TestResult,
    message: []u8,
    duration_ns: u64,
) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    if (current_suite) |suite| {
        suite.entries.append(.{
            .name = name,
            .module = module,
            .result = result,
            .message = message,
            .duration_ns = duration_ns,
        }) catch return;

        switch (result) {
            .passed => suite.passed_count += 1,
            .failed, .crashed => suite.failed_count += 1,
            .skipped => suite.skipped_count += 1,
        }
    }
}

pub fn runAutoTest(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext) !void {
    try std.log.info("Starting auto test run...", .{});

    const ai_snapshot = @import("./ai_snapshot.zig");

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_skipped: usize = 0;

    try runRenderTests(allocator, layer_context, &total_passed, &total_failed, &total_skipped);
    try runSceneTests(allocator, layer_context, &total_passed, &total_failed, &total_skipped);
    try runAssetTests(allocator, layer_context, &total_passed, &total_failed, &total_skipped);

    try std.log.info("Auto test results: {} passed, {} failed, {} skipped", .{
        total_passed,
        total_failed,
        total_skipped,
    });

    if (total_failed > 0 and config.snapshot_on_failure) {
        try std.log.warn("Test failures detected, capturing snapshot...", .{});
        try ai_snapshot.captureAndSaveSnapshot(allocator, layer_context);
    }
}

fn runRenderTests(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext, total_passed: *usize, total_failed: *usize, total_skipped: *usize) !void {
    _ = allocator;
    const renderer = layer_context.renderer;

    if (renderer.frameIndex() == 0) {
        recordTestResult("render_frame_index", "render", .skipped, "Renderer not initialized", 0);
        total_skipped.* += 1;
        return;
    }

    const start_time = std.time.nanoTimestamp();
    const viewport_size = renderer.sceneViewportSize();
    const elapsed = std.time.nanoTimestamp() - start_time;

    if (viewport_size[0] > 0 and viewport_size[1] > 0) {
        recordTestResult("render_viewport_size", "render", .passed, "Viewport size valid", elapsed);
        total_passed.* += 1;
    } else {
        recordTestResult("render_viewport_size", "render", .failed, "Viewport size is zero", elapsed);
        total_failed.* += 1;
    }
}

fn runSceneTests(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext, total_passed: *usize, total_failed: *usize, total_skipped: *usize) !void {
    _ = allocator;
    _ = total_skipped;
    const world = layer_context.world;

    const start_time = std.time.nanoTimestamp();
    _ = world.entities.items.len;
    const elapsed = std.time.nanoTimestamp() - start_time;

    recordTestResult("scene_entity_count", "scene", .passed, "Scene accessible", elapsed);
    total_passed.* += 1;

    const start_time2 = std.time.nanoTimestamp();
    const primary_camera = world.primaryCameraEntity();
    const elapsed2 = std.time.nanoTimestamp() - start_time2;

    if (primary_camera != null) {
        recordTestResult("scene_primary_camera", "scene", .passed, "Primary camera exists", elapsed2);
        total_passed.* += 1;
    } else {
        recordTestResult("scene_primary_camera", "scene", .failed, "No primary camera found", elapsed2);
        total_failed.* += 1;
    }
}

fn runAssetTests(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext, total_passed: *usize, total_failed: *usize, total_skipped: *usize) !void {
    _ = allocator;
    _ = total_failed;
    _ = total_skipped;
    const world = layer_context.world;

    const start_time = std.time.nanoTimestamp();
    _ = world.resources.textures.len + world.resources.meshes.len + world.resources.materials.len;
    const elapsed = std.time.nanoTimestamp() - start_time;

    recordTestResult("asset_resource_count", "assets", .passed, "Resources accessible", elapsed);
    total_passed.* += 1;
}

pub fn exportTestReport(allocator: std.mem.Allocator, dir: []const u8) !void {
    const file_path = try std.path.join(allocator, dir, "test_report.json");
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.print(
        \\{{
        \\  "schema": "guava.ai_debug.test_report",
        \\  "version": 1,
        \\  "timestamp": "{}",
        \\  "summary": {{
        \\    "total_passed": {},
        \\    "total_failed": {},
        \\    "total_skipped": {}
        \\  }},
        \\  "results": [
    , .{
        std.time.timestamp(),
        if (current_suite) |s| s.passed_count else 0,
        if (current_suite) |s| s.failed_count else 0,
        if (current_suite) |s| s.skipped_count else 0,
    });

    if (current_suite) |suite| {
        for (suite.entries.items, 0..) |entry, i| {
            const result_str = switch (entry.result) {
                .passed => "passed",
                .failed => "failed",
                .skipped => "skipped",
                .crashed => "crashed",
            };

            try writer.print(
                \\    {{"name":"{}","module":"{}","result":"{}","message":"{}","duration_ns":{}}}
            , .{
                std.zig.fmtEscapes(entry.name),
                std.zig.fmtEscapes(entry.module),
                result_str,
                std.zig.fmtEscapes(entry.message),
                entry.duration_ns,
            });

            if (i < suite.entries.items.len - 1) {
                try writer.writeByte(',');
            }
            try writer.writeByte('\n');
        }
    }

    try writer.print(
        \\  ]
        \\}}
    , .{});
}
