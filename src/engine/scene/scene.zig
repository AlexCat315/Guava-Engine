const world_mod = @import("world.zig");

pub const Scene = world_mod.World;
pub const World = world_mod.World;
pub const EntityId = world_mod.EntityId;
pub const Entity = world_mod.Entity;
pub const EntityDesc = world_mod.EntityDesc;
pub const Summary = world_mod.Summary;
pub const Ray = @import("raycast.zig").Ray;
pub const SurfaceRaycastHit = @import("raycast.zig").SurfaceRaycastHit;
pub const Vfx = @import("components.zig").Vfx;
pub const VfxKind = @import("components.zig").VfxKind;
pub const serializeWorldAlloc = @import("scene_io.zig").serializeWorldAlloc;
pub const deserializeWorldFromSlice = @import("scene_io.zig").deserializeWorldFromSlice;
pub const saveWorldToPath = @import("scene_io.zig").saveWorldToPath;
pub const loadWorldFromPath = @import("scene_io.zig").loadWorldFromPath;

test {
    _ = @import("world.zig");
    _ = @import("raycast.zig");
    _ = @import("scene_io.zig");
}
