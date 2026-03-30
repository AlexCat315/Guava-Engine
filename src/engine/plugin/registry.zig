const std = @import("std");
const types = @import("types.zig");

pub const Plugin = struct {
    manifest: types.PluginManifest,
    path: []u8,
    lifecycle: types.PluginLifecycle = .unloaded,

    pub fn getName(self: *const Plugin) []const u8 {
        return self.manifest.name;
    }

    pub fn getVersion(self: *const Plugin) types.PluginVersion {
        return self.manifest.version;
    }

    pub fn getType(self: *const Plugin) types.PluginType {
        return self.manifest.plugin_type;
    }

    pub fn getSource(self: *const Plugin) types.PluginSource {
        return self.manifest.source;
    }

    pub fn isEnabled(self: *const Plugin) bool {
        return self.lifecycle == .enabled;
    }
};

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(*Plugin),
    by_type: std.AutoArrayHashMap(types.PluginType, std.ArrayList(*Plugin)),
    capabilities: std.AutoArrayHashMap(types.PluginCapability, std.ArrayList(*Plugin)),

    pub fn init(allocator: std.mem.Allocator) !PluginRegistry {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(*Plugin).init(allocator),
            .by_type = std.AutoArrayHashMap(types.PluginType, std.ArrayList(*Plugin)).init(allocator),
            .capabilities = std.AutoArrayHashMap(types.PluginCapability, std.ArrayList(*Plugin)).init(allocator),
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.plugins.deinit();

        var type_it = self.by_type.iterator();
        while (type_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.by_type.deinit();

        var cap_it = self.capabilities.iterator();
        while (cap_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.capabilities.deinit();
    }

    pub fn register(self: *PluginRegistry, plugin: *Plugin) !void {
        const name = plugin.manifest.name;

        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        try self.plugins.put(name, plugin);

        const plugin_type_list = self.by_type.getOrPut(plugin.manifest.plugin_type) catch return error.OutOfMemory;
        if (plugin_type_list.value_ptr.items.len == 0) {
            plugin_type_list.value_ptr.* = std.ArrayList(*Plugin).init(self.allocator);
        }
        try plugin_type_list.value_ptr.append(plugin);

        for (plugin.manifest.capabilities) |cap| {
            const cap_list = self.capabilities.getOrPut(cap) catch return error.OutOfMemory;
            if (cap_list.value_ptr.items.len == 0) {
                cap_list.value_ptr.* = std.ArrayList(*Plugin).init(self.allocator);
            }
            try cap_list.value_ptr.append(plugin);
        }
    }

    pub fn getByName(self: *const PluginRegistry, name: []const u8) ?*const Plugin {
        return self.plugins.get(name);
    }

    pub fn getByType(self: *const PluginRegistry, plugin_type: types.PluginType) []const *Plugin {
        const list = self.by_type.get(plugin_type) orelse return &.{};
        return list.items;
    }

    pub fn getWithCapability(self: *const PluginRegistry, capability: types.PluginCapability) []const *Plugin {
        const list = self.capabilities.get(capability) orelse return &.{};
        return list.items;
    }

    pub fn isLoaded(self: *const PluginRegistry, name: []const u8) bool {
        return self.plugins.contains(name);
    }
};

test "plugin registry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.plugins.len() == 0);
}
