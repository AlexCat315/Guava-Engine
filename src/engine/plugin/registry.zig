const std = @import("std");
const types = @import("types.zig");

/// Backward-compatible alias — prefer using types.PluginRecord directly.
pub const Plugin = types.PluginRecord;

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(*types.PluginRecord),
    by_type: std.AutoArrayHashMap(types.PluginType, std.ArrayList(*types.PluginRecord)),
    capabilities: std.AutoArrayHashMap(types.PluginCapability, std.ArrayList(*types.PluginRecord)),

    pub fn init(allocator: std.mem.Allocator) !PluginRegistry {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(*types.PluginRecord).init(allocator),
            .by_type = std.AutoArrayHashMap(types.PluginType, std.ArrayList(*types.PluginRecord)).init(allocator),
            .capabilities = std.AutoArrayHashMap(types.PluginCapability, std.ArrayList(*types.PluginRecord)).init(allocator),
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

    pub fn register(self: *PluginRegistry, record: *types.PluginRecord) !void {
        const name = record.manifest.name;

        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        try self.plugins.put(name, record);

        const plugin_type_list = self.by_type.getOrPut(record.manifest.plugin_type) catch return error.OutOfMemory;
        if (plugin_type_list.value_ptr.items.len == 0) {
            plugin_type_list.value_ptr.* = std.ArrayList(*types.PluginRecord).init(self.allocator);
        }
        try plugin_type_list.value_ptr.append(record);

        for (record.manifest.capabilities) |cap| {
            const cap_list = self.capabilities.getOrPut(cap) catch return error.OutOfMemory;
            if (cap_list.value_ptr.items.len == 0) {
                cap_list.value_ptr.* = std.ArrayList(*types.PluginRecord).init(self.allocator);
            }
            try cap_list.value_ptr.append(record);
        }
    }

    pub fn getByName(self: *const PluginRegistry, name: []const u8) ?*const types.PluginRecord {
        return self.plugins.get(name);
    }

    pub fn getByType(self: *const PluginRegistry, plugin_type: types.PluginType) []const *types.PluginRecord {
        const list = self.by_type.get(plugin_type) orelse return &.{};
        return list.items;
    }

    pub fn getWithCapability(self: *const PluginRegistry, capability: types.PluginCapability) []const *types.PluginRecord {
        const list = self.capabilities.get(capability) orelse return &.{};
        return list.items;
    }

    pub fn isLoaded(self: *const PluginRegistry, name: []const u8) bool {
        return self.plugins.contains(name);
    }

    /// Discover plugins from a directory tree (engine/user/project).
    pub fn discover(self: *PluginRegistry, root_path: []const u8) !void {
        _ = self;
        _ = root_path;
        // TODO(Phase B): Scan root_path for manifest.json files, parse
        // common PluginManifest shell, then dispatch to type-specific
        // loaders (StyleRegistry for render_style, etc.).
    }

    /// Transition a plugin to the enabled state.
    pub fn enable(self: *PluginRegistry, name: []const u8) !void {
        const record = self.plugins.get(name) orelse return error.PluginNotFound;
        if (record.lifecycle == .load_error) return error.PluginInErrorState;
        record.lifecycle = .enabled;
    }

    /// Transition a plugin to the loaded (disabled) state.
    pub fn disable(self: *PluginRegistry, name: []const u8) !void {
        const record = self.plugins.get(name) orelse return error.PluginNotFound;
        if (record.lifecycle == .enabled) {
            record.lifecycle = .loaded;
        }
    }

    /// Unload a plugin completely.
    pub fn unload(self: *PluginRegistry, name: []const u8) !void {
        const record = self.plugins.get(name) orelse return error.PluginNotFound;
        record.lifecycle = .unloaded;
    }
};

test "plugin registry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.plugins.count() == 0);
}
