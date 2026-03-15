const world_mod = @import("world.zig");

pub const Scene = world_mod.World;
pub const World = world_mod.World;
pub const EntityId = world_mod.EntityId;
pub const Entity = world_mod.Entity;
pub const EntityDesc = world_mod.EntityDesc;
pub const Summary = world_mod.Summary;

test {
    _ = @import("world.zig");
}
