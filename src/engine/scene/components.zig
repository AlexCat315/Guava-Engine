const handles = @import("../assets/handles.zig");

pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;

pub const Transform = struct {
    translation: Vec3 = .{ 0.0, 0.0, 0.0 },
    rotation_euler: Vec3 = .{ 0.0, 0.0, 0.0 },
    scale: Vec3 = .{ 1.0, 1.0, 1.0 },
};

pub const CameraProjection = union(enum) {
    perspective: struct {
        fov_y_radians: f32 = 1.0471976,
        near_clip: f32 = 0.1,
        far_clip: f32 = 1000.0,
    },
    orthographic: struct {
        size: f32 = 10.0,
        near_clip: f32 = -1.0,
        far_clip: f32 = 1.0,
    },
};

pub const Camera = struct {
    projection: CameraProjection = .{ .perspective = .{} },
    is_primary: bool = false,
};

pub const Primitive = enum {
    cube,
    sphere,
    plane,
    custom,
};

pub const Mesh = struct {
    handle: ?handles.MeshHandle = null,
    primitive: Primitive = .custom,
};

pub const ShadingModel = enum {
    unlit,
    lambert,
    pbr_metallic_roughness,
};

pub const Material = struct {
    handle: ?handles.MaterialHandle = null,
    shading: ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

pub const LightKind = enum {
    directional,
    point,
    spot,
};

pub const Light = struct {
    kind: LightKind = .directional,
    color: Vec3 = .{ 1.0, 1.0, 1.0 },
    intensity: f32 = 1.0,
    range: f32 = 10.0,
};
