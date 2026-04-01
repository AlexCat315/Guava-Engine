const std = @import("std");
const plugin_types = @import("../plugin/types.zig");

/// Configurable parameter exposed by a render style plugin.
pub const StyleParam = struct {
    name: []const u8,
    display_name: []const u8 = "",
    param_type: ParamType = .float,
    default_value: f32 = 0.0,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,

    pub const ParamType = enum {
        float,
        int,
        boolean,
        color3,
    };
};

/// Manifest describing a render style plugin's capabilities and shaders.
pub const StylePluginManifest = struct {
    name: []const u8,
    display_name: []const u8 = "",
    version: []const u8 = "1.0.0",
    builtin: bool = false,
    /// Shader program name for mesh rendering (from manifest.json)
    mesh_program: []const u8 = "mesh",
    /// Optional override shader program for shadows
    shadow_program: ?[]const u8 = null,
    /// Additional post-process pass names injected by this style
    post_passes: []const []const u8 = &.{},
    /// User-tunable parameters for this style
    config_schema: []const StyleParam = &.{},
    /// Source path for user plugins
    path: ?[]const u8 = null,
};

/// Default PBR render style — maps to the built-in "mesh" shader program.
pub const default_pbr_style = StylePluginManifest{
    .name = "default_pbr",
    .display_name = "PBR (Default)",
    .version = "1.0.0",
    .builtin = true,
    .mesh_program = "mesh",
    .shadow_program = "shadow_pass",
};

/// Registry managing all available render styles and tracking the active one.
pub const StyleRegistry = struct {
    allocator: std.mem.Allocator,
    styles: std.StringHashMap(StylePluginManifest),
    active_style_name: []const u8,

    pub fn init(allocator: std.mem.Allocator) StyleRegistry {
        var registry = StyleRegistry{
            .allocator = allocator,
            .styles = std.StringHashMap(StylePluginManifest).init(allocator),
            .active_style_name = "default_pbr",
        };
        // Always register the default PBR style
        registry.styles.put(default_pbr_style.name, default_pbr_style) catch {};
        return registry;
    }

    pub fn deinit(self: *StyleRegistry) void {
        self.styles.deinit();
    }

    pub fn register(self: *StyleRegistry, manifest: StylePluginManifest) !void {
        if (self.styles.contains(manifest.name)) {
            return error.StyleAlreadyRegistered;
        }
        try self.styles.put(manifest.name, manifest);
    }

    pub fn setActiveStyle(self: *StyleRegistry, name: []const u8) bool {
        if (self.styles.contains(name)) {
            self.active_style_name = name;
            return true;
        }
        return false;
    }

    pub fn getActiveStyle(self: *const StyleRegistry) StylePluginManifest {
        return self.styles.get(self.active_style_name) orelse default_pbr_style;
    }

    pub fn getStyle(self: *const StyleRegistry, name: []const u8) ?StylePluginManifest {
        return self.styles.get(name);
    }

    pub fn styleCount(self: *const StyleRegistry) usize {
        return self.styles.count();
    }

    pub fn styleIterator(self: *const StyleRegistry) std.StringHashMap(StylePluginManifest).Iterator {
        return self.styles.iterator();
    }
};
