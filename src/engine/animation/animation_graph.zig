const std = @import("std");
const handles = @import("../assets/handles.zig");
const animation_clip_mod = @import("../assets/animation_clip_resource.zig");

pub const AnimationNodeType = enum {
    state,
    blend_space_1d,
    blend_space_2d,
    layer,
};

pub const AnimationState = struct {
    name: []u8,
    clip_handle: ?handles.AnimationClipHandle,
    speed: f32 = 1.0,
    loop: bool = true,
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const BlendSpacePoint1D = struct {
    position: f32,
    clip_handle: handles.AnimationClipHandle,
};

pub const BlendSpacePoint2D = struct {
    position: [2]f32,
    clip_handle: handles.AnimationClipHandle,
};

pub const BlendSpace1D = struct {
    name: []u8,
    points: []BlendSpacePoint1D,
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.points);
        self.* = undefined;
    }
    
    pub fn sample(self: *const @This(), parameter: f32) ?handles.AnimationClipHandle {
        if (self.points.len == 0) return null;
        if (self.points.len == 1) return self.points[0].clip_handle;
        
        var lower_index: usize = 0;
        var upper_index: usize = 0;
        
        for (self.points, 0..) |point, i| {
            if (parameter >= point.position) {
                lower_index = i;
            }
            if (parameter <= point.position and upper_index == 0) {
                upper_index = i;
            }
        }
        
        if (lower_index == upper_index) {
            return self.points[lower_index].clip_handle;
        }
        
        const lower = self.points[lower_index];
        const upper = self.points[upper_index];
        const t = if (upper.position - lower.position < 0.001) 0.0 else (parameter - lower.position) / (upper.position - lower.position);
        
        return if (t < 0.5) lower.clip_handle else upper.clip_handle;
    }
};

pub const BlendSpace2D = struct {
    name: []u8,
    points: []BlendSpacePoint2D,
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.points);
        self.* = undefined;
    }
    
    pub fn sample(self: *const @This(), parameter: [2]f32) ?handles.AnimationClipHandle {
        if (self.points.len == 0) return null;
        if (self.points.len == 1) return self.points[0].clip_handle;
        
        var closest_index: usize = 0;
        var closest_distance_sq: f32 = std.math.floatMax(f32);
        
        for (self.points, 0..) |point, i| {
            const dx = parameter[0] - point.position[0];
            const dy = parameter[1] - point.position[1];
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq < closest_distance_sq) {
                closest_distance_sq = dist_sq;
                closest_index = i;
            }
        }
        
        return self.points[closest_index].clip_handle;
    }
};

pub const TransitionCondition = union(enum) {
    time_remaining: f32,
    time_elapsed: f32,
    parameter: struct {
        name: []u8,
        value: f32,
        comparison: enum { less, greater, equal },
    },
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .parameter => |*param| {
                allocator.free(param.name);
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub const Transition = struct {
    from_state: u32,
    to_state: u32,
    duration: f32 = 0.2,
    conditions: []TransitionCondition,
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.conditions) |*condition| {
            condition.deinit(allocator);
        }
        allocator.free(self.conditions);
        self.* = undefined;
    }
};

