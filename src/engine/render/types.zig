pub const GraphicsAPI = @import("../rhi/types.zig").GraphicsAPI;
pub const BackendSelectionPolicy = @import("../rhi/types.zig").BackendSelectionPolicy;
pub const RuntimeInfo = @import("../rhi/types.zig").RuntimeInfo;
pub const graphicsApiName = @import("../rhi/types.zig").graphicsApiName;
pub const defaultPreferredBackends = @import("../rhi/types.zig").defaultPreferredBackends;
pub const defaultBackendOrder = @import("../rhi/types.zig").defaultBackendOrder;

pub const EditorViewportRenderMode = enum {
    textured,
    wireframe,
    unlit,
};

pub const EditorViewportState = struct {
    render_mode: EditorViewportRenderMode = .textured,
    show_grid: bool = true,
    show_bones: bool = false,
    show_collision: bool = false,
};

pub const SceneSnapshot = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};
