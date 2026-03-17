const handles = @import("../assets/handles.zig");

pub const Vec2 = [2]f32;
pub const Vec3 = [3]f32;
pub const Quat = [4]f32;

pub const Transform = struct {
    translation: Vec3 = .{ 0.0, 0.0, 0.0 },
    rotation: Quat = .{ 0.0, 0.0, 0.0, 1.0 },
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

pub const VfxKind = enum {
    fountain,
    orbit,
};

pub const Vfx = struct {
    kind: VfxKind = .fountain,
    looping: bool = true,
    emission_rate: f32 = 18.0,
    particle_lifetime: f32 = 1.25,
    speed: f32 = 2.2,
    max_particles: u16 = 24,
    radius: f32 = 0.55,
    spread: f32 = 0.35,
    size: f32 = 0.12,
    color: Vec3 = .{ 1.0, 0.58, 0.26 },
};

pub fn defaultVfx(kind: VfxKind) Vfx {
    return switch (kind) {
        .fountain => .{
            .kind = .fountain,
            .looping = true,
            .emission_rate = 18.0,
            .particle_lifetime = 1.2,
            .speed = 2.6,
            .max_particles = 28,
            .radius = 0.42,
            .spread = 0.38,
            .size = 0.11,
            .color = .{ 1.0, 0.58, 0.26 },
        },
        .orbit => .{
            .kind = .orbit,
            .looping = true,
            .emission_rate = 12.0,
            .particle_lifetime = 1.8,
            .speed = 1.2,
            .max_particles = 20,
            .radius = 0.72,
            .spread = 0.18,
            .size = 0.1,
            .color = .{ 0.42, 0.82, 1.0 },
        },
    };
}
