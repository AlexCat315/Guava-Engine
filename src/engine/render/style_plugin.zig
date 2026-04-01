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
    /// Built-in passes to disable when this style is active (e.g. bloom, taa)
    disabled_passes: []const []const u8 = &.{},
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

/// Unlit flat-color style — no lighting, just albedo output.
pub const unlit_flat_style = StylePluginManifest{
    .name = "unlit_flat",
    .display_name = "Unlit Flat",
    .version = "1.0.0",
    .builtin = true,
    .mesh_program = "mesh",
    .shadow_program = null,
    .disabled_passes = &.{ "bloom", "ssr" },
    .config_schema = &.{
        .{ .name = "opacity", .display_name = "Opacity", .param_type = .float, .default_value = 1.0, .min_value = 0.0, .max_value = 1.0 },
    },
};

/// Runtime storage for parameter values set by the user for a given style.
pub const StyleParamValues = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(f32),

    pub fn init(allocator: std.mem.Allocator) StyleParamValues {
        return .{ .allocator = allocator, .values = std.StringHashMap(f32).init(allocator) };
    }

    pub fn deinit(self: *StyleParamValues) void {
        self.values.deinit();
    }

    pub fn set(self: *StyleParamValues, name: []const u8, value: f32) !void {
        try self.values.put(name, value);
    }

    pub fn get(self: *const StyleParamValues, name: []const u8, default: f32) f32 {
        return self.values.get(name) orelse default;
    }
};

/// Registry managing all available render styles and tracking the active one.
pub const StyleRegistry = struct {
    allocator: std.mem.Allocator,
    styles: std.StringHashMap(StylePluginManifest),
    active_style_name: []const u8,
    param_values: std.StringHashMap(StyleParamValues),

    pub fn init(allocator: std.mem.Allocator) StyleRegistry {
        var registry = StyleRegistry{
            .allocator = allocator,
            .styles = std.StringHashMap(StylePluginManifest).init(allocator),
            .active_style_name = "default_pbr",
            .param_values = std.StringHashMap(StyleParamValues).init(allocator),
        };
        // Always register the builtin styles
        registry.styles.put(default_pbr_style.name, default_pbr_style) catch {};
        registry.styles.put(unlit_flat_style.name, unlit_flat_style) catch {};
        return registry;
    }

    pub fn deinit(self: *StyleRegistry) void {
        var it = self.param_values.iterator();
        while (it.next()) |entry| {
            var pv = entry.value_ptr.*;
            pv.deinit();
        }
        self.param_values.deinit();
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

    /// Check whether a given built-in pass should be disabled by the active style.
    pub fn isPassDisabledByActiveStyle(self: *const StyleRegistry, pass_name: []const u8) bool {
        const style = self.getActiveStyle();
        for (style.disabled_passes) |disabled| {
            if (std.mem.eql(u8, disabled, pass_name)) return true;
        }
        return false;
    }

    /// Get or create the runtime parameter values for a style.
    pub fn getParamValues(self: *StyleRegistry, style_name: []const u8) !*StyleParamValues {
        const result = try self.param_values.getOrPut(style_name);
        if (!result.found_existing) {
            result.value_ptr.* = StyleParamValues.init(self.allocator);
        }
        return result.value_ptr;
    }

    /// Load a user plugin manifest from a directory path.
    /// Expects `dir_path/manifest.json` with fields: name, display_name, version,
    /// mesh_program, shadow_program, post_passes, disabled_passes.
    pub fn loadUserPlugin(self: *StyleRegistry, dir_path: []const u8) !void {
        _ = self;
        _ = dir_path;
        // TODO: Parse manifest.json from dir_path, construct StylePluginManifest,
        // and call register(). Requires JSON parsing + file I/O integration with
        // the asset system. Will be wired once the asset pipeline JSON reader is
        // available at engine init time.
    }

    /// Scan a directory for plugin subdirectories and load each one.
    pub fn scanPluginDirectory(self: *StyleRegistry, root_path: []const u8) !void {
        _ = self;
        _ = root_path;
        // TODO: Iterate subdirectories of root_path; for each containing a
        // manifest.json, call loadUserPlugin(). Requires std.fs directory
        // iteration at init time.
    }
};
