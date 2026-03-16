const world_mod = @import("world.zig");

pub const Scene = world_mod.World;
pub const World = world_mod.World;
pub const EntityId = world_mod.EntityId;
pub const Entity = world_mod.Entity;
pub const EntityDesc = world_mod.EntityDesc;
pub const Summary = world_mod.Summary;
pub const serializeWorldAlloc = @import("scene_io.zig").serializeWorldAlloc;
pub const deserializeWorldFromSlice = @import("scene_io.zig").deserializeWorldFromSlice;
pub const saveWorldToPath = @import("scene_io.zig").saveWorldToPath;
pub const loadWorldFromPath = @import("scene_io.zig").loadWorldFromPath;

test {
    _ = @import("world.zig");
    _ = @import("scene_io.zig");
}
