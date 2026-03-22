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

pub const EditorViewportLutPreset = enum {
    neutral,
    warm,
    cool,
    filmic,
};

pub const EditorViewportState = struct {
    render_mode: EditorViewportRenderMode = .textured,
    show_grid: bool = true,
    show_bones: bool = false,
    show_collision: bool = false,
    show_collision_bvh: bool = false,
    show_constraints: bool = false,
    // 视口级曝光只影响编辑器预览，不写回场景相机资源。
    exposure_enabled: bool = false,
    exposure: f32 = 1.0,
    // Bloom 先作为视口级后处理 MVP，避免和场景相机资源耦合。
    bloom_enabled: bool = false,
    bloom_threshold: f32 = 1.0,
    bloom_intensity: f32 = 0.35,
    // SSAO 环境光遮蔽
    ssao_enabled: bool = false,
    ssao_radius: f32 = 0.5,
    ssao_bias: f32 = 0.025,
    ssao_intensity: f32 = 1.0,
    ssao_power: f32 = 2.0,
    // SSR 屏幕空间反射
    ssr_enabled: bool = false,
    ssr_intensity: f32 = 0.5,
    ssr_ray_step: f32 = 0.1,
    ssr_ray_max_distance: f32 = 100.0,
    ssr_ray_thickness: f32 = 0.5,
    ssr_fade_distance: f32 = 10.0,
    ssr_edge_fade: f32 = 0.1,
    // TAA 时域抗锯齿
    taa_enabled: bool = false,
    taa_blend_factor: f32 = 0.1,
    taa_motion_blur_scale: f32 = 1.0,
    taa_feedback_min: f32 = 0.88,
    taa_feedback_max: f32 = 0.97,
    // DOF 景深
    dof_enabled: bool = false,
    dof_focus_distance: f32 = 10.0,
    dof_focus_range: f32 = 5.0,
    dof_blur_radius: f32 = 10.0,
    dof_bokeh_radius: f32 = 5.0,
    dof_near_blur: f32 = 0.0,
    dof_far_blur: f32 = 100.0,
    dof_quality: u32 = 4,
    // Omni Shadow 点光阴影
    omni_shadow_enabled: bool = false,
    omni_shadow_resolution: u32 = 512,
    omni_shadow_far_plane: f32 = 100.0,
    // Color Grading 先走参数级 MVP，LUT 后续单独补。
    color_grading_enabled: bool = false,
    color_grading_saturation: f32 = 1.0,
    color_grading_contrast: f32 = 1.0,
    color_grading_gamma: f32 = 1.0,
    fxaa_enabled: bool = false,
    // 体积雾
    volumetric_fog_enabled: bool = false,
    volumetric_fog_density: f32 = 0.02,
    volumetric_fog_height_falloff: f32 = 0.1,
    volumetric_fog_max_distance: f32 = 100.0,
    lut_enabled: bool = false,
    lut_intensity: f32 = 1.0,
    lut_preset: EditorViewportLutPreset = .neutral,
};

pub const SceneSnapshot = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};
