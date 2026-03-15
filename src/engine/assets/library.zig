const std = @import("std");
const handles = @import("handles.zig");
const material_mod = @import("material_resource.zig");
const mesh_mod = @import("mesh_resource.zig");
const texture_mod = @import("texture_resource.zig");
const components = @import("../scene/components.zig");

pub const ResourceLibrary = struct {
    allocator: std.mem.Allocator,
    meshes: std.ArrayList(mesh_mod.MeshResource) = .empty,
    materials: std.ArrayList(material_mod.MaterialResource) = .empty,
    textures: std.ArrayList(texture_mod.TextureResource) = .empty,
    cube_mesh: ?handles.MeshHandle = null,
    plane_mesh: ?handles.MeshHandle = null,
    default_material: ?handles.MaterialHandle = null,
    white_texture: ?handles.TextureHandle = null,

    pub fn init(allocator: std.mem.Allocator) ResourceLibrary {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResourceLibrary) void {
        for (self.meshes.items) |*mesh_resource| {
            mesh_resource.deinit(self.allocator);
        }
        self.meshes.deinit(self.allocator);

        for (self.materials.items) |*material_resource| {
            material_resource.deinit(self.allocator);
        }
        self.materials.deinit(self.allocator);

        for (self.textures.items) |*texture_resource| {
            texture_resource.deinit(self.allocator);
        }
        self.textures.deinit(self.allocator);
    }

    pub fn createMesh(self: *ResourceLibrary, desc: mesh_mod.MeshResourceDesc) !handles.MeshHandle {
        const resource = try mesh_mod.clone(self.allocator, desc);
        try self.meshes.append(self.allocator, resource);
        return handles.meshHandle(self.meshes.items.len - 1);
    }

    pub fn createMaterial(self: *ResourceLibrary, desc: material_mod.MaterialResourceDesc) !handles.MaterialHandle {
        const resource = try material_mod.clone(self.allocator, desc);
        try self.materials.append(self.allocator, resource);
        return handles.materialHandle(self.materials.items.len - 1);
    }

    pub fn createTexture(self: *ResourceLibrary, desc: texture_mod.TextureResourceDesc) !handles.TextureHandle {
        const resource = try texture_mod.clone(self.allocator, desc);
        try self.textures.append(self.allocator, resource);
        return handles.textureHandle(self.textures.items.len - 1);
    }

    pub fn mesh(self: *const ResourceLibrary, handle: handles.MeshHandle) ?*const mesh_mod.MeshResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        return &self.meshes.items[handles.indexOf(handle)];
    }

    pub fn material(self: *const ResourceLibrary, handle: handles.MaterialHandle) ?*const material_mod.MaterialResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        return &self.materials.items[handles.indexOf(handle)];
    }

    pub fn texture(self: *const ResourceLibrary, handle: handles.TextureHandle) ?*const texture_mod.TextureResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        return &self.textures.items[handles.indexOf(handle)];
    }

    pub fn ensurePrimitiveMesh(self: *ResourceLibrary, primitive: components.Primitive) !handles.MeshHandle {
        return switch (primitive) {
            .cube => blk: {
                if (self.cube_mesh) |handle| break :blk handle;
                self.cube_mesh = try self.createMesh(.{
                    .name = "BuiltinCube",
                    .vertices = cube_vertices[0..],
                    .indices = cube_indices[0..],
                });
                break :blk self.cube_mesh.?;
            },
            .plane => blk: {
                if (self.plane_mesh) |handle| break :blk handle;
                self.plane_mesh = try self.createMesh(.{
                    .name = "BuiltinPlane",
                    .vertices = plane_vertices[0..],
                    .indices = plane_indices[0..],
                });
                break :blk self.plane_mesh.?;
            },
            else => error.UnsupportedPrimitive,
        };
    }

    pub fn ensureWhiteTexture(self: *ResourceLibrary) !handles.TextureHandle {
        if (self.white_texture) |handle| {
            return handle;
        }

        const pixels = [_]u8{
            0xFF, 0xFF, 0xFF, 0xFF,
        };

        self.white_texture = try self.createTexture(.{
            .name = "White1x1",
            .width = 1,
            .height = 1,
            .pixels = pixels[0..],
        });
        return self.white_texture.?;
    }

    pub fn ensureDefaultMaterial(self: *ResourceLibrary) !handles.MaterialHandle {
        if (self.default_material) |handle| {
            return handle;
        }

        self.default_material = try self.createMaterial(.{
            .name = "DefaultMaterial",
            .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
            .base_color_texture = try self.ensureWhiteTexture(),
        });
        return self.default_material.?;
    }
};

const cube_vertices = [_]mesh_mod.Vertex{
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 0.0, 0.0 } },
};

const cube_indices = [_]u32{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const plane_vertices = [_]mesh_mod.Vertex{
    .{ .position = .{ -0.5, 0.0, -0.5 }, .color = .{ 0.85, 0.88, 0.9, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.0, -0.5 }, .color = .{ 0.85, 0.88, 0.9, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.0, 0.5 }, .color = .{ 0.85, 0.88, 0.9, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.0, 0.5 }, .color = .{ 0.85, 0.88, 0.9, 1.0 }, .uv = .{ 0.0, 0.0 } },
};

const plane_indices = [_]u32{
    0, 1, 2,
    0, 2, 3,
};
