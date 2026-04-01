const std = @import("std");
const types = @import("types.zig");
const manifest_mod = @import("manifest.zig");

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
            entry.value_ptr.*.deinit(self.allocator);
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
        if (!plugin_type_list.found_existing) {
            plugin_type_list.value_ptr.* = .empty;
        }
        try plugin_type_list.value_ptr.append(self.allocator, record);

        for (record.manifest.capabilities) |cap| {
            const cap_list = self.capabilities.getOrPut(cap) catch return error.OutOfMemory;
            if (!cap_list.found_existing) {
                cap_list.value_ptr.* = .empty;
            }
            try cap_list.value_ptr.append(self.allocator, record);
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
    /// Iterates subdirectories of `root_path`, reads `manifest.json` from
    /// each, and registers a `PluginRecord` for every valid manifest.
    pub fn discover(self: *PluginRegistry, root_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
            std.log.warn("PluginRegistry: cannot open directory '{s}': {s}", .{ root_path, @errorName(err) });
            return;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;

            const manifest_path = std.fs.path.join(self.allocator, &.{ root_path, entry.name, "manifest.json" }) catch continue;
            defer self.allocator.free(manifest_path);

            const content = std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 64 * 1024) catch continue;
            defer self.allocator.free(content);

            var plugin_manifest = manifest_mod.parseManifest(self.allocator, content) catch continue;
            errdefer plugin_manifest.deinit(self.allocator);

            // Set the path field (parseManifest does not know about file paths).
            plugin_manifest.path = self.allocator.dupe(u8, manifest_path) catch continue;

            const record = self.allocator.create(types.PluginRecord) catch continue;
            record.* = .{
                .manifest = plugin_manifest,
                .lifecycle = .loaded,
            };

            self.register(record) catch {
                record.deinit(self.allocator);
                self.allocator.destroy(record);
                continue;
            };
        }
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

    /// Fully unload and remove a plugin from all indices.
    pub fn unload(self: *PluginRegistry, name: []const u8) !void {
        const record_ptr = self.plugins.get(name) orelse return error.PluginNotFound;

        // Remove from by_type index
        if (self.by_type.getPtr(record_ptr.manifest.plugin_type)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == record_ptr) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Remove from capability indices
        for (record_ptr.manifest.capabilities) |cap| {
            if (self.capabilities.getPtr(cap)) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == record_ptr) {
                        _ = list.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Remove from main map, free record
        _ = self.plugins.remove(name);
        record_ptr.deinit(self.allocator);
        self.allocator.destroy(record_ptr);
    }
};

test "plugin registry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.plugins.count() == 0);
}