pub const Parameter = struct {
    name: []u8,
    type: enum { float, bool, trigger, int },
    default_value: union(enum) {
        float: f32,
        bool: bool,
        int: i32,
    },
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const AnimationGraph = struct {
    name: []u8,
    states: std.ArrayList(AnimationState),
    blend_spaces_1d: std.ArrayList(BlendSpace1D),
    blend_spaces_2d: std.ArrayList(BlendSpace2D),
    transitions: std.ArrayList(Transition),
    parameters: std.ArrayList(Parameter),
    default_state: ?u32 = null,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !AnimationGraph {
        return .{
            .name = try allocator.dupe(u8, name),
            .states = std.ArrayList(AnimationState).init(allocator),
            .blend_spaces_1d = std.ArrayList(BlendSpace1D).init(allocator),
            .blend_spaces_2d = std.ArrayList(BlendSpace2D).init(allocator),
            .transitions = std.ArrayList(Transition).init(allocator),
            .parameters = std.ArrayList(Parameter).init(allocator),
        };
    }
    
    pub fn deinit(self: *@This()) void {
        const allocator = self.states.allocator;
        
        allocator.free(self.name);
        
        for (self.states.items) |*state| {
            state.deinit(allocator);
        }
        self.states.deinit();
        
        for (self.blend_spaces_1d.items) |*blend_space| {
            blend_space.deinit(allocator);
        }
        self.blend_spaces_1d.deinit();
        
        for (self.blend_spaces_2d.items) |*blend_space| {
            blend_space.deinit(allocator);
        }
        self.blend_spaces_2d.deinit();
        
        for (self.transitions.items) |*transition| {
            transition.deinit(allocator);
        }
        self.transitions.deinit();
        
        for (self.parameters.items) |*parameter| {
            parameter.deinit(allocator);
        }
        self.parameters.deinit();
        
        self.* = undefined;
    }
    
    pub fn addState(self: *@This(), name: []const u8, clip_handle: ?handles.AnimationClipHandle) !u32 {
        const state = AnimationState{
            .name = try self.states.allocator.dupe(u8, name),
            .clip_handle = clip_handle,
            .speed = 1.0,
            .loop = true,
        };
        try self.states.append(state);
        return @as(u32, @intCast(self.states.items.len - 1));
    }
    
    pub fn addBlendSpace1D(self: *@This(), name: []const u8, points: []const BlendSpacePoint1D) !u32 {
        const allocator = self.blend_spaces_1d.allocator;
        
        var owned_points = try allocator.alloc(BlendSpacePoint1D, points.len);
        for (points, 0..) |point, i| {
            owned_points[i] = point;
        }
        
        const blend_space = BlendSpace1D{
            .name = try allocator.dupe(u8, name),
            .points = owned_points,
        };
        
        try self.blend_spaces_1d.append(blend_space);
        return @as(u32, @intCast(self.blend_spaces_1d.items.len - 1));
    }
    
    pub fn addBlendSpace2D(self: *@This(), name: []const u8, points: []const BlendSpacePoint2D) !u32 {
        const allocator = self.blend_spaces_2d.allocator;
        
        var owned_points = try allocator.alloc(BlendSpacePoint2D, points.len);
        for (points, 0..) |point, i| {
            owned_points[i] = point;
        }
        
        const blend_space = BlendSpace2D{
            .name = try allocator.dupe(u8, name),
            .points = owned_points,
        };
        
        try self.blend_spaces_2d.append(blend_space);
        return @as(u32, @intCast(self.blend_spaces_2d.items.len - 1));
    }
    
    pub fn addTransition(self: *@This(), from_state: u32, to_state: u32, duration: f32, conditions: []const TransitionCondition) !void {
        const allocator = self.transitions.allocator;
        
        var owned_conditions = try allocator.alloc(TransitionCondition, conditions.len);
        for (conditions, 0..) |condition, i| {
            owned_conditions[i] = condition;
        }
        
        const transition = Transition{
            .from_state = from_state,
            .to_state = to_state,
            .duration = duration,
            .conditions = owned_conditions,
        };
        
        try self.transitions.append(transition);
    }
    
    pub fn addParameter(self: *@This(), name: []const u8, parameter_type: ParameterType, default_value: anytype) !void {
        const allocator = self.parameters.allocator;
        
        const param = Parameter{
            .name = try allocator.dupe(u8, name),
            .type = parameter_type,
            .default_value = switch (parameter_type) {
                .float => .{ .float = @as(f32, @floatCast(default_value)) },
                .bool => .{ .bool = @as(bool, default_value) },
                .int => .{ .int = @as(i32, @intCast(default_value)) },
                .trigger => .{ .bool = false },
            },
        };
        
        try self.parameters.append(param);
    }
    
    pub fn findState(self: *const @This(), name: []const u8) ?u32 {
        for (self.states.items, 0..) |state, i| {
            if (std.mem.eql(u8, state.name, name)) {
                return @as(u32, @intCast(i));
            }
        }
        return null;
    }
    
    pub fn findParameter(self: *const @This(), name: []const u8) ?u32 {
        for (self.parameters.items, 0..) |param, i| {
            if (std.mem.eql(u8, param.name, name)) {
                return @as(u32, @intCast(i));
            }
        }
        return null;
    }
};

pub const AnimationGraphInstance = struct {
    graph: *const AnimationGraph,
    current_state: u32,
    next_state: ?u32 = null,
    transition_time: f32 = 0.0,
    transition_duration: f32 = 0.0,
    parameters: std.ArrayList(ParameterValue),
    state_time: f32 = 0.0,
    
    pub const ParameterValue = union(enum) {
        float: f32,
        bool: bool,
        int: i32,
    };
    
    pub fn init(allocator: std.mem.Allocator, graph: *const AnimationGraph) !AnimationGraphInstance {
        var parameters = std.ArrayList(ParameterValue).init(allocator);
        try parameters.ensureTotalCapacity(graph.parameters.items.len);
        
        for (graph.parameters.items) |param| {
            switch (param.default_value) {
                .float => |v| try parameters.append(.{ .float = v }),
                .bool => |v| try parameters.append(.{ .bool = v }),
                .int => |v| try parameters.append(.{ .int = v }),
            }
        }
        
        const default_state = graph.default_state orelse 0;
        return .{
            .graph = graph,
            .current_state = default_state,
            .parameters = parameters,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.parameters.deinit();
        self.* = undefined;
    }
    
    pub fn setParameter(self: *@This(), index: u32, value: anytype) void {
        if (index >= self.parameters.items.len) return;
        
        switch (self.parameters.items[index]) {
            .float => self.parameters.items[index] = .{ .float = @as(f32, @floatCast(value)) },
            .bool => self.parameters.items[index] = .{ .bool = @as(bool, value) },
            .int => self.parameters.items[index] = .{ .int = @as(i32, @intCast(value)) },
        }
    }
    
    pub fn update(self: *@This(), delta_time: f32) void {
        if (self.next_state) |_| {
            self.transition_time += delta_time;
            if (self.transition_time >= self.transition_duration) {
                self.current_state = self.next_state.?;
                self.next_state = null;
                self.transition_time = 0.0;
                self.transition_duration = 0.0;
                self.state_time = 0.0;
            }
        } else {
            self.state_time += delta_time;
            
            for (self.graph.transitions.items) |transition| {
                if (transition.from_state != self.current_state) continue;
                
                var all_conditions_met = true;
                for (transition.conditions) |condition| {
                    if (!evaluateCondition(condition, self.parameters.items, self.state_time)) {
                        all_conditions_met = false;
                        break;
                    }
                }
                
                if (all_conditions_met) {
                    self.next_state = transition.to_state;
                    self.transition_time = 0.0;
                    self.transition_duration = transition.duration;
                    break;
                }
            }
        }
    }
    
    pub fn getCurrentClip(self: *const @This()) ?handles.AnimationClipHandle {
        if (self.current_state >= self.graph.states.items.len) return null;
        
        const state = &self.graph.states.items[self.current_state];
        return state.clip_handle;
    }
    
    pub fn getBlendFactor(self: *const @This()) f32 {
        if (self.next_state == null or self.transition_duration <= 0.0) {
            return 0.0;
        }
        return std.math.clamp(self.transition_time / self.transition_duration, 0.0, 1.0);
    }
};

fn evaluateCondition(condition: TransitionCondition, parameters: []const AnimationGraphInstance.ParameterValue, state_time: f32) bool {
    _ = parameters;
    switch (condition) {
        .time_remaining => {
            return false;
        },
        .time_elapsed => |threshold| {
            return state_time >= threshold;
        },
        .parameter => {
            return false;
        },
    }
}

pub const ParameterType = enum { float, bool, trigger, int };

test "AnimationGraph basic state management" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TestGraph");
    defer graph.deinit();
    
    const state1 = try graph.addState("Idle", null);
    const state2 = try graph.addState("Run", null);
    
    try std.testing.expectEqual(@as(u32, 0), state1);
    try std.testing.expectEqual(@as(u32, 1), state2);
    
    const found_state1 = graph.findState("Idle");
    try std.testing.expectEqual(@as(?u32, 0), found_state1);
    
    const not_found = graph.findState("NonExistent");
    try std.testing.expectEqual(@as(?u32, null), not_found);
}

test "AnimationGraphInstance parameter management" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TestGraph");
    defer graph.deinit();
    
    try graph.addParameter("Speed", .float, 0.0);
    try graph.addParameter("IsGrounded", .bool, true);
    try graph.addParameter("Health", .int, 100);
    
    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();
    
    try std.testing.expectEqual(@as(f32, 0.0), instance.parameters.items[0].float);
    try std.testing.expectEqual(true, instance.parameters.items[1].bool);
    try std.testing.expectEqual(@as(i32, 100), instance.parameters.items[2].int);
    
    instance.setParameter(0, 5.5);
    try std.testing.expectEqual(@as(f32, 5.5), instance.parameters.items[0].float);
}

test "BlendSpace1D sampling" {
    const points = [_]BlendSpacePoint1D{
        .{ .position = 0.0, .clip_handle = .{ .index = 0 } },
        .{ .position = 5.0, .clip_handle = .{ .index = 1 } },
        .{ .position = 10.0, .clip_handle = .{ .index = 2 } },
    };
    
    var blend_space = BlendSpace1D{
        .name = "SpeedBlend",
        .points = try std.testing.allocator.dupe(BlendSpacePoint1D, &points),
    };
    defer blend_space.deinit(std.testing.allocator);
    
    const clip0 = blend_space.sample(0.0);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, .{ .index = 0 }), clip0);
    
    const clip5 = blend_space.sample(5.0);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, .{ .index = 1 }), clip5);
    
    const clip2_5 = blend_space.sample(2.5);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, .{ .index = 0 }), clip2_5);
}