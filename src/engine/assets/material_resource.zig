const std = @import("std");
const handles = @import("handles.zig");
const components = @import("../scene/components.zig");

pub const MaterialResource = struct {
    name: []u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture: ?handles.TextureHandle = null,

    pub fn deinit(self: *MaterialResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const MaterialResourceDesc = struct {
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture: ?handles.TextureHandle = null,
};

pub fn clone(allocator: std.mem.Allocator, desc: MaterialResourceDesc) !MaterialResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .shading = desc.shading,
        .base_color_factor = desc.base_color_factor,
        .base_color_texture = desc.base_color_texture,
    };
}
