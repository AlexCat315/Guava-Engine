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
    // 视口级曝光只影响编辑器预览，不写回场景相机资源。
    exposure_enabled: bool = false,
    exposure: f32 = 1.0,
    // Bloom 先作为视口级后处理 MVP，避免和场景相机资源耦合。
    bloom_enabled: bool = false,
    bloom_threshold: f32 = 1.0,
    bloom_intensity: f32 = 0.35,
    // Color Grading 先走参数级 MVP，LUT 后续单独补。
    color_grading_enabled: bool = false,
    color_grading_saturation: f32 = 1.0,
    color_grading_contrast: f32 = 1.0,
    color_grading_gamma: f32 = 1.0,
    fxaa_enabled: bool = false,
};

pub const SceneSnapshot = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};
