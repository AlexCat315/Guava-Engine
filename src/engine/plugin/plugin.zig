const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const manifest = @import("manifest.zig");

pub const PluginType = types.PluginType;
pub const PluginCapability = types.PluginCapability;
pub const PluginSource = types.PluginSource;
pub const PluginLifecycle = types.PluginLifecycle;
pub const PluginVersion = types.PluginVersion;
pub const PluginManifest = types.PluginManifest;
pub const Plugin = registry.Plugin;
pub const PluginRegistry = registry.PluginRegistry;

pub fn createRegistry(allocator: std.mem.Allocator) !registry.PluginRegistry {
    return try registry.PluginRegistry.init(allocator);
}
