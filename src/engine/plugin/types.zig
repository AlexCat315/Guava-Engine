const std = @import("std");

pub const PluginType = enum {
    render_style,
    audio_effect,
    physics_ext,
    terrain_gen,
    ai_behavior,
    ui_extension,
    script_vm,
};

pub const PluginCapability = enum {
    shader,
    compute_pass,
    render_pass,
    audio_processor,
    script_handler,
};

pub const PluginSource = enum {
    builtin,
    user,
    project,
};

pub const PluginLifecycle = enum {
    unloaded,
    loaded,
    enabled,
    load_error,
};

pub const PluginVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn parse(str: []const u8) !PluginVersion {
        var parts = std.mem.splitSequence(u8, str, ".");
        const major = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion) catch return error.InvalidVersion;
        const minor = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion) catch return error.InvalidVersion;
        const patch = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion) catch return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn compatible(self: PluginVersion, other: PluginVersion) bool {
        return self.major == other.major;
    }
};

pub const PluginManifest = struct {
    name: []u8,
    version: PluginVersion,
    plugin_type: PluginType,
    capabilities: []const PluginCapability = &.{},
    source: PluginSource = .user,
    path: []u8 = &.{},

    shaders: []const []const u8 = &.{},
    post_passes: []const []const u8 = &.{},
    dependencies: []const []const u8 = &.{},

    on_load: ?[]const u8 = null,
    on_unload: ?[]const u8 = null,
    on_enable: ?[]const u8 = null,
};

pub const Plugin = struct {
    manifest: PluginManifest,
    path: []u8,
    lifecycle: PluginLifecycle = .unloaded,
};

test "plugin version parsing" {
    const v = try PluginVersion.parse("1.2.3");
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u16, 2), v.minor);
    try std.testing.expectEqual(@as(u16, 3), v.patch);
}

test "plugin version compatible" {
    const v1 = PluginVersion{ .major = 1, .minor = 2, .patch = 0 };
    const v2 = PluginVersion{ .major = 1, .minor = 5, .patch = 0 };
    const v3 = PluginVersion{ .major = 2, .minor = 0, .patch = 0 };

    try std.testing.expect(v1.compatible(v2));
    try std.testing.expect(!v1.compatible(v3));
}
