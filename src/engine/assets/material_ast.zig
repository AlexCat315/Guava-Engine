const std = @import("std");
const components = @import("../scene/components.zig");
const handles = @import("handles.zig");
const material_resource_mod = @import("material_resource.zig");

pub const TextureSlots = struct {
    base_color: ?handles.TextureHandle = null,
    metallic_roughness: ?handles.TextureHandle = null,
    normal: ?handles.TextureHandle = null,
    occlusion: ?handles.TextureHandle = null,
    emissive: ?handles.TextureHandle = null,
};

// MaterialAst is a small renderer-agnostic intermediate representation.
// Phase 1 keeps this flat and close to MaterialResource for safe adoption.
pub const MaterialAst = struct {
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
    textures: TextureSlots = .{},

    pub fn fromResource(resource: *const material_resource_mod.MaterialResource) MaterialAst {
        return .{
            .name = resource.name,
            .shading = resource.shading,
            .base_color_factor = resource.base_color_factor,
            .emissive_factor = resource.emissive_factor,
            .metallic_factor = resource.metallic_factor,
            .roughness_factor = resource.roughness_factor,
            .alpha_cutoff = resource.alpha_cutoff,
            .double_sided = resource.double_sided,
            .use_ibl = resource.use_ibl,
            .ibl_intensity = resource.ibl_intensity,
            .textures = .{
                .base_color = resource.base_color_texture,
                .metallic_roughness = resource.metallic_roughness_texture,
                .normal = resource.normal_texture,
                .occlusion = resource.occlusion_texture,
                .emissive = resource.emissive_texture,
            },
        };
    }

    pub fn toResourceDesc(self: *const MaterialAst) material_resource_mod.MaterialResourceDesc {
        return .{
            .name = self.name,
            .shading = self.shading,
            .base_color_factor = self.base_color_factor,
            .base_color_texture = self.textures.base_color,
            .metallic_roughness_texture = self.textures.metallic_roughness,
            .normal_texture = self.textures.normal,
            .occlusion_texture = self.textures.occlusion,
            .emissive_texture = self.textures.emissive,
            .emissive_factor = self.emissive_factor,
            .metallic_factor = self.metallic_factor,
            .roughness_factor = self.roughness_factor,
            .alpha_cutoff = self.alpha_cutoff,
            .double_sided = self.double_sided,
            .use_ibl = self.use_ibl,
            .ibl_intensity = self.ibl_intensity,
        };
    }
};

test "MaterialAst.fromResource maps all phase-1 fields" {
    const resource: material_resource_mod.MaterialResource = .{
        .name = @constCast("MatA"),
        .shading = .lambert,
        .base_color_factor = .{ 0.1, 0.2, 0.3, 0.4 },
        .base_color_texture = @enumFromInt(2),
        .metallic_roughness_texture = @enumFromInt(3),
        .normal_texture = @enumFromInt(4),
        .occlusion_texture = @enumFromInt(5),
        .emissive_texture = @enumFromInt(6),
        .emissive_factor = .{ 0.7, 0.8, 0.9 },
        .metallic_factor = 0.25,
        .roughness_factor = 0.75,
        .alpha_cutoff = 0.42,
        .double_sided = true,
        .use_ibl = false,
        .ibl_intensity = 1.6,
    };

    const ast = MaterialAst.fromResource(&resource);
    try std.testing.expectEqual(components.ShadingModel.lambert, ast.shading);
    try std.testing.expectEqual(resource.base_color_factor, ast.base_color_factor);
    try std.testing.expectEqual(resource.emissive_factor, ast.emissive_factor);
    try std.testing.expectEqual(resource.metallic_factor, ast.metallic_factor);
    try std.testing.expectEqual(resource.roughness_factor, ast.roughness_factor);
    try std.testing.expectEqual(resource.alpha_cutoff, ast.alpha_cutoff);
    try std.testing.expectEqual(resource.double_sided, ast.double_sided);
    try std.testing.expectEqual(resource.use_ibl, ast.use_ibl);
    try std.testing.expectEqual(resource.ibl_intensity, ast.ibl_intensity);
    try std.testing.expectEqual(resource.base_color_texture, ast.textures.base_color);
    try std.testing.expectEqual(resource.metallic_roughness_texture, ast.textures.metallic_roughness);
    try std.testing.expectEqual(resource.normal_texture, ast.textures.normal);
    try std.testing.expectEqual(resource.occlusion_texture, ast.textures.occlusion);
    try std.testing.expectEqual(resource.emissive_texture, ast.textures.emissive);
}

test "MaterialAst.toResourceDesc maps all phase-1 fields" {
    const ast: MaterialAst = .{
        .name = "AstMat",
        .shading = .pbr_metallic_roughness,
        .base_color_factor = .{ 0.9, 0.6, 0.4, 1.0 },
        .emissive_factor = .{ 0.05, 0.1, 0.2 },
        .metallic_factor = 0.33,
        .roughness_factor = 0.66,
        .alpha_cutoff = 0.12,
        .double_sided = true,
        .use_ibl = true,
        .ibl_intensity = 0.8,
        .textures = .{
            .base_color = @enumFromInt(11),
            .metallic_roughness = @enumFromInt(12),
            .normal = @enumFromInt(13),
            .occlusion = @enumFromInt(14),
            .emissive = @enumFromInt(15),
        },
    };

    const desc = ast.toResourceDesc();
    try std.testing.expectEqualStrings(ast.name, desc.name);
    try std.testing.expectEqual(ast.shading, desc.shading);
    try std.testing.expectEqual(ast.base_color_factor, desc.base_color_factor);
    try std.testing.expectEqual(ast.emissive_factor, desc.emissive_factor);
    try std.testing.expectEqual(ast.metallic_factor, desc.metallic_factor);
    try std.testing.expectEqual(ast.roughness_factor, desc.roughness_factor);
    try std.testing.expectEqual(ast.alpha_cutoff, desc.alpha_cutoff);
    try std.testing.expectEqual(ast.double_sided, desc.double_sided);
    try std.testing.expectEqual(ast.use_ibl, desc.use_ibl);
    try std.testing.expectEqual(ast.ibl_intensity, desc.ibl_intensity);
    try std.testing.expectEqual(ast.textures.base_color, desc.base_color_texture);
    try std.testing.expectEqual(ast.textures.metallic_roughness, desc.metallic_roughness_texture);
    try std.testing.expectEqual(ast.textures.normal, desc.normal_texture);
    try std.testing.expectEqual(ast.textures.occlusion, desc.occlusion_texture);
    try std.testing.expectEqual(ast.textures.emissive, desc.emissive_texture);
}
