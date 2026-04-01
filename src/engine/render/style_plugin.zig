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

/// Execution stage for a post-process pass injected by a style plugin.
pub const StylePassStage = enum {
    post_lighting,
    post_tonemap,
    pre_ui,
};

/// Descriptor for a single post-process pass contributed by a style plugin.
/// Declares execution stage, resource dependencies, and ordering constraints
/// so `RenderGraph` can safely schedule barriers and resource aliasing.
pub const StylePostPassDescriptor = struct {
    name: []const u8,
    shader_program: []const u8,
    stage: StylePassStage = .post_lighting,
    reads: []const []const u8 = &.{},
    writes: []const []const u8 = &.{},
    order_after: ?[]const u8 = null,
    order_before: ?[]const u8 = null,
};

/// Manifest describing a render style plugin's capabilities and shaders.
/// This is the typed payload for `render_style` plugins; `PluginManifest`
/// (in plugin/types.zig) holds the common shell (name, version, source, deps).
pub const StylePluginManifest = struct {
    name: []const u8,
    display_name: []const u8 = "",
    version: []const u8 = "1.0.0",
    source: plugin_types.PluginSource = .builtin,
    path: ?[]const u8 = null,

    /// Shader program name for mesh rendering.
    mesh_program: []const u8 = "mesh",
    /// Optional override shader program for shadows.
    shadow_program: ?[]const u8 = null,
    /// Built-in passes to disable when this style is active (e.g. "bloom", "taa").
    disabled_passes: []const []const u8 = &.{},
    /// User-tunable parameters for this style.
    config_schema: []const StyleParam = &.{},
    /// Post-process pass chain contributed by this style.
    /// Phase C feature — loaded but not yet injected into RenderGraph.
    post_chain: []const StylePostPassDescriptor = &.{},
};

/// Default PBR render style — maps to the built-in "mesh" shader program.
pub const default_pbr_style = StylePluginManifest{
    .name = "default_pbr",
    .display_name = "PBR (Default)",
    .version = "1.0.0",
    .source = .builtin,
    .mesh_program = "mesh",
    .shadow_program = "shadow_pass",
};

/// Unlit flat-color style — no lighting, just albedo output.
pub const unlit_flat_style = StylePluginManifest{
    .name = "unlit_flat",
    .display_name = "Unlit Flat",
    .version = "1.0.0",
    .source = .builtin,
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
/// This is the typed runtime owner for `render_style` plugins.
/// `PluginRegistry` handles discovery/lifecycle; `StyleRegistry` handles
/// shader selection, parameters, and activation.
pub const StyleRegistry = struct {
    allocator: std.mem.Allocator,
    styles: std.StringHashMap(StylePluginManifest),
    active_style_name: []const u8,
    previous_style_name: []const u8,
    param_values: std.StringHashMap(StyleParamValues),

    pub fn init(allocator: std.mem.Allocator) StyleRegistry {
        var registry = StyleRegistry{
            .allocator = allocator,
            .styles = std.StringHashMap(StylePluginManifest).init(allocator),
            .active_style_name = "default_pbr",
            .previous_style_name = "default_pbr",
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

    /// Switch active style. Returns false if the style doesn't exist.
    /// Saves previous style for rollback.
    pub fn setActiveStyle(self: *StyleRegistry, name: []const u8) bool {
        if (self.styles.contains(name)) {
            self.previous_style_name = self.active_style_name;
            self.active_style_name = name;
            return true;
        }
        return false;
    }

    /// Rollback to the previously active style (e.g. on switch failure).
    pub fn rollbackStyle(self: *StyleRegistry) void {
        self.active_style_name = self.previous_style_name;
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
    /// Expects `dir_path/manifest.json` with the structure documented in R-9.
    pub fn loadUserPlugin(self: *StyleRegistry, dir_path: []const u8) !void {
        _ = self;
        _ = dir_path;
        // TODO(Phase B): Parse manifest.json from dir_path, extract the
        // "render_style" typed payload, construct StylePluginManifest,
        // and call register(). Requires JSON parsing + directory I/O.
    }

    /// Scan a directory for plugin subdirectories and load each one.
    pub fn scanPluginDirectory(self: *StyleRegistry, root_path: []const u8) !void {
        _ = self;
        _ = root_path;
        // TODO(Phase B): Iterate subdirectories of root_path; for each
        // containing a manifest.json with plugin_type=="render_style",
        // call loadUserPlugin().
    }
};
