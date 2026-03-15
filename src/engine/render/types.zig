pub const GraphicsAPI = @import("../rhi/types.zig").GraphicsAPI;
pub const BackendSelectionPolicy = @import("../rhi/types.zig").BackendSelectionPolicy;
pub const RuntimeInfo = @import("../rhi/types.zig").RuntimeInfo;
pub const graphicsApiName = @import("../rhi/types.zig").graphicsApiName;

pub const SceneSnapshot = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};
