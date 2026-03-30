const std = @import("std");
const types = @import("types.zig");

const ManifestParseError = error{
    InvalidJson,
    MissingField,
    InvalidPluginType,
    InvalidCapability,
    InvalidVersion,
};

pub fn parseManifest(allocator: std.mem.Allocator, json_content: []const u8) ManifestParseError!types.PluginManifest {
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    const json = try parser.parse(json_content);

    const name = json.root.object.get("name") orelse return ManifestParseError.MissingField;
    const name_str = try allocator.dupe(u8, name.string);

    const version_str = json.root.object.get("version") orelse return ManifestParseError.MissingField;
    const version = types.PluginVersion.parse(version_str.string) catch return ManifestParseError.InvalidVersion;

    const plugin_type_str = json.root.object.get("plugin_type") orelse return ManifestParseError.MissingField;
    const plugin_type = std.meta.stringToEnum(types.PluginType, plugin_type_str.string) orelse return ManifestParseError.InvalidPluginType;

    const source_str = json.root.object.get("source") orelse "user";
    const source = std.meta.stringToEnum(types.PluginSource, source_str.str) orelse .user;

    var capabilities = std.ArrayList(types.PluginCapability).init(allocator);
    defer capabilities.deinit();

    if (json.root.object.get("capabilities")) |caps_val| {
        for (caps_val.array.items) |cap_val| {
            const cap_str = cap_val.string;
            const cap = std.meta.stringToEnum(types.PluginCapability, cap_str) orelse return ManifestParseError.InvalidCapability;
            try capabilities.append(cap);
        }
    }

    return types.PluginManifest{
        .name = name_str,
        .version = version,
        .plugin_type = plugin_type,
        .capabilities = try capabilities.toOwnedSlice(),
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

    const manifest = try parseManifest(allocator, json);
    try std.testing.expectEqualSlices(u8, "test_plugin", manifest.name);
    try std.testing.expectEqual(@as(u16, 1), manifest.version.major);
}
