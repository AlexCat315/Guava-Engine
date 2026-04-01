const std = @import("std");
const types = @import("types.zig");

pub const ManifestParseError = error{
    InvalidJson,
    MissingField,
    InvalidPluginType,
    InvalidCapability,
    InvalidVersion,
    OutOfMemory,
};

/// Parse a `manifest.json` blob into a `PluginManifest`.
/// All string fields in the returned manifest are allocator-owned and must
/// be released by calling `PluginManifest.deinit(allocator)`.
pub fn parseManifest(allocator: std.mem.Allocator, json_content: []const u8) ManifestParseError!types.PluginManifest {
    const ManifestJson = struct {
        name: []const u8 = "",
        version: []const u8 = "1.0.0",
        plugin_type: []const u8 = "render_style",
        source: []const u8 = "user",
        capabilities: []const []const u8 = &.{},
    };

    const parsed = std.json.parseFromSlice(ManifestJson, allocator, json_content, .{
        .ignore_unknown_fields = true,
    }) catch return ManifestParseError.InvalidJson;
    defer parsed.deinit();

    const m = parsed.value;
    if (m.name.len == 0) return ManifestParseError.MissingField;

    const plugin_type = std.meta.stringToEnum(types.PluginType, m.plugin_type) orelse
        return ManifestParseError.InvalidPluginType;
    const source = std.meta.stringToEnum(types.PluginSource, m.source) orelse .user;
    const version = types.PluginVersion.parse(m.version) catch
        return ManifestParseError.InvalidVersion;

    // Parse capabilities into an owned slice.
    var caps: std.ArrayListUnmanaged(types.PluginCapability) = .empty;
    defer caps.deinit(allocator);
    for (m.capabilities) |cap_str| {
        const cap = std.meta.stringToEnum(types.PluginCapability, cap_str) orelse
            return ManifestParseError.InvalidCapability;
        caps.append(allocator, cap) catch return ManifestParseError.OutOfMemory;
    }

    const name_dupe = allocator.dupe(u8, m.name) catch return ManifestParseError.OutOfMemory;
    errdefer allocator.free(name_dupe);

    const owned_caps = caps.toOwnedSlice(allocator) catch return ManifestParseError.OutOfMemory;

    return .{
        .name = name_dupe,
        .version = version,
        .plugin_type = plugin_type,
        .capabilities = owned_caps,
        .source = source,
    };
}

test "parse manifest basic" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test_plugin",
        \\  "version": "1.2.3",
        \\  "plugin_type": "render_style",
        \\  "capabilities": ["shader", "render_pass"]
        \\}
    ;

    var manifest = try parseManifest(allocator, json);
    defer manifest.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "test_plugin", manifest.name);
    try std.testing.expectEqual(@as(u16, 1), manifest.version.major);
}
