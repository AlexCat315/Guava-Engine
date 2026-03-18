const std = @import("std");
const handles = @import("handles.zig");
const components = @import("../scene/components.zig");

pub const MaterialResource = struct {
    name: []u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture: ?handles.TextureHandle = null,
    metallic_roughness_texture: ?handles.TextureHandle = null,
    normal_texture: ?handles.TextureHandle = null,
    occlusion_texture: ?handles.TextureHandle = null,
    emissive_texture: ?handles.TextureHandle = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true, // Enable IBL by default
    ibl_intensity: f32 = 1.0, // IBL intensity multiplier

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
    metallic_roughness_texture: ?handles.TextureHandle = null,
    normal_texture: ?handles.TextureHandle = null,
    occlusion_texture: ?handles.TextureHandle = null,
    emissive_texture: ?handles.TextureHandle = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
};

pub fn clone(allocator: std.mem.Allocator, desc: MaterialResourceDesc) !MaterialResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .shading = desc.shading,
        .base_color_factor = desc.base_color_factor,
        .base_color_texture = desc.base_color_texture,
        .metallic_roughness_texture = desc.metallic_roughness_texture,
        .normal_texture = desc.normal_texture,
        .occlusion_texture = desc.occlusion_texture,
        .emissive_texture = desc.emissive_texture,
        .emissive_factor = desc.emissive_factor,
        .metallic_factor = desc.metallic_factor,
        .roughness_factor = desc.roughness_factor,
        .alpha_cutoff = desc.alpha_cutoff,
        .double_sided = desc.double_sided,
        .use_ibl = desc.use_ibl,
        .ibl_intensity = desc.ibl_intensity,
    };
}
