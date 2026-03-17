const std = @import("std");
const engine = @import("guava");

const IssueSeverity = enum {
    err,
    warn,
    info,
};

pub const DebugIssue = struct {
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
    entity_id: engine.scene.EntityId = 0,
    suggested_fix: []const u8 = "",
};

const EditorState = @import("../core/state.zig").EditorState;

pub fn analyzeAndDebug(allocator: std.mem.Allocator, layer_context: *engine.core.LayerContext, world: *engine.scene.World, editor_state: *EditorState) !void {
    _ = layer_context;
    var issues = std.ArrayList(DebugIssue).init(allocator);
    defer issues.deinit();

    try analyzeRenderIssues(world, &issues);
    try analyzeSceneIssues(world, &issues);
    try analyzeAssetIssues(world, &issues);
    try analyzeUIIssues(editor_state, &issues);

    if (issues.items.len > 0) {
        try reportIssues(allocator, issues.items);
    } else {
        std.log.info("[AI Debug] No issues detected", .{});
    }
}

fn analyzeRenderIssues(world: *engine.scene.World, issues: *std.ArrayList(DebugIssue)) !void {
    const renderer = world;
    _ = renderer;

    var has_main_light = false;
    for (world.entities.items) |entity| {
        if (entity.light != null) {
            has_main_light = true;
            break;
        }
    }

    if (!has_main_light) {
        try issues.append(.{
            .severity = .warn,
            .code = "no_light",
            .message = "No light source found in scene",
            .suggested_fix = "Add a directional or point light to illuminate the scene",
        });
    }
}

fn analyzeSceneIssues(world: *engine.scene.World, issues: *std.ArrayList(DebugIssue)) !void {
    if (world.primaryCameraEntity() == null) {
        try issues.append(.{
            .severity = .err,
            .code = "no_primary_camera",
            .message = "No primary camera found in scene",
            .suggested_fix = "Add a camera entity and set it as primary for rendering",
        });
    }

    var mesh_count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.mesh != null) mesh_count += 1;
    }

    if (mesh_count == 0 and world.entities.items.len > 0) {
        try issues.append(.{
            .severity = .info,
            .code = "no_meshes",
            .message = "Scene has entities but no meshes",
            .suggested_fix = "Add mesh components or import a model",
        });
    }
}

fn analyzeAssetIssues(world: *engine.scene.World, issues: *std.ArrayList(DebugIssue)) !void {
    _ = issues;
    for (world.entities.items) |entity| {
        if (entity.mesh) |mesh| {
            _ = mesh;
        }
    }
}

fn analyzeUIIssues(editor_state: *EditorState, issues: *std.ArrayList(DebugIssue)) !void {
    if (editor_state.viewport_extent[0] == 0 or editor_state.viewport_extent[1] == 0) {
        try issues.append(.{
            .severity = .warn,
            .code = "viewport_zero_extent",
            .message = "Viewport has zero extent",
            .suggested_fix = "Resize the viewport window",
        });
    }

    if (editor_state.manipulation_entity) |_| {
        if (!editor_state.viewport_hovered) {
            try issues.append(.{
                .severity = .info,
                .code = "selection_outside_viewport",
                .message = "Selected entity may be outside viewport",
                .suggested_fix = "Frame the selected entity or check its transform",
            });
        }
    }
}

fn reportIssues(allocator: std.mem.Allocator, issues: []const DebugIssue) !void {
    _ = allocator;
    var error_count: usize = 0;
    var warn_count: usize = 0;
    var info_count: usize = 0;

    for (issues) |issue| {
        switch (issue.severity) {
            .err => {
                error_count += 1;
                std.log.err("[AI Debug] {s}: {s}", .{ issue.code, issue.message });
            },
            .warn => {
                warn_count += 1;
                std.log.warn("[AI Debug] {s}: {s}", .{ issue.code, issue.message });
            },
            .info => {
                info_count += 1;
                std.log.info("[AI Debug] {s}: {s}", .{ issue.code, issue.message });
            },
        }

        if (issue.suggested_fix.len > 0) {
            std.log.info("  Fix: {s}", .{issue.suggested_fix});
        }
    }

    std.log.info("[AI Debug] Summary: {} errors, {} warnings, {} info", .{ error_count, warn_count, info_count });
}
