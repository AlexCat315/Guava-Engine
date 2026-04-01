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
        const major = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        const minor = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        const patch = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn compatible(self: PluginVersion, other: PluginVersion) bool {
        return self.major == other.major;
    }
};

/// Common shell shared by all plugin types.
/// Type-specific payloads (StylePluginManifest, etc.) are owned by their
/// respective subsystem registries, not embedded here.
///
/// Ownership: All slice fields (.name, .path) are allocator-owned when the
/// manifest is created by `discover()`.  Callers must call `deinit()` to
/// release them.
pub const PluginManifest = struct {
    name: []u8,
    version: PluginVersion,
    plugin_type: PluginType,
    capabilities: []const PluginCapability = &.{},
    source: PluginSource = .user,
    path: []u8 = &.{},
    dependencies: []const []const u8 = &.{},

    on_load: ?[]const u8 = null,
    on_unload: ?[]const u8 = null,
    on_enable: ?[]const u8 = null,

    pub fn deinit(self: *PluginManifest, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.path.len > 0) allocator.free(self.path);
        self.* = undefined;
    }
};

/// Record tracked by PluginRegistry: common manifest + lifecycle + error state.
pub const PluginRecord = struct {
    manifest: PluginManifest,
    lifecycle: PluginLifecycle = .unloaded,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *PluginRecord, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
    }

    pub fn getName(self: *const PluginRecord) []const u8 {
        return self.manifest.name;
    }

    pub fn getVersion(self: *const PluginRecord) PluginVersion {
        return self.manifest.version;
    }

    pub fn getType(self: *const PluginRecord) PluginType {
        return self.manifest.plugin_type;
    }

    pub fn getSource(self: *const PluginRecord) PluginSource {
        return self.manifest.source;
    }

    pub fn isEnabled(self: *const PluginRecord) bool {
        return self.lifecycle == .enabled;
    }

    pub fn hasError(self: *const PluginRecord) bool {
        return self.lifecycle == .load_error;
    }
};

test "plugin version parsing" {
    const v = try PluginVersion.parse("1.2.3");
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u16, 2), v.minor);
    try std.testing.expectEqual(@as(u16, 3), v.patch);
}
