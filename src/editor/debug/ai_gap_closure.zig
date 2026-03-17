const std = @import("std");
const engine = @import("guava");

const PlanPhase = enum {
    p0_acceptance_baseline,
    p1_runtime_data_layer,
    p2_scene_extraction,
    p3_async_assets,
    p4_material_system,
    p5_ibl_skybox,
    p6_shadow_system,
    p7_culling_bvh,
    p8_animation,
    p9_physics,
    p10_scripting,
};

const PhaseStatus = enum {
    not_started,
    in_progress,
    completed,
    blocked,
};

const PhaseInfo = struct {
    phase: PlanPhase,
    name: []u8,
    description: []u8,
    status: PhaseStatus,
    dependencies: []const PlanPhase,
    tasks: std.ArrayList([]u8),
};

const GapClosurePlanner = struct {
    allocator: std.mem.Allocator,
    phases: std.ArrayList(PhaseInfo),
    current_phase: PlanPhase = .p2_scene_extraction,

    pub fn init(allocator: std.mem.Allocator) GapClosurePlanner {
        return .{
            .allocator = allocator,
            .phases = std.ArrayList(PhaseInfo).init(allocator),
        };
    }

    pub fn deinit(self: *GapClosurePlanner) void {
        for (self.phases.items) |*phase| {
            phase.tasks.deinit();
        }
        self.phases.deinit();
    }

    pub fn initializeDefaultPhases(self: *GapClosurePlanner) !void {
        try self.phases.append(.{
            .phase = .p0_acceptance_baseline,
            .name = "P0: Acceptance Baseline & Regression Skeleton",
            .description = "Establish baseline scenarios and regression paths",
            .status = .not_started,
            .dependencies = &.{},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p1_runtime_data_layer,
            .name = "P1: Runtime Data Layer Refactoring",
            .description = "Upgrade Transform to translation+quaternion+scale, add world transform cache",
            .status = .not_started,
            .dependencies = &.{.p0_acceptance_baseline},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p2_scene_extraction,
            .name = "P2: Scene Extraction & Render Data Model Refactoring",
            .description = "Separate Scene/WWorld edit data from Render submission data",
            .status = .not_started,
            .dependencies = &.{.p1_runtime_data_layer},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p3_async_assets,
            .name = "P3: Async Asset Pipeline & GPU Upload",
            .description = "Move asset import and decoding to background threads",
            .status = .not_started,
            .dependencies = &.{.p2_scene_extraction},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p4_material_system,
            .name = "P4: Material System 2.0 & Real PBR Baseline",
            .description = "Complete PBR with normal, metallic_roughness, AO, emissive",
            .status = .not_started,
            .dependencies = &.{.p3_async_assets},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p5_ibl_skybox,
            .name = "P5: IBL, Skybox, HDR & Post-Processing",
            .description = "Environment mapping, skybox, HDR rendering, bloom, tonemapping",
            .status = .not_started,
            .dependencies = &.{.p4_material_system},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p6_shadow_system,
            .name = "P6: Shadow System",
            .description = "Directional light shadows, CSM, shadow debugging",
            .status = .not_started,
            .dependencies = &.{.p5_ibl_skybox},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p7_culling_bvh,
            .name = "P7: Culling, BVH & Raycast Refactoring",
            .description = "Frustum culling, static BVH, broad phase + narrow phase raycast",
            .status = .not_started,
            .dependencies = &.{.p4_material_system},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p8_animation,
            .name = "P8: Animation System MVP",
            .description = "Skeleton, skin, animation clips, basic blending",
            .status = .not_started,
            .dependencies = &.{ .p1_runtime_data_layer, .p2_scene_extraction },
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p9_physics,
            .name = "P9: Physics System MVP",
            .description = "Rigidbody, colliders, fixed timestep, Jolt integration",
            .status = .not_started,
            .dependencies = &.{.p1_runtime_data_layer},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });

        try self.phases.append(.{
            .phase = .p10_scripting,
            .name = "P10: Script & Gameplay MVP",
            .description = "Script component, lifecycle hooks, hot reload",
            .status = .not_started,
            .dependencies = &.{.p9_physics},
            .tasks = std.ArrayList([]u8).init(self.allocator),
        });
    }

    pub fn getCurrentPhase(self: *const GapClosurePlanner) ?*const PhaseInfo {
        for (self.phases.items) |*phase| {
            if (phase.phase == self.current_phase) {
                return phase;
            }
        }
        return null;
    }

    pub fn canStartPhase(self: *const GapClosurePlanner, phase: PlanPhase) bool {
        for (self.phases.items) |*p| {
            if (p.phase == phase and p.status == .not_started) {
                for (p.dependencies) |dep| {
                    var found = false;
                    for (self.phases.items) |*dep_phase| {
                        if (dep_phase.phase == dep and dep_phase.status == .completed) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            }
        }
        return false;
    }

    pub fn advanceToNextPhase(self: *GapClosurePlanner) void {
        var found_current = false;
        for (self.phases.items) |*phase| {
            if (found_current and phase.status == .not_started and self.canStartPhase(phase.phase)) {
                self.current_phase = phase.phase;
                phase.status = .in_progress;
                return;
            }
            if (phase.phase == self.current_phase) {
                phase.status = .completed;
                found_current = true;
            }
        }
    }

    pub fn exportPlanReport(self: *const GapClosurePlanner, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.print(
            \\{{
            \\  "schema": "guava.ai_debug.gap_closure_plan",
            \\  "version": 1,
            \\  "current_phase": "{}",
            \\  "phases": [
        , .{
            @tagName(self.current_phase),
        });

        for (self.phases.items, 0..) |phase, i| {
            try writer.print(
                \\    {{"phase":"{}","name":"{}","status":"{}"}}
            , .{
                @tagName(phase.phase),
                phase.name,
                @tagName(phase.status),
            });
            if (i < self.phases.items.len - 1) {
                try writer.writeByte(',');
            }
            try writer.writeByte('\n');
        }

        try writer.writeAll("  ]\n}\n");

        return buffer.toOwnedSlice();
    }
};

var global_planner: ?GapClosurePlanner = null;

pub fn initGlobalPlanner(allocator: std.mem.Allocator) !void {
    global_planner = GapClosurePlanner.init(allocator);
    try global_planner.?.initializeDefaultPhases();
}

pub fn deinitGlobalPlanner() void {
    if (global_planner) |*planner| {
        planner.deinit();
    }
    global_planner = null;
}

pub fn getGlobalPlanner() ?*GapClosurePlanner {
    return if (global_planner) |*p| p else null;
}

pub fn runAutoPhaseAdvancement(allocator: std.mem.Allocator) !void {
    if (global_planner) |*planner| {
        if (planner.canStartPhase(planner.current_phase)) {
            std.log.info("Advancing to next phase: {}", .{@tagName(planner.current_phase)});
            planner.advanceToNextPhase();

            const report = try planner.exportPlanReport(allocator);
            defer allocator.free(report);
            std.log.info("Gap Closure Plan Report:\n{s}", .{report});
        }
    }
}
