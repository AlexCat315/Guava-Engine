//! 渲染系统核心模块
//!
//! 本模块提供完整的渲染管线实现，是 Guava Engine 渲染系统的核心。
//!
//! ## 渲染管线流程
//!
//! 1. **Depth Prepass** - 深度预通道，优化后续渲染
//! 2. **Shadow Pass** - 阴影贴图渲染
//! 3. **Base Pass** - 主渲染通道，渲染场景几何体
//! 4. **Skybox Pass** - 天空盒渲染
//! 5. **Bloom Pass** - 泛光后处理
//! 6. **FXAA Pass** - 快速近似抗锯齿
//! 7. **Tonemap Pass** - 色调映射
//! 8. **Gizmo Pass** - 编辑器 Gizmo 渲染
//! 9. **Outline Pass** - 选中物体轮廓
//! 10. **ID Pass** - 物体 ID 拾取（用于编辑器选择）
//!
//! ## 主要功能
//!
//! - **设备管理** - 创建和管理 GPU 设备
//! - **资源管理** - 纹理、缓冲区、管线等 GPU 资源
//! - **渲染图** - 自动管理渲染通道依赖
//! - **场景提取** - 视锥剔除和场景数据准备
//! - **后处理** - Bloom、FXAA、色调映射等效果
//! - **编辑器支持** - Gizmo、选择高亮、ID 拾取
//!
//! ## 使用示例
//!
//! ```zig
//! // 创建渲染器配置
//! const config = RendererConfig{
//!     .requested_backends = &.{.metal, .vulkan},
//!     .enable_validation = true,
//! };
//!
//! // 初始化渲染器
//! var renderer = try Renderer.init(allocator, config);
//! defer renderer.deinit();
//!
//! // 渲染帧
//! const report = try renderer.drawFrame(&world, viewport_state);
//! ```

const std = @import("std");
const mesh_resource_mod = @import("../assets/mesh_resource.zig");
const assets_lib = @import("../assets/library.zig");
const handles = @import("../assets/handles.zig");
const environment_map_import_mod = @import("../assets/environment_map_import.zig");
const material_resource_mod = @import("../assets/material_resource.zig");
const registry_mod = @import("../assets/registry.zig");
const texture_resource_mod = @import("../assets/texture_resource.zig");
const texture_import_mod = @import("../assets/texture_import.zig");
const base_pass_mod = @import("base_pass.zig");
const shadow_pass_mod = @import("shadow_pass.zig");
const skybox_pass_mod = @import("skybox_pass.zig");
const bloom_pass_mod = @import("bloom_pass.zig");
const tonemap_pass_mod = @import("tonemap_pass.zig");
const depth_prepass_mod = @import("depth_prepass.zig");
const id_pass_mod = @import("id_pass.zig");
const gizmo_pass_mod = @import("gizmo_pass.zig");
const outline_pass_mod = @import("outline_pass.zig");
const volumetric_fog_pass_mod = @import("volumetric_fog_pass.zig");
const ssao_pass_mod = @import("ssao_pass.zig");
const ssao_compute_pass_mod = @import("ssao_compute_pass_runtime.zig");
const ibl_compute_pass_mod = @import("ibl_compute_pass.zig");
const contact_shadow_pass_mod = @import("contact_shadow_pass.zig");
const taa_pass_mod = @import("taa_pass.zig");
const rt_shadow_composite_pass_mod = @import("rt_shadow_composite_pass.zig");
const dof_pass_mod = @import("dof_pass.zig");
const ssr_pass_mod = @import("ssr_pass.zig");
const fullscreen_post_mod = @import("fullscreen_post_pass.zig");
const platform_mod = @import("../core/platform.zig");
const selection_history_mod = @import("selection_history.zig");
const imgui_mod = @import("../ui/imgui.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const scene_extraction = @import("scene_extraction.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const rhi_api = @import("../rhi/rhi.zig");
const rhi_mock_backend_mod = @import("../rhi/metal/metal_backend.zig");
const metal_device_mod = @import("../rhi/metal/metal_device.zig");
const sdl = @import("../platform/sdl.zig").c;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const mat4_mod = @import("../math/mat4.zig");
const vec3 = @import("../math/vec3.zig");
const physics_mod = @import("../physics/system.zig");
const PassDescriptors = @import("render_helpers.zig").PassDescriptors;
const render_log = std.log.scoped(.viewport_render);
const rt_backend = @import("../rt/rt_backend.zig");
const rt_device_mod = @import("../rhi/rt_device.zig");

/// 是否已记录视口后端日志
var g_logged_viewport_backend: bool = false;
/// 是否已记录环境状态日志
var g_logged_environment_status: bool = false;
/// 已记录的后处理状态
var g_logged_postfx_state: ?types.EditorViewportState = null;
/// 是否已记录场景提取剔除日志
var g_logged_scene_extraction_culling: bool = false;
/// 已记录的碰撞覆盖盒数量
var g_logged_collision_overlay_boxes: ?usize = null;
/// 是否已记录 CPU PathTrace 激活日志
var g_logged_path_trace_active: bool = false;

const CachedEnvironmentTextures = struct {
    resolved: bool = false,
    environment_map: ?*const rhi_mod.Texture = null,
    irradiance_map: ?*const rhi_mod.Texture = null,
    prefiltered_env_map: ?*const rhi_mod.Texture = null,
    brdf_lut: ?*const rhi_mod.Texture = null,
};

/// 图形 API 类型
pub const GraphicsAPI = rhi_types.GraphicsAPI;
/// 运行时信息
pub const RuntimeInfo = rhi_types.RuntimeInfo;
/// 选择历史管理
pub const SelectionHistory = selection_history_mod.SelectionHistory;
/// 选择更新模式
pub const SelectionUpdateMode = selection_history_mod.SelectionUpdateMode;
/// 编辑器 Gizmo 状态
pub const EditorGizmoState = gizmo_pass_mod.EditorGizmoState;
/// 编辑器视口状态
pub const EditorViewportState = types.EditorViewportState;

/// 渲染器配置
///
/// 用于初始化渲染器时指定各种参数。
pub const RendererConfig = struct {
    /// 请求的图形后端列表（按优先级排序）
    requested_backends: []const rhi_types.GraphicsAPI = &.{},
    /// 后端选择策略
    selection_policy: rhi_types.BackendSelectionPolicy = .explicit_order,
    /// 是否启用验证层（调试用）
    enable_validation: bool = true,
    /// 帧在飞数量（用于帧同步）
    frames_in_flight: u32 = 2,
};

/// 帧报告
///
/// 包含一帧渲染的统计信息，用于性能分析和调试。
pub const FrameReport = struct {
    /// 使用的图形后端
    backend: types.GraphicsAPI,
    /// 执行的渲染通道数量
    passes_executed: usize,
    /// 渲染图资源数量
    graph_resources: usize,
    /// 场景快照
    scene: types.SceneSnapshot,
    /// 运行时信息
    runtime: types.RuntimeInfo,
    /// 绘制调用次数
    draw_calls: usize = 0,
    /// 绘制的三角形数量
    triangles_drawn: usize = 0,
    /// RHI BindingSet 缓存命中次数
    binding_cache_hits: u64 = 0,
    /// RHI BindingSet 缓存未命中次数
    binding_cache_misses: u64 = 0,
    /// RHI slot-layout 校验失败数
    slot_layout_errors: usize = 0,
    /// 本帧 RHI 缓存命中增量
    binding_cache_hits_delta: u64 = 0,
    /// 本帧 RHI 缓存未命中增量
    binding_cache_misses_delta: u64 = 0,
    /// 本帧 RHI 缓存淘汰增量
    binding_cache_evictions_delta: u64 = 0,
};

/// 选择回读请求
const SelectionReadbackRequest = struct {
    /// 像素 X 坐标
    pixel_x: u32,
    /// 像素 Y 坐标
    pixel_y: u32,
    /// 选择更新模式
    mode: SelectionUpdateMode,
};

/// 飞行中的选择回读
const InFlightSelectionReadback = struct {
    /// 请求信息
    request: SelectionReadbackRequest,
    /// 缓冲区偏移
    offset: u32,
};

/// 飞行中的选择批次
const InFlightSelectionBatch = struct {
    /// GPU 同步围栏
    fence: rhi_mod.Fence,
    /// 传输缓冲区
    transfer_buffer: rhi_mod.TransferBuffer,
    /// 回读列表
    readbacks: []InFlightSelectionReadback,

    fn deinit(self: *InFlightSelectionBatch, allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) void {
        device.releaseTransferBuffer(&self.transfer_buffer);
        allocator.free(self.readbacks);
        device.releaseFence(&self.fence);
        self.* = undefined;
    }
};

/// 构建场景提取视锥体
///
/// 从主相机计算视锥体，用于视锥剔除。
fn buildSceneExtractionFrustum(
    scene_cache: *mesh_pass_mod.MeshSceneCache,
    world: *const scene_mod.World,
    width: u32,
    height: u32,
) ?frustum_mod.Frustum {
    if (width == 0 or height == 0) return null;
    const camera_id = world.primaryCameraEntity() orelse return null;
    const camera_entity = world.getEntityConst(camera_id) orelse return null;
    const camera_component = camera_entity.camera orelse return null;
    const world_transform = world.worldTransformConst(camera_id) orelse camera_entity.local_transform;
    const camera_block = mesh_pass_mod.CameraBlock{
        .transform = world_transform,
        .camera = camera_component,
        .is_primary = camera_component.is_primary,
    };
    const view_projection = scene_cache.calculateViewProjection(camera_block, width, height);
    return frustum_mod.Frustum.fromViewProjection(view_projection);
}

fn previewRenderMode(render_mode: types.EditorViewportRenderMode) types.EditorViewportRenderMode {
    return switch (render_mode) {
        .wireframe => .textured,
        else => render_mode,
    };
}

fn effectiveViewportRenderMode(state: types.EditorViewportState) types.EditorViewportRenderMode {
    if (state.pipeline_mode == .path_trace) {
        // PathTrace 模式下仍返回 textured，以保持依赖渲染模式分支的代码路径稳定。
        return .textured;
    }
    return state.render_mode;
}

const PathTraceTriangle = struct {
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
    n0: [3]f32,
    n1: [3]f32,
    n2: [3]f32,
    uv0: [2]f32,
    uv1: [2]f32,
    uv2: [2]f32,
    albedo: [3]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    texture_index: i32, // -1 = no texture, >=0 = index into PathTraceTextureCache.textures
};

const PathTraceTexture = struct {
    pixels: []const u8, // borrowed pointer (owned by TextureResource)
    width: u32,
    height: u32,
};

const PathTraceMesh = struct {
    aabb: AABB,
    tri_start: u32,
    tri_count: u32,
};

/// 渐进式路径追踪状态：每帧只追踪有限扫描行，避免阻塞主线程。
const PathTraceProgressiveState = struct {
    current_scanline: u32 = 0,
    complete: bool = false,
    trace_pixels: ?[]u8 = null,
    display_pixels: ?[]u8 = null,
    trace_width: u32 = 0,
    trace_height: u32 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    // 缓存的场景数据
    triangles: ?[]PathTraceTriangle = null,
    meshes: ?[]PathTraceMesh = null,
    textures: ?[]PathTraceTexture = null,
    inv_view_projection: [16]f32 = mat4_mod.identity(),
    camera_origin: [3]f32 = .{ 0, 0, 0 },
    light_direction: [3]f32 = .{ 0, 1, 0 },
    sample_step: u32 = 1,
    cached_samples: u32 = 0,
    cached_bounces: u32 = 0,
    // 变化检测
    last_view_projection: [16]f32 = mat4_mod.identity(),
    last_samples: u32 = 0,
    last_bounces: u32 = 0,
    last_resolution_scale: f32 = 0.0,

    fn reset(self: *PathTraceProgressiveState, allocator: std.mem.Allocator) void {
        self.current_scanline = 0;
        self.complete = false;
        if (self.triangles) |t| {
            allocator.free(t);
            self.triangles = null;
        }
        if (self.meshes) |m| {
            allocator.free(m);
            self.meshes = null;
        }
        if (self.textures) |tex| {
            allocator.free(tex);
            self.textures = null;
        }
    }

    fn deinit(self: *PathTraceProgressiveState, allocator: std.mem.Allocator) void {
        if (self.trace_pixels) |p| allocator.free(p);
        if (self.display_pixels) |p| allocator.free(p);
        if (self.triangles) |t| allocator.free(t);
        if (self.meshes) |m| allocator.free(m);
        if (self.textures) |tex| allocator.free(tex);
        self.* = .{};
    }
};

/// 硬件 RT 渲染状态（GPU 光追，与平台无关）
const HwRtState = struct {
    triangles: ?[]rt_backend.RtTriangle = null,
    texture_atlas: ?[]u8 = null,
    texture_meta: ?[]rt_backend.RtTextureMeta = null,
    textures_uploaded: bool = false,
    trace_pixels: ?[]u8 = null,
    display_pixels: ?[]u8 = null,
    trace_width: u32 = 0,
    trace_height: u32 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    accel_built: bool = false,
    needs_retrace: bool = true,
    last_view_projection: [16]f32 = mat4_mod.identity(),
    last_samples: u32 = 0,
    last_bounces: u32 = 0,
    last_resolution_scale: f32 = 0.0,

    fn reset(self: *HwRtState, allocator: std.mem.Allocator) void {
        if (self.triangles) |t| allocator.free(t);
        if (self.texture_atlas) |a| allocator.free(a);
        if (self.texture_meta) |m| allocator.free(m);
        self.triangles = null;
        self.texture_atlas = null;
        self.texture_meta = null;
        self.textures_uploaded = false;
        self.accel_built = false;
        self.needs_retrace = true;
    }

    fn deinit(self: *HwRtState, allocator: std.mem.Allocator) void {
        if (self.triangles) |t| allocator.free(t);
        if (self.texture_atlas) |a| allocator.free(a);
        if (self.texture_meta) |m| allocator.free(m);
        if (self.trace_pixels) |p| allocator.free(p);
        if (self.display_pixels) |p| allocator.free(p);
        self.* = .{};
    }
};

fn mulMat4Vec4(matrix: [16]f32, vector: [4]f32) [4]f32 {
    return .{
        matrix[0] * vector[0] + matrix[4] * vector[1] + matrix[8] * vector[2] + matrix[12] * vector[3],
        matrix[1] * vector[0] + matrix[5] * vector[1] + matrix[9] * vector[2] + matrix[13] * vector[3],
        matrix[2] * vector[0] + matrix[6] * vector[1] + matrix[10] * vector[2] + matrix[14] * vector[3],
        matrix[3] * vector[0] + matrix[7] * vector[1] + matrix[11] * vector[2] + matrix[15] * vector[3],
    };
}

fn unprojectNdc(inv_view_projection: [16]f32, ndc_x: f32, ndc_y: f32, ndc_z: f32) [3]f32 {
    const clip = [4]f32{ ndc_x, ndc_y, ndc_z, 1.0 };
    const world = mulMat4Vec4(inv_view_projection, clip);
    const inv_w = if (@abs(world[3]) > 0.000001) 1.0 / world[3] else 1.0;
    return .{ world[0] * inv_w, world[1] * inv_w, world[2] * inv_w };
}

fn hashU32(value: u32) u32 {
    var x = value;
    x ^= x >> 17;
    x *%= 0xed5ad4bb;
    x ^= x >> 11;
    x *%= 0xac4c1b51;
    x ^= x >> 15;
    x *%= 0x31848bab;
    x ^= x >> 14;
    return x;
}

fn hashUnitFloat(seed: u32) f32 {
    const h = hashU32(seed);
    return @as(f32, @floatFromInt(h & 0x00FFFFFF)) / 16777215.0;
}

fn transformPoint(model: [16]f32, p: [3]f32) [3]f32 {
    const w = mulMat4Vec4(model, .{ p[0], p[1], p[2], 1.0 });
    const inv_w = if (@abs(w[3]) > 0.000001) 1.0 / w[3] else 1.0;
    return .{ w[0] * inv_w, w[1] * inv_w, w[2] * inv_w };
}

fn transformNormal(model: [16]f32, n: [3]f32) [3]f32 {
    // Transform normal by upper 3x3 of model matrix (ignoring translation)
    return vec3.normalize(.{
        model[0] * n[0] + model[4] * n[1] + model[8] * n[2],
        model[1] * n[0] + model[5] * n[1] + model[9] * n[2],
        model[2] * n[0] + model[6] * n[1] + model[10] * n[2],
    });
}

const TriangleHit = struct {
    t: f32,
    u: f32,
    v: f32,
};

/// Möller–Trumbore ray-triangle intersection
fn intersectTriangle(origin: [3]f32, direction: [3]f32, tri: PathTraceTriangle, t_min: f32, t_max: f32) ?TriangleHit {
    const edge1 = vec3.sub(tri.v1, tri.v0);
    const edge2 = vec3.sub(tri.v2, tri.v0);
    const h = vec3.cross(direction, edge2);
    const a = vec3.dot(edge1, h);

    if (@abs(a) < 0.0000001) return null; // Ray parallel to triangle

    const f = 1.0 / a;
    const s = vec3.sub(origin, tri.v0);
    const u = f * vec3.dot(s, h);
    if (u < 0.0 or u > 1.0) return null;

    const q = vec3.cross(s, edge1);
    const v = f * vec3.dot(direction, q);
    if (v < 0.0 or u + v > 1.0) return null;

    const t = f * vec3.dot(edge2, q);
    if (t > t_min and t < t_max) {
        return .{ .t = t, .u = u, .v = v };
    }
    return null;
}

fn sampleSky(direction: [3]f32) [3]f32 {
    const horizon = std.math.clamp(direction[1] * 0.5 + 0.5, 0.0, 1.0);
    return .{
        0.12 + 0.42 * horizon,
        0.18 + 0.48 * horizon,
        0.24 + 0.58 * horizon,
    };
}

/// bilinear sample a BGRA8 CPU texture, return linear RGB [0,1]
fn sampleTextureBilinear(tex: PathTraceTexture, u_in: f32, v_in: f32) [3]f32 {
    // Wrap UVs to [0,1)
    var u = u_in - @floor(u_in);
    var v = v_in - @floor(v_in);
    if (u < 0.0) u += 1.0;
    if (v < 0.0) v += 1.0;
    const fx = u * @as(f32, @floatFromInt(tex.width)) - 0.5;
    const fy = v * @as(f32, @floatFromInt(tex.height)) - 0.5;
    const x0_i = @as(i32, @intFromFloat(@floor(fx)));
    const y0_i = @as(i32, @intFromFloat(@floor(fy)));
    const frac_x = fx - @floor(fx);
    const frac_y = fy - @floor(fy);
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);

    const x0: u32 = @intCast(@mod(x0_i, w) + (if (@mod(x0_i, w) < 0) w else @as(i32, 0)));
    const y0: u32 = @intCast(@mod(y0_i, h) + (if (@mod(y0_i, h) < 0) h else @as(i32, 0)));
    const x1: u32 = @intCast(@mod(x0_i + 1, w) + (if (@mod(x0_i + 1, w) < 0) w else @as(i32, 0)));
    const y1: u32 = @intCast(@mod(y0_i + 1, h) + (if (@mod(y0_i + 1, h) < 0) h else @as(i32, 0)));

    const c00 = readTexelBgra(tex, x0, y0);
    const c10 = readTexelBgra(tex, x1, y0);
    const c01 = readTexelBgra(tex, x0, y1);
    const c11 = readTexelBgra(tex, x1, y1);
    return .{
        (c00[0] * (1.0 - frac_x) + c10[0] * frac_x) * (1.0 - frac_y) + (c01[0] * (1.0 - frac_x) + c11[0] * frac_x) * frac_y,
        (c00[1] * (1.0 - frac_x) + c10[1] * frac_x) * (1.0 - frac_y) + (c01[1] * (1.0 - frac_x) + c11[1] * frac_x) * frac_y,
        (c00[2] * (1.0 - frac_x) + c10[2] * frac_x) * (1.0 - frac_y) + (c01[2] * (1.0 - frac_x) + c11[2] * frac_x) * frac_y,
    };
}

fn readTexelBgra(tex: PathTraceTexture, x: u32, y: u32) [3]f32 {
    const idx = (@as(usize, y) * @as(usize, tex.width) + @as(usize, x)) * 4;
    if (idx + 3 >= tex.pixels.len) return [3]f32{ 0.5, 0.5, 0.5 };
    // BGRA8 → linear RGB (approximate sRGB→linear via pow 2.2)
    const b = @as(f32, @floatFromInt(tex.pixels[idx + 0])) / 255.0;
    const g = @as(f32, @floatFromInt(tex.pixels[idx + 1])) / 255.0;
    const r = @as(f32, @floatFromInt(tex.pixels[idx + 2])) / 255.0;
    return .{
        std.math.pow(f32, r, 2.2),
        std.math.pow(f32, g, 2.2),
        std.math.pow(f32, b, 2.2),
    };
}

fn randomHemisphereDirection(normal: [3]f32, seed: u32) [3]f32 {
    const jitter = vec3.normalize(.{
        hashUnitFloat(seed ^ 0x68bc21eb) * 2.0 - 1.0,
        hashUnitFloat(seed ^ 0x02e5be93) * 2.0 - 1.0,
        hashUnitFloat(seed ^ 0xa3d95fa1) * 2.0 - 1.0,
    });
    return vec3.normalize(vec3.add(normal, jitter));
}

fn pathTraceRay(
    origin_start: [3]f32,
    direction_start: [3]f32,
    triangles: []const PathTraceTriangle,
    meshes: []const PathTraceMesh,
    textures: []const PathTraceTexture,
    light_direction: [3]f32,
    seed_base: u32,
    max_bounces: u32,
) [3]f32 {
    var origin = origin_start;
    var direction = direction_start;
    var throughput = [3]f32{ 1.0, 1.0, 1.0 };
    var radiance = [3]f32{ 0.0, 0.0, 0.0 };

    var bounce: u32 = 0;
    while (bounce < max_bounces) : (bounce += 1) {
        var closest_t: f32 = 1.0e30;
        var hit_tri: ?*const PathTraceTriangle = null;
        var hit_u: f32 = 0.0;
        var hit_v: f32 = 0.0;

        // Per-mesh AABB early-out, then scan triangles
        for (meshes) |mesh| {
            if (mesh.aabb.rayIntersection(origin, direction, closest_t) == null) continue;
            const end = mesh.tri_start + mesh.tri_count;
            for (triangles[mesh.tri_start..end]) |*tri| {
                if (intersectTriangle(origin, direction, tri.*, 0.001, closest_t)) |hit| {
                    closest_t = hit.t;
                    hit_tri = tri;
                    hit_u = hit.u;
                    hit_v = hit.v;
                }
            }
        }

        if (hit_tri == null) {
            const sky = sampleSky(direction);
            radiance = vec3.add(radiance, vec3.mul(throughput, sky));
            break;
        }

        const tri = hit_tri.?;
        const hit_pos = vec3.add(origin, vec3.scale(direction, closest_t));

        // Interpolate vertex normal using barycentric coordinates
        const w0 = 1.0 - hit_u - hit_v;
        const normal = vec3.normalize(.{
            w0 * tri.n0[0] + hit_u * tri.n1[0] + hit_v * tri.n2[0],
            w0 * tri.n0[1] + hit_u * tri.n1[1] + hit_v * tri.n2[1],
            w0 * tri.n0[2] + hit_u * tri.n1[2] + hit_v * tri.n2[2],
        });

        // Emissive contribution
        const emissive_strength = tri.emissive[0] + tri.emissive[1] + tri.emissive[2];
        if (emissive_strength > 0.001) {
            radiance = vec3.add(radiance, vec3.mul(throughput, tri.emissive));
        }

        // Resolve surface albedo: texture sample * base_color_factor, or just factor
        const surface_albedo = blk_albedo: {
            if (tri.texture_index >= 0 and @as(usize, @intCast(tri.texture_index)) < textures.len) {
                const uv_u = w0 * tri.uv0[0] + hit_u * tri.uv1[0] + hit_v * tri.uv2[0];
                const uv_v = w0 * tri.uv0[1] + hit_u * tri.uv1[1] + hit_v * tri.uv2[1];
                const tex_color = sampleTextureBilinear(textures[@intCast(tri.texture_index)], uv_u, uv_v);
                break :blk_albedo [3]f32{
                    tex_color[0] * tri.albedo[0],
                    tex_color[1] * tri.albedo[1],
                    tex_color[2] * tri.albedo[2],
                };
            }
            break :blk_albedo tri.albedo;
        };

        // Direct lighting (Lambertian + roughness-based specular)
        const n_dot_l = std.math.clamp(vec3.dot(normal, light_direction), 0.0, 1.0);
        const diffuse = vec3.scale(surface_albedo, n_dot_l * (1.0 - tri.metallic));

        // Simple specular (Blinn-Phong approximation for roughness)
        const halfway = vec3.normalize(vec3.add(light_direction, vec3.scale(direction, -1.0)));
        const n_dot_h = std.math.clamp(vec3.dot(normal, halfway), 0.0, 1.0);
        const spec_power = @max(2.0, 2.0 / (tri.roughness * tri.roughness + 0.001));
        const spec = std.math.pow(f32, n_dot_h, spec_power) * (1.0 - tri.roughness) * 0.4;
        const spec_color = [3]f32{
            surface_albedo[0] * tri.metallic + (1.0 - tri.metallic) * spec,
            surface_albedo[1] * tri.metallic + (1.0 - tri.metallic) * spec,
            surface_albedo[2] * tri.metallic + (1.0 - tri.metallic) * spec,
        };

        const direct_light = [3]f32{
            diffuse[0] + spec_color[0] * n_dot_l,
            diffuse[1] + spec_color[1] * n_dot_l,
            diffuse[2] + spec_color[2] * n_dot_l,
        };

        // Ambient
        const ambient = vec3.scale(surface_albedo, 0.08);
        const combined = vec3.add(direct_light, ambient);
        radiance = vec3.add(radiance, vec3.mul(throughput, combined));

        // Bounce
        throughput = vec3.scale(vec3.mul(throughput, surface_albedo), 0.5);
        if (vec3.length(throughput) < 0.02) {
            break;
        }

        const seed = seed_base ^ (bounce *% 0x9e3779b9);
        direction = randomHemisphereDirection(normal, seed);
        origin = vec3.add(hit_pos, vec3.scale(normal, 0.002));
    }

    return radiance;
}

fn linearToSrgb8(color: [3]f32) [4]u8 {
    const corrected = [3]f32{
        std.math.pow(f32, std.math.clamp(color[0], 0.0, 1.0), 1.0 / 2.2),
        std.math.pow(f32, std.math.clamp(color[1], 0.0, 1.0), 1.0 / 2.2),
        std.math.pow(f32, std.math.clamp(color[2], 0.0, 1.0), 1.0 / 2.2),
    };
    return .{
        @as(u8, @intFromFloat(corrected[2] * 255.0)),
        @as(u8, @intFromFloat(corrected[1] * 255.0)),
        @as(u8, @intFromFloat(corrected[0] * 255.0)),
        255,
    };
}

const SceneViewportState = struct {
    width: u32 = 0,
    height: u32 = 0,
    hdr_color_texture: ?rhi_mod.Texture = null,
    taa_texture: ?rhi_mod.Texture = null,
    ssao_texture: ?rhi_mod.Texture = null,
    contact_shadow_texture: ?rhi_mod.Texture = null,
    bloom_texture: ?rhi_mod.Texture = null,
    fxaa_texture: ?rhi_mod.Texture = null,
    color_texture: ?rhi_mod.Texture = null,
    depth_texture: ?rhi_mod.Texture = null,

    fn deinit(self: *SceneViewportState, device: *rhi_mod.RhiDevice) void {
        if (self.hdr_color_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.taa_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.ssao_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.contact_shadow_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.bloom_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.fxaa_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = .{};
    }

    fn ensure(self: *SceneViewportState, device: *rhi_mod.RhiDevice, width: u32, height: u32) !void {
        if (width == 0 or height == 0) {
            self.deinit(device);
            return;
        }

        if (self.color_texture) |color_texture| {
            if (self.depth_texture != null and self.hdr_color_texture != null and self.taa_texture != null and self.ssao_texture != null and self.contact_shadow_texture != null and self.bloom_texture != null and self.fxaa_texture != null and color_texture.desc.width == width and color_texture.desc.height == height) {
                self.width = width;
                self.height = height;
                return;
            }
        }

        self.deinit(device);

        self.hdr_color_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.hdr_color_texture) |*texture| {
            device.releaseTexture(texture);
            self.hdr_color_texture = null;
        };

        self.taa_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.taa_texture) |*texture| {
            device.releaseTexture(texture);
            self.taa_texture = null;
        };

        self.ssao_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .r8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler | rhi_types.TextureUsage.compute_storage_write,
        });
        errdefer if (self.ssao_texture) |*texture| {
            device.releaseTexture(texture);
            self.ssao_texture = null;
        };

        self.contact_shadow_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .r8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.contact_shadow_texture) |*texture| {
            device.releaseTexture(texture);
            self.contact_shadow_texture = null;
        };

        self.bloom_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.bloom_texture) |*texture| {
            device.releaseTexture(texture);
            self.bloom_texture = null;
        };

        self.fxaa_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.fxaa_texture) |*texture| {
            device.releaseTexture(texture);
            self.fxaa_texture = null;
        };

        self.color_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
            self.color_texture = null;
        };

        self.depth_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .d32_float,
            .usage = rhi_types.TextureUsage.depth_stencil_target | rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
            self.depth_texture = null;
        };

        self.width = width;
        self.height = height;
        render_log.info(
            "viewport textures ready size={d}x{d} hdr_format={s} color_format={s} depth_format={s}",
            .{
                width,
                height,
                @tagName(self.hdr_color_texture.?.desc.format),
                @tagName(self.color_texture.?.desc.format),
                @tagName(self.depth_texture.?.desc.format),
            },
        );
    }

    fn active(self: *const SceneViewportState) bool {
        return self.width > 0 and self.height > 0 and self.hdr_color_texture != null and self.color_texture != null and self.depth_texture != null;
    }

    fn hdrColor(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.hdr_color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn taa(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.taa_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn color(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn bloom(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.bloom_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn ssao(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.ssao_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn contactShadow(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.contact_shadow_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn fxaa(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.fxaa_texture) |*texture| {
            return texture;
        }
        return null;
    }

    fn depth(self: *SceneViewportState) ?*const rhi_mod.Texture {
        if (self.depth_texture) |*texture| {
            return texture;
        }
        return null;
    }
};

const csm_cascade_count = 4;

const ShadowMapState = struct {
    /// Per-cascade shadow map resolution. 2048×2048 per cascade = ~64 MB total VRAM for d32_float.
    size: u32 = 2048,
    depth_textures: [csm_cascade_count]?rhi_mod.Texture = .{ null, null, null, null },
    sampler: ?rhi_mod.Sampler = null,
    /// true = shadow map depth already cleared to 1.0 for RT shadow bypass
    cleared_for_rt: bool = false,

    /// View-space far-plane distance per cascade (computed each frame).
    cascade_splits: [csm_cascade_count]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    /// Light-space view-projection per cascade (computed each frame).
    cascade_matrices: [csm_cascade_count][16]f32 = .{ mat4_mod.identity(), mat4_mod.identity(), mat4_mod.identity(), mat4_mod.identity() },

    fn init(device: *rhi_mod.RhiDevice) !ShadowMapState {
        const size: u32 = 2048;
        var textures: [csm_cascade_count]?rhi_mod.Texture = .{ null, null, null, null };
        errdefer for (&textures) |*t| {
            if (t.*) |*tex| device.releaseTexture(tex);
        };
        for (0..csm_cascade_count) |i| {
            const label: []const u8 = switch (i) {
                0 => "CSM_Cascade0",
                1 => "CSM_Cascade1",
                2 => "CSM_Cascade2",
                3 => "CSM_Cascade3",
                else => unreachable,
            };
            textures[i] = try device.createTexture(.{
                .width = size,
                .height = size,
                .format = .d32_float,
                .usage = rhi_types.TextureUsage.depth_stencil_target | rhi_types.TextureUsage.sampler,
                .label = label,
            });
        }

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .enable_compare = true,
            .compare_op = .less,
        });

        return .{
            .size = size,
            .depth_textures = textures,
            .sampler = sampler,
        };
    }

    fn deinit(self: *ShadowMapState, device: *rhi_mod.RhiDevice) void {
        for (&self.depth_textures) |*texture| {
            if (texture.*) |*tex| {
                device.releaseTexture(tex);
            }
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        self.* = .{};
    }
};

/// Material preview thumbnail resolution (128x128 pixels). Trade-off between visual fidelity (larger = better detail)
/// and texture cache pressure (smaller = more cached thumbnails in VRAM). Value is quadratically dependent on memory:
/// 128^2 * 4 bytes (RGBA8) = 65 KB per thumbnail vs 256^2 * 4 = 262 KB. See material_thumbnail_cache_limit.
const material_thumbnail_dimension: u32 = 128;

/// Number of material thumbnails to process per frame. Limits GPU submission time for thumbnail generation.
/// Chosen to amortize CPU-GPU sync cost while keeping per-frame overhead low (~2ms GPU time typical).
/// Increase if UI remains responsive; decrease if frame time budget is tight.
const material_thumbnail_jobs_per_frame: usize = 2;

/// Maximum number of cached material thumbnails kept in VRAM. Once exceeded, LRU eviction removes oldest.
/// 48 * 128^2 * 4 bytes = ~3 MB VRAM. Adjust based on available VRAM and material palette size.
const material_thumbnail_cache_limit: usize = 48;
const selection_readback_bytes: u32 = 4;
const material_thumbnail_clear_color = [4]f32{ 0.075, 0.08, 0.09, 1.0 };
const ghost_preview_tint_color = [4]f32{ 0.28, 0.94, 0.62, 0.42 };
const ghost_preview_tint_strength: f32 = 0.45;
const thumbnail_viewport_state = EditorViewportState{
    .render_mode = .textured,
    .show_grid = false,
    .show_bones = false,
    .show_collision = false,
};

const MaterialThumbnailTextureFingerprint = struct {
    handle: ?handles.TextureHandle = null,
    width: u32 = 0,
    height: u32 = 0,
    format: rhi_types.TextureFormat = .unknown,
};

const MaterialThumbnailSignature = struct {
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    texture: MaterialThumbnailTextureFingerprint = .{},
};

const MaterialThumbnailSource = struct {
    material_handle: handles.MaterialHandle,
    material: *const material_resource_mod.MaterialResource,
    texture: ?*const texture_resource_mod.TextureResource = null,
    signature: MaterialThumbnailSignature,
};

const ThumbnailRenderTarget = struct {
    color_texture: rhi_mod.Texture,
    depth_texture: rhi_mod.Texture,

    fn init(device: *rhi_mod.RhiDevice) !ThumbnailRenderTarget {
        const color_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
        errdefer {
            var owned = color_texture;
            device.releaseTexture(&owned);
        }

        const depth_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .d32_float,
            .usage = rhi_types.TextureUsage.depth_stencil_target,
        });
        errdefer {
            var owned = depth_texture;
            device.releaseTexture(&owned);
        }

        return .{
            .color_texture = color_texture,
            .depth_texture = depth_texture,
        };
    }

    fn deinit(self: *ThumbnailRenderTarget, device: *rhi_mod.RhiDevice) void {
        device.releaseTexture(&self.color_texture);
        device.releaseTexture(&self.depth_texture);
        self.* = undefined;
    }
};

const MaterialThumbnailCacheEntry = struct {
    asset_id: []u8,
    target: ThumbnailRenderTarget,
    signature: MaterialThumbnailSignature = .{},
    dirty: bool = true,
    queued: bool = false,
    ready: bool = false,
    last_requested_frame: usize = 0,

    fn deinit(self: *MaterialThumbnailCacheEntry, allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) void {
        allocator.free(self.asset_id);
        self.target.deinit(device);
        self.* = undefined;
    }
};

const MaterialThumbnailPreview = struct {
    world: scene_mod.World,
    preview_entity: scene_mod.EntityId,
    preview_material_handle: handles.MaterialHandle,
    preview_texture_handle: ?handles.TextureHandle = null,

    fn init(allocator: std.mem.Allocator) !MaterialThumbnailPreview {
        var world = scene_mod.World.init(allocator, null);
        errdefer world.deinit();

        const sphere_mesh = try world.assets().ensurePrimitiveMesh(.sphere);
        const preview_material_handle = try world.assets().createMaterial(.{
            .name = "ThumbnailMaterial",
            .shading = .pbr_metallic_roughness,
            .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        });

        const preview_entity = try world.createEntity(.{
            .name = "ThumbnailSphere",
            .local_transform = .{
                .rotation = @import("../math/quat.zig").fromEuler(.{ 0.0, 0.42, 0.0 }),
                .scale = .{ 1.08, 1.08, 1.08 },
            },
            .mesh = .{
                .handle = sphere_mesh,
                .primitive = .sphere,
            },
            .material = .{
                .handle = preview_material_handle,
            },
        });

        const camera_position = [3]f32{ 1.8, 1.05, 2.45 };
        _ = try world.createEntity(.{
            .name = "ThumbnailCamera",
            .camera = .{
                .is_primary = true,
                .projection = .{
                    .perspective = .{
                        .fov_y_radians = 0.68,
                        .near_clip = 0.1,
                        .far_clip = 32.0,
                    },
                },
            },
            .local_transform = .{
                .translation = camera_position,
                .rotation = @import("../math/quat.zig").fromEuler(lookRotationEuler(camera_position, .{ 0.0, 0.0, 0.0 })),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailKeyLight",
            .light = .{
                .kind = .directional,
                .color = .{ 1.0, 0.98, 0.94 },
                .intensity = 2.6,
            },
            .local_transform = .{
                .rotation = @import("../math/quat.zig").fromEuler(.{ -0.88, 0.68, 0.0 }),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailFillLight",
            .light = .{
                .kind = .point,
                .color = .{ 0.72, 0.82, 1.0 },
                .intensity = 5.8,
                .range = 8.0,
            },
            .local_transform = .{
                .translation = .{ 1.7, 1.25, 1.2 },
            },
        });

        return .{
            .world = world,
            .preview_entity = preview_entity,
            .preview_material_handle = preview_material_handle,
        };
    }

    fn deinit(self: *MaterialThumbnailPreview) void {
        self.world.deinit();
        self.* = undefined;
    }

    fn syncFromSource(self: *MaterialThumbnailPreview, source: MaterialThumbnailSource) !void {
        var preview_texture_handle: ?handles.TextureHandle = null;
        if (source.texture) |texture| {
            preview_texture_handle = try self.upsertPreviewTexture(texture);
        }

        const material_index = handles.indexOf(self.preview_material_handle);
        const preview_material = &self.world.resources.materials.items[material_index];
        preview_material.shading = source.material.shading;
        preview_material.base_color_factor = source.material.base_color_factor;
        preview_material.base_color_texture = preview_texture_handle;

        if (self.world.getEntity(self.preview_entity)) |entity| {
            entity.material = .{
                .handle = self.preview_material_handle,
                .shading = source.material.shading,
                .base_color_factor = source.material.base_color_factor,
            };
        }
    }

    fn upsertPreviewTexture(
        self: *MaterialThumbnailPreview,
        source_texture: *const texture_resource_mod.TextureResource,
    ) !handles.TextureHandle {
        if (self.preview_texture_handle) |handle| {
            const owned_pixels = try self.world.allocator.dupe(u8, source_texture.pixels);
            errdefer self.world.allocator.free(owned_pixels);

            const preview_texture = &self.world.resources.textures.items[handles.indexOf(handle)];
            self.world.allocator.free(preview_texture.pixels);
            preview_texture.width = source_texture.width;
            preview_texture.height = source_texture.height;
            preview_texture.format = source_texture.format;
            preview_texture.pixels = owned_pixels;
            return handle;
        }

        const created = try self.world.assets().createTexture(.{
            .name = "ThumbnailTexture",
            .width = source_texture.width,
            .height = source_texture.height,
            .format = source_texture.format,
            .pixels = source_texture.pixels,
        });
        self.preview_texture_handle = created;
        return created;
    }
};

/// 渲染器结构体
///
/// Renderer 是渲染系统的核心，管理整个渲染管线。
/// 包含所有渲染通道、GPU 资源和编辑器渲染状态。
///
/// ## 主要组件
///
/// - **RHI 设备** - GPU 资源管理和命令提交
/// - **渲染图** - 自动管理渲染通道依赖
/// - **场景缓存** - 优化场景数据访问
/// - **渲染通道** - 各种渲染通道（阴影、基础、后处理等）
/// - **编辑器支持** - Gizmo、选择、缩略图等
///
/// ## 使用示例
///
/// ```zig
/// // 初始化渲染器
/// var renderer = try Renderer.init(allocator, platform, window, .{});
/// defer renderer.deinit();
///
/// // 渲染帧
/// const report = try renderer.drawFrame(&world, viewport_state);
/// ```
pub const Renderer = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 平台抽象
    platform: platform_mod.Platform,
    /// RHI 设备（GPU 资源管理）
    rhi: rhi_mod.RhiDevice,
    /// 渲染图（管理渲染通道依赖）
    graph: graph_mod.RenderGraph,
    /// 场景缓存（优化场景数据访问）
    scene_cache: mesh_pass_mod.MeshSceneCache,
    /// AI staged preview 场景缓存
    preview_scene_cache: mesh_pass_mod.MeshSceneCache,
    /// 缩略图场景缓存
    thumbnail_scene_cache: mesh_pass_mod.MeshSceneCache,
    /// 渲染世界（提取的场景数据）
    render_world: scene_extraction.RenderWorld,
    /// staged preview 渲染世界
    preview_render_world: scene_extraction.RenderWorld,
    /// 缩略图渲染世界
    thumbnail_render_world: scene_extraction.RenderWorld,
    /// ID 拾取通道（用于编辑器选择）
    id_pass: id_pass_mod.IdPass,
    /// 深度预通道（优化后续渲染）
    depth_prepass: depth_prepass_mod.DepthPrepass,
    /// 阴影通道（阴影贴图渲染）
    shadow_pass: shadow_pass_mod.ShadowPass,
    /// 基础通道（主渲染）
    base_pass: base_pass_mod.BasePass,
    /// 天空盒通道
    skybox_pass: ?skybox_pass_mod.SkyboxPass = null,
    /// 轮廓通道（选中物体高亮）
    outline_pass: outline_pass_mod.OutlinePass,
    /// Gizmo 通道（编辑器可视化）
    gizmo_pass: gizmo_pass_mod.GizmoPass,
    /// SSAO 后处理通道
    ssao_pass: ssao_pass_mod.SSAOPass,
    /// SSAO Compute 通道（GPU Compute 加速）
    ssao_compute_pass: ?ssao_compute_pass_mod.SSAOComputePass = null,
    /// RHI 设备（抽象后端）
    rhi_device: ?*rhi_api.Device = null,
    /// RHI mock 后端存储（仅测试用；生产环境使用 real Metal）
    rhi_mock_backend: ?*rhi_mock_backend_mod.MetalBackend = null,
    /// Real Metal backend device（生产环境使用）
    rhi_metal_device: ?*metal_device_mod.MetalDevice = null,
    /// SDL Metal view handle（需要在 deinit 时销毁）
    sdl_metal_view: sdl.SDL_MetalView = null,
    /// IBL Compute 通道（GPU Compute 加速 BRDF LUT + Irradiance）
    ibl_compute_pass: ?ibl_compute_pass_mod.IBLComputePass = null,
    /// TAA 抗锯齿通道
    taa_pass: taa_pass_mod.TAAPass,
    /// RT 阴影合成通道
    rt_shadow_composite_pass: rt_shadow_composite_pass_mod.RtShadowCompositePass,
    /// SSAO 环境光遮蔽合成通道 — 将 SSAO 纹理以乘法混合叠加到 HDR 缓冲
    ssao_composite_pass: rt_shadow_composite_pass_mod.RtShadowCompositePass,
    /// RT 阴影遮罩纹理（屏幕分辨率，BGRA8）
    rt_shadow_mask_texture: ?rhi_mod.Texture = null,
    /// RT 阴影遮罩像素缓冲 (CPU 侧)
    rt_shadow_pixels: ?[]u8 = null,
    rt_shadow_width: u32 = 0,
    rt_shadow_height: u32 = 0,
    rt_shadow_last_vp: [16]f32 = mat4_mod.identity(),
    /// 选择历史管理
    selection_history: SelectionHistory,
    /// 选择是否已初始化
    selection_seeded: bool = false,
    /// 编辑器 Gizmo 状态
    editor_gizmo_state: EditorGizmoState = .{},
    /// staged preview 的自定义 gizmo 目标
    preview_gizmo_transform: ?components.Transform = null,
    /// staged preview 根实体过滤列表
    preview_entity_filter: std.ArrayList(scene_mod.EntityId) = .empty,
    /// 编辑器视口状态
    editor_viewport_state: EditorViewportState = .{},
    /// 前一帧视图矩阵（TAA 重投影用）
    prev_view_matrix: [16]f32 = mat4_mod.identity(),
    /// 缓存的环境贴图纹理指针（避免每帧重新加载 IBL 数据）
    cached_env_textures: CachedEnvironmentTextures = .{},
    /// 待处理的选择回读请求
    pending_selection_readbacks: std.ArrayList(SelectionReadbackRequest) = .empty,
    /// 飞行中的选择批次
    in_flight_selection_batches: std.ArrayList(InFlightSelectionBatch) = .empty,
    /// 场景视口状态（纹理等）
    scene_viewport: SceneViewportState = .{},
    /// 阴影贴图状态
    shadow_map: ShadowMapState = .{},
    /// 材质缩略图预览
    material_thumbnail_preview: MaterialThumbnailPreview,
    /// 材质缩略图缓存
    material_thumbnail_cache: std.StringHashMap(MaterialThumbnailCacheEntry) = undefined,
    /// 材质缩略图请求队列
    material_thumbnail_requests: std.ArrayList([]u8) = .empty,
    /// 编辑器 staged preview scene
    preview_scene: ?*const scene_mod.Scene = null,
    /// AI Ghost Highlight: 实体 ID 列表（最多 16 个），显示紫色呼吸灯轮廓
    ai_focus_entity_ids: [16]scene_mod.EntityId = .{0} ** 16,
    ai_focus_entity_count: usize = 0,
    /// 渐进式 CPU 路径追踪状态
    path_trace_state: PathTraceProgressiveState = .{},
    /// 硬件 RT 后端（通过 RHI RT 抽象层）
    rt_device: ?rt_device_mod.RtDevice = null,
    /// 硬件 RT 渲染状态
    hw_rt_state: HwRtState = .{},

    /// 初始化渲染器
    ///
    /// ## 参数
    /// - `allocator` - 内存分配器
    /// - `platform` - 平台抽象
    /// - `window` - 窗口（用于创建交换链）
    /// - `config` - 渲染器配置
    ///
    /// ## 返回
    /// 初始化的 Renderer 实例
    ///
    /// ## 错误
    /// - `error.OutOfMemory` - 内存不足
    /// - `error.DeviceCreationFailed` - GPU 设备创建失败
    pub fn init(
        allocator: std.mem.Allocator,
        platform: platform_mod.Platform,
        window: *window_mod.Window,
        config: RendererConfig,
    ) !Renderer {
        var renderer = Renderer{
            .allocator = allocator,
            .platform = platform,
            .rhi = try rhi_mod.RhiDevice.init(
                allocator,
                platform,
                window,
                .{
                    .preferred_backends = config.requested_backends,
                    .selection_policy = config.selection_policy,
                    .enable_validation = config.enable_validation,
                    .frames_in_flight = config.frames_in_flight,
                },
            ),
            .graph = try graph_mod.RenderGraph.initDefault3D(allocator),
            .scene_cache = undefined,
            .preview_scene_cache = undefined,
            .thumbnail_scene_cache = undefined,
            .render_world = scene_extraction.RenderWorld.init(allocator),
            .preview_render_world = scene_extraction.RenderWorld.init(allocator),
            .thumbnail_render_world = scene_extraction.RenderWorld.init(allocator),
            .id_pass = undefined,
            .depth_prepass = undefined,
            .shadow_pass = undefined,
            .base_pass = undefined,
            .skybox_pass = undefined,
            .outline_pass = undefined,
            .gizmo_pass = undefined,
            .ssao_pass = undefined,
            .ssao_compute_pass = null,
            .ibl_compute_pass = null,
            .taa_pass = undefined,
            .rt_shadow_composite_pass = undefined,
            .ssao_composite_pass = undefined,
            .selection_history = SelectionHistory.init(allocator, 64),
            .material_thumbnail_cache = std.StringHashMap(MaterialThumbnailCacheEntry).init(allocator),
            .material_thumbnail_preview = undefined,
        };
        errdefer renderer.material_thumbnail_cache.deinit();
        errdefer renderer.in_flight_selection_batches.deinit(allocator);
        errdefer renderer.pending_selection_readbacks.deinit(allocator);
        errdefer renderer.selection_history.deinit();
        errdefer renderer.graph.deinit();
        errdefer renderer.rhi.deinit();

        renderer.scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.scene_cache.deinit(&renderer.rhi);

        renderer.preview_scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.preview_scene_cache.deinit(&renderer.rhi);

        renderer.thumbnail_scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.thumbnail_scene_cache.deinit(&renderer.rhi);

        renderer.material_thumbnail_preview = try MaterialThumbnailPreview.init(allocator);
        errdefer renderer.material_thumbnail_preview.deinit();

        renderer.id_pass = try id_pass_mod.IdPass.init(&renderer.rhi);
        errdefer renderer.id_pass.deinit(&renderer.rhi);

        renderer.depth_prepass = try depth_prepass_mod.DepthPrepass.init(&renderer.rhi);
        errdefer renderer.depth_prepass.deinit(&renderer.rhi);

        renderer.shadow_pass = try shadow_pass_mod.ShadowPass.init(&renderer.rhi);
        errdefer renderer.shadow_pass.deinit(&renderer.rhi);

        renderer.shadow_map = try ShadowMapState.init(&renderer.rhi);
        errdefer renderer.shadow_map.deinit(&renderer.rhi);

        renderer.base_pass = try base_pass_mod.BasePass.init(&renderer.rhi);
        errdefer renderer.base_pass.deinit(&renderer.rhi);

        renderer.skybox_pass = try skybox_pass_mod.SkyboxPass.init(&renderer.rhi);
        errdefer if (renderer.skybox_pass) |*pass| {
            pass.deinit(&renderer.rhi);
        };

        renderer.ssao_pass = try ssao_pass_mod.SSAOPass.init(&renderer.rhi);
        errdefer renderer.ssao_pass.deinit(&renderer.rhi);

        renderer.ssao_compute_pass = ssao_compute_pass_mod.SSAOComputePass.init(&renderer.rhi) catch |err| blk: {
            std.log.warn("SSAO compute pass init failed (falling back to fragment): {}", .{err});
            break :blk null;
        };

        renderer.ibl_compute_pass = blk: {
            const p = ibl_compute_pass_mod.IBLComputePass.init(&renderer.rhi);
            if (!p.hasBRDF() and !p.hasIrradiance()) {
                std.log.warn("IBL compute pass: no pipelines available, GPU IBL disabled", .{});
                break :blk null;
            }
            break :blk p;
        };

        renderer.taa_pass = try taa_pass_mod.TAAPass.init(&renderer.rhi);
        errdefer renderer.taa_pass.deinit(&renderer.rhi);

        renderer.rt_shadow_composite_pass = try rt_shadow_composite_pass_mod.RtShadowCompositePass.init(&renderer.rhi);
        errdefer renderer.rt_shadow_composite_pass.deinit(&renderer.rhi);

        // SSAO 合成通道复用 RT 阴影合成的 multiply-blend 管线
        renderer.ssao_composite_pass = try rt_shadow_composite_pass_mod.RtShadowCompositePass.init(&renderer.rhi);
        errdefer renderer.ssao_composite_pass.deinit(&renderer.rhi);

        // RHI Metal backend — real GPU via ObjC++ bridge on macOS,
        // falls back to mock MetalBackend otherwise.
        rhi_init: {
            if (comptime @import("builtin").os.tag == .macos) {
                const md_ptr = allocator.create(metal_device_mod.MetalDevice) catch break :rhi_init;
                const md = metal_device_mod.MetalDevice.init(allocator) orelse {
                    allocator.destroy(md_ptr);
                    break :rhi_init;
                };
                md_ptr.* = md;

                // Create SDL Metal view & obtain CAMetalLayer
                const metal_view = sdl.SDL_Metal_CreateView(window.handle);
                if (metal_view) |view| {
                    renderer.sdl_metal_view = view;
                    if (sdl.SDL_Metal_GetLayer(view)) |layer| {
                        md_ptr.setLayer(layer);
                    }
                }

                const dev_ptr = allocator.create(rhi_api.Device) catch {
                    md_ptr.deinit();
                    allocator.destroy(md_ptr);
                    break :rhi_init;
                };
                dev_ptr.* = md_ptr.createDevice();
                renderer.rhi_metal_device = md_ptr;
                renderer.rhi_device = dev_ptr;

                // Pre-create tonemap layouts
                if (tonemap_pass_mod.TonemapPass.createLayouts(dev_ptr)) |layouts| {
                    if (dev_ptr.resolvePipelineLayout(&.{ layouts.hdr_layout, layouts.bloom_layout, layouts.uniform_layout })) |_| {
                        renderer.graph.setPassBindingConstraints(.tonemap_pass, &.{
                            .{ .slot = 0, .expected_layout_id = layouts.hdr_layout.id },
                            .{ .slot = 1, .expected_layout_id = layouts.bloom_layout.id },
                            .{ .slot = 2, .expected_layout_id = layouts.uniform_layout.id },
                        }) catch {};
                    } else |_| {}
                } else |_| {}
            } else {
                // Non-macOS: use mock backend
                const backend_ptr = allocator.create(rhi_mock_backend_mod.MetalBackend) catch break :rhi_init;
                backend_ptr.* = rhi_mock_backend_mod.MetalBackend.init(allocator);
                const dev_ptr = allocator.create(rhi_api.Device) catch {
                    backend_ptr.deinit();
                    allocator.destroy(backend_ptr);
                    break :rhi_init;
                };
                dev_ptr.* = backend_ptr.createDevice();
                renderer.rhi_mock_backend = backend_ptr;
                renderer.rhi_device = dev_ptr;

                if (tonemap_pass_mod.TonemapPass.createLayouts(dev_ptr)) |layouts| {
                    if (dev_ptr.resolvePipelineLayout(&.{ layouts.hdr_layout, layouts.bloom_layout, layouts.uniform_layout })) |_| {
                        renderer.graph.setPassBindingConstraints(.tonemap_pass, &.{
                            .{ .slot = 0, .expected_layout_id = layouts.hdr_layout.id },
                            .{ .slot = 1, .expected_layout_id = layouts.bloom_layout.id },
                            .{ .slot = 2, .expected_layout_id = layouts.uniform_layout.id },
                        }) catch {};
                    } else |_| {}
                } else |_| {}
            }
        }

        renderer.outline_pass = try outline_pass_mod.OutlinePass.init(&renderer.rhi);
        errdefer renderer.outline_pass.deinit(&renderer.rhi);

        renderer.gizmo_pass = try gizmo_pass_mod.GizmoPass.init(&renderer.rhi);
        renderer.graph.writeExports("dist/reports/render_graph.dot", "dist/reports/render_graph.json") catch |err| {
            std.log.warn("failed to write render graph exports: {}", .{err});
        };
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.path_trace_state.deinit(self.allocator);
        self.hw_rt_state.deinit(self.allocator);
        if (self.rt_device) |*d| d.deinit();
        self.releaseInFlightSelectionBatches();
        self.pending_selection_readbacks.deinit(self.allocator);
        self.selection_history.deinit();
        self.preview_entity_filter.deinit(self.allocator);
        self.scene_viewport.deinit(&self.rhi);
        self.releaseMaterialThumbnailRequests();
        self.releaseMaterialThumbnailCache();
        self.material_thumbnail_preview.deinit();
        self.thumbnail_scene_cache.deinit(&self.rhi);
        self.preview_scene_cache.deinit(&self.rhi);
        if (self.skybox_pass) |*pass| {
            pass.deinit(&self.rhi);
        }
        self.ssao_pass.deinit(&self.rhi);
        if (self.ssao_compute_pass) |*p| p.deinit(&self.rhi);
        if (self.ibl_compute_pass) |*p| p.deinit(&self.rhi);
        self.taa_pass.deinit(&self.rhi);
        self.rt_shadow_composite_pass.deinit(&self.rhi);
        self.ssao_composite_pass.deinit(&self.rhi);
        if (self.rt_shadow_mask_texture) |*t| self.rhi.releaseTexture(t);
        if (self.rt_shadow_pixels) |p| self.allocator.free(p);
        if (self.rhi_device) |dp| {
            dp.deinit();
            self.allocator.destroy(dp);
        }
        if (self.rhi_metal_device) |md| {
            md.deinit();
            self.allocator.destroy(md);
        }
        if (self.sdl_metal_view != null) {
            sdl.SDL_Metal_DestroyView(self.sdl_metal_view);
        }
        if (self.rhi_mock_backend) |bp| {
            bp.deinit();
            self.allocator.destroy(bp);
        }
        self.gizmo_pass.deinit(&self.rhi);
        self.outline_pass.deinit(&self.rhi);
        self.base_pass.deinit(&self.rhi);
        self.shadow_map.deinit(&self.rhi);
        self.shadow_pass.deinit(&self.rhi);
        self.depth_prepass.deinit(&self.rhi);
        self.id_pass.deinit(&self.rhi);
        self.scene_cache.deinit(&self.rhi);
        self.thumbnail_render_world.deinit();
        self.preview_render_world.deinit();
        self.render_world.deinit();
        self.rhi.deinit();
        self.graph.deinit();
    }

    pub fn backendApi(self: *const Renderer) rhi_types.GraphicsAPI {
        return self.rhi.api;
    }

    pub fn runtimeInfo(self: *const Renderer) types.RuntimeInfo {
        return self.rhi.runtimeInfo();
    }

    pub fn device(self: *Renderer) *rhi_mod.RhiDevice {
        return &self.rhi;
    }

    pub fn handleResize(self: *Renderer, width: u32, height: u32) !void {
        try self.rhi.resize(width, height);
    }

    pub fn requestSelectionReadback(
        self: *Renderer,
        pixel_x: u32,
        pixel_y: u32,
        mode: SelectionUpdateMode,
    ) !void {
        try self.pending_selection_readbacks.append(self.allocator, .{
            .pixel_x = pixel_x,
            .pixel_y = pixel_y,
            .mode = mode,
        });
        self.selection_seeded = true;
    }

    /// 设置 AI 聚焦实体（Ghost Highlight），渲染时显示紫色呼吸灯轮廓
    pub fn setAiFocusEntities(self: *Renderer, ids: []const scene_mod.EntityId) void {
        const count = @min(ids.len, self.ai_focus_entity_ids.len);
        @memcpy(self.ai_focus_entity_ids[0..count], ids[0..count]);
        self.ai_focus_entity_count = count;
    }

    /// 清除 AI 聚焦实体列表
    pub fn clearAiFocusEntities(self: *Renderer) void {
        self.ai_focus_entity_count = 0;
    }

    pub fn selectedEntity(self: *const Renderer) ?scene_mod.EntityId {
        return self.selection_history.primarySelection();
    }

    pub fn selectedEntities(self: *const Renderer) []const scene_mod.EntityId {
        return self.selection_history.currentSelection();
    }

    pub fn resetSceneState(self: *Renderer) !void {
        self.releaseInFlightSelectionBatches();
        self.in_flight_selection_batches = .empty;
        self.pending_selection_readbacks.deinit(self.allocator);
        self.pending_selection_readbacks = .empty;
        self.selection_history.deinit();
        self.selection_history = SelectionHistory.init(self.allocator, 64);
        self.selection_seeded = false;
        self.releaseMaterialThumbnailRequests();
        self.releaseMaterialThumbnailCache();
        self.thumbnail_scene_cache.invalidateMaterialResources(&self.rhi);
        self.preview_scene_cache.deinit(&self.rhi);
        self.preview_scene_cache = try mesh_pass_mod.MeshSceneCache.init(self.allocator, &self.rhi);
        self.scene_cache.deinit(&self.rhi);
        self.scene_cache = try mesh_pass_mod.MeshSceneCache.init(self.allocator, &self.rhi);
        self.preview_scene = null;
        self.preview_gizmo_transform = null;
        self.preview_entity_filter.clearRetainingCapacity();
    }

    pub fn replaceSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .replace);
        self.selection_seeded = true;
    }

    pub fn replaceSelectionMany(self: *Renderer, entities: []const scene_mod.EntityId) !void {
        _ = try self.selection_history.replaceSelection(entities);
        self.selection_seeded = true;
    }

    pub fn toggleSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .toggle);
        self.selection_seeded = true;
    }

    pub fn setEditorGizmoState(self: *Renderer, state: EditorGizmoState) void {
        self.editor_gizmo_state = state;
    }

    pub fn setPreviewGizmoTransform(self: *Renderer, transform: ?components.Transform) void {
        self.preview_gizmo_transform = transform;
    }

    pub fn setPreviewEntityFilter(self: *Renderer, entity_ids: []const scene_mod.EntityId) !void {
        self.preview_entity_filter.clearRetainingCapacity();
        try self.preview_entity_filter.appendSlice(self.allocator, entity_ids);
    }

    pub fn clearPreviewEntityFilter(self: *Renderer) void {
        self.preview_entity_filter.clearRetainingCapacity();
    }

    /// Reset progressive path trace state so the next frame in PathTrace mode
    /// starts a fresh render.  Called on explicit Raster→PathTrace mode switch.
    pub fn resetPathTraceState(self: *Renderer) void {
        self.path_trace_state.reset(self.allocator);
        // Zero out last_view_projection so change detection triggers re-cache
        self.path_trace_state.last_view_projection = mat4_mod.identity();
        self.path_trace_state.last_samples = 0;
        self.path_trace_state.last_bounces = 0;
        self.path_trace_state.last_resolution_scale = 0.0;
        // 同时重置 HW RT 状态，使 GPU 路径也从头开始
        self.hw_rt_state.reset(self.allocator);
        self.hw_rt_state.needs_retrace = true;
        self.hw_rt_state.last_view_projection = mat4_mod.identity();
        self.hw_rt_state.last_samples = 0;
        self.hw_rt_state.last_bounces = 0;
        self.hw_rt_state.last_resolution_scale = 0.0;
    }

    pub fn setEditorViewportState(self: *Renderer, state: EditorViewportState) void {
        if (g_logged_postfx_state == null or
            g_logged_postfx_state.?.exposure_enabled != state.exposure_enabled or
            @abs(g_logged_postfx_state.?.exposure - state.exposure) > 0.0001 or
            g_logged_postfx_state.?.bloom_enabled != state.bloom_enabled or
            @abs(g_logged_postfx_state.?.bloom_threshold - state.bloom_threshold) > 0.0001 or
            @abs(g_logged_postfx_state.?.bloom_intensity - state.bloom_intensity) > 0.0001 or
            g_logged_postfx_state.?.color_grading_enabled != state.color_grading_enabled or
            @abs(g_logged_postfx_state.?.color_grading_saturation - state.color_grading_saturation) > 0.0001 or
            @abs(g_logged_postfx_state.?.color_grading_contrast - state.color_grading_contrast) > 0.0001 or
            @abs(g_logged_postfx_state.?.color_grading_gamma - state.color_grading_gamma) > 0.0001 or
            g_logged_postfx_state.?.fxaa_enabled != state.fxaa_enabled or
            g_logged_postfx_state.?.lut_enabled != state.lut_enabled or
            @abs(g_logged_postfx_state.?.lut_intensity - state.lut_intensity) > 0.0001 or
            g_logged_postfx_state.?.lut_preset != state.lut_preset)
        {
            render_log.info(
                "viewport postfx updated exposure_enabled={} exposure={d:.2} bloom_enabled={} bloom_threshold={d:.2} bloom_intensity={d:.2} color_grading_enabled={} saturation={d:.2} contrast={d:.2} gamma={d:.2} fxaa_enabled={} lut_enabled={} lut_intensity={d:.2} lut_preset={s}",
                .{
                    state.exposure_enabled,
                    state.exposure,
                    state.bloom_enabled,
                    state.bloom_threshold,
                    state.bloom_intensity,
                    state.color_grading_enabled,
                    state.color_grading_saturation,
                    state.color_grading_contrast,
                    state.color_grading_gamma,
                    state.fxaa_enabled,
                    state.lut_enabled,
                    state.lut_intensity,
                    @tagName(state.lut_preset),
                },
            );
            g_logged_postfx_state = state;
        }
        self.editor_viewport_state = state;
    }

    pub fn setPreviewScene(self: *Renderer, scene: ?*const scene_mod.Scene) void {
        self.preview_scene = scene;
    }

    pub fn setSceneViewportSize(self: *Renderer, width: u32, height: u32) !void {
        try self.scene_viewport.ensure(&self.rhi, width, height);
    }

    pub fn sceneViewportTexture(self: *Renderer) ?*const rhi_mod.Texture {
        if (self.scene_viewport.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn sceneViewportSize(self: *const Renderer) [2]u32 {
        return .{ self.scene_viewport.width, self.scene_viewport.height };
    }

    pub fn passCount(self: *const Renderer) usize {
        return self.graph.passCount();
    }

    pub fn requestMaterialThumbnail(self: *Renderer, scene: *const scene_mod.Scene, asset_id: []const u8, frame_index: usize) !void {
        const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
            self.removeMaterialThumbnail(asset_id);
            return;
        };

        const entry = try self.ensureMaterialThumbnailEntry(asset_id);
        entry.last_requested_frame = frame_index;
        if (!std.meta.eql(entry.signature, source.signature)) {
            entry.signature = source.signature;
            entry.dirty = true;
        }
        if (entry.dirty and !entry.queued) {
            try self.enqueueMaterialThumbnailRequest(entry);
        }
    }

    pub fn materialThumbnailTexture(self: *const Renderer, asset_id: []const u8) ?*const rhi_mod.Texture {
        const entry = self.findMaterialThumbnailCacheIndex(asset_id) orelse return null;
        if (!entry.ready) {
            return null;
        }
        return &entry.target.color_texture;
    }

    /// Renders a complete frame: processes scene data, executes render graph passes, and returns statistics.
    ///
    /// Parameters:
    /// - `scene`: Scene snapshot containing visible entities, lights, and cameras.
    /// - `physics_state_opt`: Optional physics state for collision geometry rendering (debug visualization).
    ///
    /// Returns: FrameReport with per-pass statistics (execution time, draw calls, triangles),
    /// scene snapshot, and GPU runtime info (backend, total VRAM).
    ///
    /// Side-effects:
    /// - Submits GPU work to RHI device (non-blocking from CPU perspective).
    /// - Updates material thumbnail cache (processes material_thumbnail_jobs_per_frame thumbnails).
    /// - Processes selection readbacks from previous frame (object picking for editor).
    /// - May trigger async resource compilations (shaders, pipelines) on first use.
    ///
    /// Errors:
    /// - Most errors are logged and result in a degraded frame (e.g., failed to compile shader).
    /// - Returning error means GPU submission failed; caller should skip present or retry next frame.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from render thread (typically main thread).
    /// Scene pointer must remain valid until GPU work completes (typically 1-2 frames later).
    pub fn drawFrame(self: *Renderer, scene: *scene_mod.Scene, physics_state_opt: ?*physics_mod.PhysicsState) !FrameReport {
        try self.resolveSelectionReadbacks();

        const pass_stats = try self.graph.allocatePassStats(self.allocator);
        defer self.allocator.free(pass_stats);

        const snapshot = buildSceneSnapshot(scene);
        const result = blk: {
            const frame = try self.rhi.beginFrame();
            const clear = clearAndDepthForScene(snapshot, self.passCount());
            const has_swapchain = frame.swapchain_image.id != 0;

            if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
                if (has_swapchain) {
                    try self.rhi.clearAndPresent(frame, clear);
                } else {
                    try self.rhi.submitFrame(frame);
                }
                break :blk FrameReport{
                    .backend = self.rhi.api,
                    .passes_executed = self.passCount(),
                    .graph_resources = self.graph.resourceCount(),
                    .scene = snapshot,
                    .runtime = self.runtimeInfo(),
                };
            }

            const viewport_active = self.scene_viewport.active();
            const can_render_scene = viewport_active or has_swapchain;
            const render_width = if (viewport_active) self.scene_viewport.width else frame.swapchain_image.width;
            const render_height = if (viewport_active) self.scene_viewport.height else frame.swapchain_image.height;
            var draw_stats = mesh_pass_mod.DrawStats{};

            if (can_render_scene) {
                if (!g_logged_viewport_backend) {
                    render_log.info(
                        "draw frame backend={s} viewport_active={} swapchain={} rhi_device={} skybox_ready={}",
                        .{
                            @tagName(self.rhi.api),
                            viewport_active,
                            has_swapchain,
                            self.rhi_device != null,
                            if (self.skybox_pass) |*pass| pass.isReady() else false,
                        },
                    );
                    g_logged_viewport_backend = true;
                }
                const extraction_frustum = buildSceneExtractionFrustum(&self.scene_cache, scene, render_width, render_height);
                const extraction_stats = try scene_extraction.extractWorld(
                    scene,
                    &self.render_world,
                    self.selection_history.primarySelection(),
                    self.selection_history.currentSelection(),
                    extraction_frustum,
                );
                if (extraction_frustum != null and !g_logged_scene_extraction_culling) {
                    render_log.info(
                        "scene extraction culling active candidates={} meshes={}/{} culled={} vfx={}/{} culled={}",
                        .{
                            extraction_stats.frustum_candidates,
                            extraction_stats.extracted_meshes,
                            extraction_stats.total_meshes,
                            extraction_stats.culledMeshes(),
                            extraction_stats.extracted_vfxs,
                            extraction_stats.total_vfxs,
                            extraction_stats.culledVfxs(),
                        },
                    );
                    g_logged_scene_extraction_culling = true;
                }

                var prepared_scene = try self.scene_cache.prepareScene(
                    &self.rhi,
                    scene,
                    &self.render_world,
                    render_width,
                    render_height,
                );
                defer prepared_scene.deinit();

                if (!self.selection_seeded) {
                    _ = try self.selection_history.applyPick(
                        self.scene_cache.defaultSelectionEntity(scene),
                        .replace,
                    );
                    self.selection_seeded = true;
                }

                try self.id_pass.ensureTargetSize(&self.rhi, render_width, render_height);

                const light_space_matrix = blk_lsm: {
                    const main_light = if (prepared_scene.lights.directional_lights.len > 0)
                        prepared_scene.lights.directional_lights[0]
                    else
                        mesh_pass_mod.DirectionalLightBlock{ .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }), .color = .{ 1.0, 0.98, 0.92 }, .intensity = 1.6 };

                    const light_dir = vec3.normalize(main_light.direction);

                    // Camera near/far from projection
                    const cam_proj = prepared_scene.camera.camera.projection;
                    const cam_near = switch (cam_proj) {
                        .perspective => |p| p.near_clip,
                        .orthographic => |o| o.near_clip,
                    };
                    const cam_far = switch (cam_proj) {
                        .perspective => |p| p.far_clip,
                        .orthographic => |o| o.far_clip,
                    };

                    // Inverse VP for extracting frustum corners
                    const inv_vp = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
                    const texel_size = @as(f32, @floatFromInt(self.shadow_map.size));

                    // Compute cascade splits (practical-split-scheme, lambda=0.7)
                    const splits = computeCascadeSplits(cam_near, cam_far, csm_cascade_count, 0.7);
                    self.shadow_map.cascade_splits = splits;

                    // Compute per-cascade matrices
                    var first_mat: [16]f32 = mat4_mod.identity();
                    for (0..csm_cascade_count) |ci| {
                        const split_near = if (ci == 0) cam_near else splits[ci - 1];
                        const split_far = splits[ci];
                        const cascade_mat = computeCascadeMatrix(inv_vp, split_near, split_far, cam_near, cam_far, light_dir, texel_size);
                        self.shadow_map.cascade_matrices[ci] = cascade_mat;
                        if (ci == 0) first_mat = cascade_mat;
                    }

                    // Legacy: keep first cascade as the main light_space_matrix for backward compat
                    break :blk_lsm first_mat;
                };
                prepared_scene.light_space_matrix = light_space_matrix;
                prepared_scene.cascade_matrices = self.shadow_map.cascade_matrices;
                prepared_scene.cascade_splits = self.shadow_map.cascade_splits;
                for (0..csm_cascade_count) |ci| {
                    prepared_scene.shadow_maps[ci] = &self.shadow_map.depth_textures[ci].?;
                }
                prepared_scene.shadow_sampler = &self.shadow_map.sampler.?;
                try resolveEnvironmentTextures(self, scene, &prepared_scene);

                var prepared_preview_scene: mesh_pass_mod.PreparedScene = undefined;
                var has_prepared_preview_scene = false;
                defer if (has_prepared_preview_scene) {
                    prepared_preview_scene.deinit();
                };
                if (viewport_active and self.preview_scene != null and self.preview_entity_filter.items.len > 0) {
                    const preview_frustum = frustum_mod.Frustum.fromViewProjection(prepared_scene.view_projection);
                    _ = try scene_extraction.extractWorld(
                        @constCast(self.preview_scene.?),
                        &self.preview_render_world,
                        null,
                        &.{},
                        preview_frustum,
                    );
                    prepared_preview_scene = try self.preview_scene_cache.preparePreviewScene(
                        &self.rhi,
                        self.preview_scene.?,
                        &self.preview_render_world,
                        &prepared_scene,
                        self.preview_entity_filter.items,
                    );
                    has_prepared_preview_scene = true;
                }

                const path_trace_viewport = viewport_active and self.editor_viewport_state.pipeline_mode == .path_trace;

                // scene_color_target 在所有模式下都需要（用于 overlay passes: gizmo, outline, debug）
                const scene_color_target: rhi_mod.ColorTarget = if (viewport_active)
                    .{ .texture = self.scene_viewport.color().? }
                else
                    .swapchain;

                if (path_trace_viewport) {
                    const path_trace_start = std.time.nanoTimestamp();
                    try self.renderPathTraceViewport(&prepared_scene, scene);
                    self.graph.recordPassStat(pass_stats, .base_pass, durationNs(path_trace_start, std.time.nanoTimestamp()), 0, 0);
                } else {
                    const scene_hdr_color_target: rhi_mod.ColorTarget = if (viewport_active)
                        .{ .texture = self.scene_viewport.hdrColor().? }
                    else
                        .swapchain;
                    const scene_depth_target: ?rhi_mod.DepthAttachmentDesc = blk_depth: {
                        const depth_texture = if (viewport_active)
                            self.scene_viewport.depth().?
                        else
                            self.rhi.depthTexture() orelse break :blk_depth null;
                        break :blk_depth .{
                            .texture = depth_texture,
                            .clear_depth = 1.0,
                            .clear_stencil = 0,
                            .load_op = .clear,
                            .store_op = .dont_care,
                            .stencil_load_op = .dont_care,
                            .stencil_store_op = .dont_care,
                        };
                    };

                    // RT Shadows: 当 rt_shadows_enabled 且硬件 RT 可用时，
                    // 用 RT 阴影遮罩替换 shadow map，跳过常规阴影渲染。
                    const rt_shadows_active = viewport_active and
                        self.editor_viewport_state.rt_shadows_enabled and
                        self.tryRenderRtShadows(&prepared_scene, scene, self.scene_viewport.width, self.scene_viewport.height);

                    if (self.shadow_pass.isReady()) {
                        if (rt_shadows_active) {
                            // RT shadows 激活：首次清除 depth=1.0（mesh shader 得到 shadow=1.0），
                            // 后续帧完全跳过 shadow pass
                            if (!self.shadow_map.cleared_for_rt) {
                                for (0..csm_cascade_count) |ci| {
                                    const rp = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.shadowOnly(&self.shadow_map.depth_textures[ci].?));
                                    self.rhi.endRenderPass(rp);
                                }
                                self.shadow_map.cleared_for_rt = true;
                            }
                        } else {
                            self.shadow_map.cleared_for_rt = false;
                            const shadow_start = std.time.nanoTimestamp();
                            var cascade_stats = mesh_pass_mod.DrawStats{};
                            for (0..csm_cascade_count) |ci| {
                                const shadow_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.shadowOnly(&self.shadow_map.depth_textures[ci].?));
                                const cs = self.shadow_pass.draw(&self.rhi, frame, shadow_render_pass, &prepared_scene, self.shadow_map.cascade_matrices[ci]);
                                cascade_stats.add(cs);
                                self.rhi.endRenderPass(shadow_render_pass);
                            }
                            self.graph.recordPassStat(pass_stats, .shadow_map, durationNs(shadow_start, std.time.nanoTimestamp()), cascade_stats.draw_calls, cascade_stats.triangles_drawn);
                            draw_stats.add(cascade_stats);
                        }
                    }

                    if (self.id_pass.isReady()) {
                        const id_texture = self.id_pass.texture().?;
                        const id_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.idPass(id_texture, scene_depth_target));
                        const start = std.time.nanoTimestamp();
                        const id_stats = self.id_pass.draw(&self.rhi, frame, id_render_pass, &prepared_scene);
                        self.graph.recordPassStat(pass_stats, .id_pass, durationNs(start, std.time.nanoTimestamp()), id_stats.draw_calls, id_stats.triangles_drawn);
                        draw_stats.add(id_stats);
                        self.rhi.endRenderPass(id_render_pass);
                    }

                    const base_pass_target = if (viewport_active) scene_hdr_color_target else scene_color_target;

                    // TAA jitter: apply subpixel offset to projection matrix before rendering
                    const taa_enabled = viewport_active and self.editor_viewport_state.taa_enabled and self.taa_pass.isReady() and self.scene_viewport.taa() != null;
                    const unjittered_projection = prepared_scene.projection_matrix;
                    if (taa_enabled) {
                        const jitter = self.taa_pass.getJitter();
                        const jx = jitter[0] / @as(f32, @floatFromInt(self.scene_viewport.width));
                        const jy = jitter[1] / @as(f32, @floatFromInt(self.scene_viewport.height));
                        // Offset the projection matrix translation column (indices 12,13 in row-major = [3][0],[3][1] in col-major)
                        prepared_scene.projection_matrix[8] += jx * 2.0;
                        prepared_scene.projection_matrix[9] += jy * 2.0;
                        prepared_scene.view_projection = mat4_mod.mul(prepared_scene.projection_matrix, prepared_scene.view_matrix);
                    }

                    const scene_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.colorWithDepth(base_pass_target, clear.color, scene_depth_target));
                    const active_render_mode = effectiveViewportRenderMode(self.editor_viewport_state);
                    const depth_start = std.time.nanoTimestamp();
                    const depth_stats = if (active_render_mode != .wireframe)
                        self.depth_prepass.draw(&self.rhi, frame, scene_pass, &prepared_scene)
                    else
                        mesh_pass_mod.DrawStats{};
                    self.graph.recordPassStat(pass_stats, .depth_prepass, durationNs(depth_start, std.time.nanoTimestamp()), depth_stats.draw_calls, depth_stats.triangles_drawn);
                    draw_stats.add(depth_stats);

                    const opaque_start = std.time.nanoTimestamp();
                    const opaque_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, .{
                        .render_mode = active_render_mode,
                        .target = if (viewport_active) .hdr else .ldr,
                        .phase = .opaque_pass,
                    });
                    self.graph.recordPassStat(pass_stats, .base_pass, durationNs(opaque_start, std.time.nanoTimestamp()), opaque_stats.draw_calls, opaque_stats.triangles_drawn);
                    draw_stats.add(opaque_stats);

                    if (self.skybox_pass) |*skybox_pass| {
                        if (skybox_pass.isReady() and prepared_scene.environment_map != null) {
                            const skybox_start = std.time.nanoTimestamp();
                            skybox_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, prepared_scene.environment_map.?);
                            self.graph.recordPassStat(pass_stats, .skybox_pass, durationNs(skybox_start, std.time.nanoTimestamp()), 1, 1);
                            draw_stats.draw_calls += 1;
                            draw_stats.triangles_drawn += 1;
                        }
                    }

                    if (has_prepared_preview_scene) {
                        const preview_opaque_start = std.time.nanoTimestamp();
                        const preview_opaque_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_preview_scene, .{
                            .render_mode = previewRenderMode(active_render_mode),
                            .target = .hdr,
                            .phase = .opaque_pass,
                            .blend_opaque = true,
                            .alpha_multiplier = ghost_preview_tint_color[3],
                            .preview_tint_strength = ghost_preview_tint_strength,
                            .override_base_color = ghost_preview_tint_color,
                        });
                        self.graph.recordPassStat(pass_stats, .base_pass, durationNs(preview_opaque_start, std.time.nanoTimestamp()), preview_opaque_stats.draw_calls, preview_opaque_stats.triangles_drawn);
                        draw_stats.add(preview_opaque_stats);
                    }

                    const transparent_start = std.time.nanoTimestamp();
                    const transparent_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, .{
                        .render_mode = active_render_mode,
                        .target = if (viewport_active) .hdr else .ldr,
                        .phase = .transparent_pass,
                    });
                    self.graph.recordPassStat(pass_stats, .transparent, durationNs(transparent_start, std.time.nanoTimestamp()), transparent_stats.draw_calls, transparent_stats.triangles_drawn);
                    draw_stats.add(transparent_stats);

                    if (has_prepared_preview_scene) {
                        const preview_transparent_start = std.time.nanoTimestamp();
                        const preview_transparent_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_preview_scene, .{
                            .render_mode = previewRenderMode(active_render_mode),
                            .target = .hdr,
                            .phase = .transparent_pass,
                            .alpha_multiplier = ghost_preview_tint_color[3],
                            .preview_tint_strength = ghost_preview_tint_strength,
                            .override_base_color = ghost_preview_tint_color,
                        });
                        self.graph.recordPassStat(pass_stats, .transparent, durationNs(preview_transparent_start, std.time.nanoTimestamp()), preview_transparent_stats.draw_calls, preview_transparent_stats.triangles_drawn);
                        draw_stats.add(preview_transparent_stats);
                    }

                    self.rhi.endRenderPass(scene_pass);

                    if (viewport_active) {
                        // RT Shadow Composite: 乘法混合 RT 阴影遮罩到 HDR 颜色缓冲
                        if (rt_shadows_active and self.rt_shadow_composite_pass.isReady() and self.scene_viewport.hdrColor() != null) {
                            if (self.rt_shadow_mask_texture) |*mask_tex| {
                                try self.rt_shadow_composite_pass.syncTexture(&self.rhi, mask_tex);
                                const rt_shadow_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                const rt_shadow_stats = self.rt_shadow_composite_pass.draw(&self.rhi, frame, rt_shadow_pass, self.editor_viewport_state.rt_shadow_strength);
                                draw_stats.add(rt_shadow_stats);
                                self.rhi.endRenderPass(rt_shadow_pass);
                            }
                        }

                        // Volumetric fog: composite onto HDR color before bloom/tonemap
                        const fog_enabled = self.editor_viewport_state.volumetric_fog_enabled and self.scene_viewport.hdrColor() != null;
                        if (fog_enabled) {
                            if (self.rhi_device) |dev| {
                                const inv_vp_fog = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
                                var fog_light_dir = [4]f32{ 0.0, -1.0, 0.0, 0.0 };
                                var fog_light_col = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
                                if (prepared_scene.lights.directional_lights.len > 0) {
                                    const ml = prepared_scene.lights.directional_lights[0];
                                    fog_light_dir = .{ ml.direction[0], ml.direction[1], ml.direction[2], 0.0 };
                                    fog_light_col = .{ ml.color[0], ml.color[1], ml.color[2], ml.intensity };
                                }
                                const fog_start = std.time.nanoTimestamp();
                                volumetric_fog_pass_mod.VolumetricFogPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                    .{
                                        .inv_view_projection = inv_vp_fog,
                                        .light_space_matrix = prepared_scene.light_space_matrix,
                                        .camera_position = prepared_scene.camera_world_position,
                                        .light_direction = fog_light_dir,
                                        .light_color = fog_light_col,
                                        .fog_params = .{
                                            self.editor_viewport_state.volumetric_fog_density,
                                            self.editor_viewport_state.volumetric_fog_height_falloff,
                                            self.editor_viewport_state.volumetric_fog_max_distance,
                                            32.0,
                                        },
                                    },
                                ) catch {};
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(fog_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }

                        const bloom_enabled = self.editor_viewport_state.bloom_enabled and self.scene_viewport.bloom() != null;
                        const fxaa_enabled = self.editor_viewport_state.fxaa_enabled and self.scene_viewport.fxaa() != null;

                        // SSAO: render ambient occlusion to ssao_texture
                        const ssao_enabled = self.editor_viewport_state.ssao_enabled and self.scene_viewport.ssao() != null and self.scene_viewport.depth() != null;
                        if (ssao_enabled) {
                            const mat4_ssao = @import("../math/mat4.zig");
                            const inv_proj = mat4_ssao.inverse(prepared_scene.projection_matrix) orelse mat4_ssao.identity();
                            const inv_view = mat4_ssao.inverse(prepared_scene.view_matrix) orelse mat4_ssao.identity();

                            const ssao_uniforms = ssao_pass_mod.SSAOUniforms{
                                .projection = prepared_scene.projection_matrix,
                                .inv_projection = inv_proj,
                                .view = prepared_scene.view_matrix,
                                .inv_view = inv_view,
                                .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                .radius = self.editor_viewport_state.ssao_radius,
                                .bias = self.editor_viewport_state.ssao_bias,
                                .intensity = self.editor_viewport_state.ssao_intensity,
                                .power = self.editor_viewport_state.ssao_power,
                                .kernel_size = 16,
                                .noise_scale = .{
                                    @as(f32, @floatFromInt(self.scene_viewport.width)) / 4.0,
                                    @as(f32, @floatFromInt(self.scene_viewport.height)) / 4.0,
                                },
                            };

                            // Prefer compute path when available; keep fragment path as fallback.
                            const use_legacy_path = self.editor_viewport_state.ssao_use_legacy_path;
                            var dispatched_compute = false;
                            if (!use_legacy_path) {
                                if (self.ssao_compute_pass) |*compute_pass| {
                                    if (compute_pass.isReady()) {
                                        compute_pass.dispatch(
                                            &self.rhi,
                                            frame,
                                            self.scene_viewport.depth().?,
                                            self.scene_viewport.ssao().?,
                                            ssao_uniforms,
                                        );
                                        dispatched_compute = true;
                                    }
                                }
                            }
                            if (!dispatched_compute and self.ssao_pass.isReady()) {
                                try self.ssao_pass.syncTextures(&self.rhi, self.scene_viewport.depth().?, null);
                                const ssao_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.ssao().? }));
                                const ssao_stats = self.ssao_pass.draw(&self.rhi, frame, ssao_render_pass, ssao_uniforms);
                                draw_stats.add(ssao_stats);
                                self.rhi.endRenderPass(ssao_render_pass);
                            }

                            // SSAO 合成: 将 SSAO 纹理以乘法混合叠加到 HDR 颜色缓冲，
                            // 使遮蔽区域（角落/缝隙）自然变暗，增强场景接地感。
                            if (self.ssao_composite_pass.isReady() and self.scene_viewport.hdrColor() != null) {
                                try self.ssao_composite_pass.syncTexture(&self.rhi, self.scene_viewport.ssao().?);
                                const ssao_composite_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                const ssao_composite_stats = self.ssao_composite_pass.draw(&self.rhi, frame, ssao_composite_render_pass, self.editor_viewport_state.ssao_intensity);
                                draw_stats.add(ssao_composite_stats);
                                self.rhi.endRenderPass(ssao_composite_render_pass);
                            }
                        }

                        // Contact Shadows: screen-space ray march for small-scale occlusion
                        const cs_enabled = self.editor_viewport_state.contact_shadows_enabled and self.scene_viewport.contactShadow() != null and self.scene_viewport.depth() != null;
                        if (cs_enabled) {
                            if (self.rhi_device) |dev| {
                                const mat4_cs = @import("../math/mat4.zig");
                                const inv_proj_cs = mat4_cs.inverse(prepared_scene.projection_matrix) orelse mat4_cs.identity();
                                const cs_light_dir: [4]f32 = if (prepared_scene.lights.directional_lights.len > 0) cs_ld: {
                                    const dl = prepared_scene.lights.directional_lights[0];
                                    break :cs_ld .{ dl.direction[0], dl.direction[1], dl.direction[2], 0.0 };
                                } else .{ 0.3, -0.9, -0.2, 0.0 };

                                contact_shadow_pass_mod.ContactShadowPass.execute(
                                    self.allocator,
                                    dev,
                                    &self.graph,
                                    0,
                                    0,
                                    .{
                                        .projection = prepared_scene.projection_matrix,
                                        .inv_projection = inv_proj_cs,
                                        .view = prepared_scene.view_matrix,
                                        .light_direction = cs_light_dir,
                                        .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                        .max_distance = self.editor_viewport_state.contact_shadows_distance,
                                        .thickness = self.editor_viewport_state.contact_shadows_thickness,
                                        .intensity = self.editor_viewport_state.contact_shadows_intensity,
                                        .bias = self.editor_viewport_state.contact_shadows_bias,
                                        .num_steps = @intCast(self.editor_viewport_state.contact_shadows_steps),
                                    },
                                ) catch |err| {
                                    std.log.warn("contact shadow failed: {}", .{err});
                                };
                            }
                        }

                        // SSR dispatch
                        if (self.editor_viewport_state.ssr_enabled) {
                            if (self.rhi_device) |dev| {
                                const mat4_ssr = @import("../math/mat4.zig");
                                const inv_proj_ssr = mat4_ssr.inverse(prepared_scene.projection_matrix) orelse mat4_ssr.identity();
                                const inv_view_ssr = mat4_ssr.inverse(prepared_scene.view_matrix) orelse mat4_ssr.identity();
                                const ssr_start = std.time.nanoTimestamp();
                                ssr_pass_mod.SSRPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                    .{
                                        .projection = prepared_scene.projection_matrix,
                                        .inv_projection = inv_proj_ssr,
                                        .view = prepared_scene.view_matrix,
                                        .inv_view = inv_view_ssr,
                                        .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                        .ray_step = self.editor_viewport_state.ssr_ray_step,
                                        .ray_max_distance = self.editor_viewport_state.ssr_ray_max_distance,
                                        .ray_thickness = self.editor_viewport_state.ssr_ray_thickness,
                                        .intensity = self.editor_viewport_state.ssr_intensity,
                                        .fade_distance = self.editor_viewport_state.ssr_fade_distance,
                                        .edge_fade = self.editor_viewport_state.ssr_edge_fade,
                                    },
                                ) catch {};
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(ssr_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }

                        // TAA resolve: blend current frame with history
                        var taa_resolved = false;
                        if (taa_enabled) {
                            try self.taa_pass.ensureHistoryTexture(&self.rhi, self.scene_viewport.width, self.scene_viewport.height);
                            try self.taa_pass.syncTextures(&self.rhi, self.scene_viewport.hdrColor().?, null, self.scene_viewport.depth());
                            const taa_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.taa().? }));

                            const inv_proj_taa = mat4_mod.inverse(unjittered_projection) orelse mat4_mod.identity();
                            const jitter_val = self.taa_pass.getJitter();

                            const taa_uniforms = taa_pass_mod.TAAUniforms{
                                .projection = unjittered_projection,
                                .inv_projection = inv_proj_taa,
                                .view = prepared_scene.view_matrix,
                                .prev_view = self.prev_view_matrix,
                                .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                .jitter = .{
                                    jitter_val[0] / @as(f32, @floatFromInt(self.scene_viewport.width)),
                                    jitter_val[1] / @as(f32, @floatFromInt(self.scene_viewport.height)),
                                },
                                .blend_factor = self.editor_viewport_state.taa_blend_factor,
                                .motion_blur_scale = 0.0, // No velocity buffer in MVP — disable velocity lookup
                                .feedback_min = self.editor_viewport_state.taa_feedback_min,
                                .feedback_max = self.editor_viewport_state.taa_feedback_max,
                            };
                            const taa_stats = self.taa_pass.draw(&self.rhi, frame, taa_render_pass, taa_uniforms);
                            draw_stats.add(taa_stats);
                            self.rhi.endRenderPass(taa_render_pass);

                            // Copy TAA output to history for next frame
                            self.rhi.blitTexture(frame, self.scene_viewport.taa().?, &self.taa_pass.history_texture.?);
                            taa_resolved = true;

                            self.taa_pass.advanceFrame();
                        }

                        // Select HDR input for bloom: use TAA output if resolved, otherwise raw HDR
                        const _hdr_input_for_post = if (taa_resolved) self.scene_viewport.taa().? else self.scene_viewport.hdrColor().?;
                        _ = _hdr_input_for_post;

                        if (bloom_enabled) {
                            if (self.rhi_device) |dev| {
                                const bloom_start = std.time.nanoTimestamp();
                                bloom_pass_mod.BloomPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                    .{
                                        .threshold = self.editor_viewport_state.bloom_threshold,
                                        .intensity = self.editor_viewport_state.bloom_intensity,
                                    },
                                ) catch {};
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(bloom_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }

                        // DOF dispatch
                        if (self.editor_viewport_state.dof_enabled) {
                            if (self.rhi_device) |dev| {
                                const dof_start = std.time.nanoTimestamp();
                                dof_pass_mod.DOFPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                    .{
                                        .focus_distance = self.editor_viewport_state.dof_focus_distance,
                                        .focus_range = self.editor_viewport_state.dof_focus_range,
                                        .blur_radius = self.editor_viewport_state.dof_blur_radius,
                                        .bokeh_radius = self.editor_viewport_state.dof_bokeh_radius,
                                        .near_blur = self.editor_viewport_state.dof_near_blur,
                                        .far_blur = self.editor_viewport_state.dof_far_blur,
                                        .quality = self.editor_viewport_state.dof_quality,
                                    },
                                ) catch {};
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(dof_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }

                        if (self.rhi_device) |dev| {
                            const tm_start = std.time.nanoTimestamp();
                            tonemap_pass_mod.TonemapPass.execute(
                                self.allocator,
                                dev,
                                null,
                                0,
                                0,
                                .{
                                    .exposure_params = .{
                                        @as(f32, if (self.editor_viewport_state.exposure_enabled) 1.0 else 0.0),
                                        self.editor_viewport_state.exposure,
                                        0.0,
                                        0.0,
                                    },
                                    .bloom_params = .{
                                        @as(f32, if (bloom_enabled) 1.0 else 0.0),
                                        self.editor_viewport_state.bloom_intensity,
                                        0.0,
                                        0.0,
                                    },
                                    .color_grading_params = .{
                                        @as(f32, if (self.editor_viewport_state.color_grading_enabled) 1.0 else 0.0),
                                        self.editor_viewport_state.color_grading_saturation,
                                        self.editor_viewport_state.color_grading_contrast,
                                        self.editor_viewport_state.color_grading_gamma,
                                    },
                                    .lut_params = .{
                                        @as(f32, if (self.editor_viewport_state.lut_enabled) 1.0 else 0.0),
                                        self.editor_viewport_state.lut_intensity,
                                        1.0,
                                        0.0,
                                    },
                                },
                            ) catch {};
                            self.graph.recordPassStat(pass_stats, .tonemap_pass, durationNs(tm_start, std.time.nanoTimestamp()), 1, 1);
                        }

                        if (fxaa_enabled) {
                            if (self.rhi_device) |dev| {
                                const fxaa_start = std.time.nanoTimestamp();
                                fullscreen_post_mod.FullscreenPostPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                ) catch {};
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(fxaa_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }
                    }
                }

                // --- 公共 overlay passes：所有模式（Raster/PathTrace/HW RT）都运行 ---
                const selected_entities = self.selection_history.currentSelection();
                const ai_focus_entities = self.ai_focus_entity_ids[0..self.ai_focus_entity_count];
                if (self.outline_pass.isReady() and self.id_pass.texture() != null and (selected_entities.len > 0 or ai_focus_entities.len > 0)) {
                    try self.outline_pass.syncTexture(&self.rhi, self.id_pass.texture().?);
                    const outline_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(scene_color_target));
                    const outline_start = std.time.nanoTimestamp();
                    var outline_stats = mesh_pass_mod.DrawStats{};
                    if (selected_entities.len > 0) {
                        outline_stats.add(self.outline_pass.draw(&self.rhi, frame, outline_pass, selected_entities));
                    }
                    if (ai_focus_entities.len > 0) {
                        const pulse = 0.65 + 0.35 * @sin(@as(f32, @floatCast(@as(f64, @floatFromInt(std.time.milliTimestamp())) / 220.0)));
                        outline_stats.add(self.outline_pass.drawWithColor(
                            &self.rhi,
                            frame,
                            outline_pass,
                            ai_focus_entities,
                            .{ 0.70, 0.35, 1.0, pulse },
                        ));
                    }
                    self.graph.recordPassStat(pass_stats, .outline_pass, durationNs(outline_start, std.time.nanoTimestamp()), outline_stats.draw_calls, outline_stats.triangles_drawn);
                    draw_stats.add(outline_stats);
                    self.rhi.endRenderPass(outline_pass);
                }

                if (self.gizmoPassRequired(scene)) {
                    const gizmo_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(scene_color_target));
                    const gizmo_start = std.time.nanoTimestamp();
                    var gizmo_overlay_stats = mesh_pass_mod.DrawStats{};
                    const gizmo_target_transform = if (self.preview_gizmo_transform) |preview_transform|
                        preview_transform
                    else if (self.selection_history.primarySelection()) |selected_entity_id|
                        scene.worldTransformConst(selected_entity_id)
                    else
                        null;
                    if (gizmo_target_transform) |selected_transform| {
                        const gizmo_stats = self.gizmo_pass.draw(
                            &self.rhi,
                            frame,
                            gizmo_pass,
                            &prepared_scene,
                            selected_transform,
                            self.editor_gizmo_state,
                        );
                        gizmo_overlay_stats.add(gizmo_stats);
                        draw_stats.add(gizmo_stats);
                    }

                    const debug_stats = try self.drawViewportDebugOverlays(frame, gizmo_pass, scene, &prepared_scene, physics_state_opt);
                    gizmo_overlay_stats.add(debug_stats);
                    draw_stats.add(debug_stats);
                    self.graph.recordPassStat(pass_stats, .gizmo_overlay, durationNs(gizmo_start, std.time.nanoTimestamp()), gizmo_overlay_stats.draw_calls, gizmo_overlay_stats.triangles_drawn);
                    self.rhi.endRenderPass(gizmo_pass);
                }

                // Store view matrix for TAA reprojection next frame
                self.prev_view_matrix = prepared_scene.view_matrix;
            }

            const thumbnail_stats = try self.processMaterialThumbnailRequests(frame, scene);
            draw_stats.add(thumbnail_stats);

            if (has_swapchain) {
                imgui_mod.prepare(&frame.command_buffer);
                const ui_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                    .color = .{
                        .target = .swapchain,
                        .clear_color = clear.color,
                        .load_op = if (viewport_active) .clear else .load,
                        .store_op = .store,
                    },
                    .depth = null,
                });
                const ui_start = std.time.nanoTimestamp();
                imgui_mod.render(&frame.command_buffer, &ui_pass);
                self.graph.recordPassStat(pass_stats, .ui_overlay, durationNs(ui_start, std.time.nanoTimestamp()), 0, 0);
                self.rhi.endRenderPass(ui_pass);
            }

            if (self.pending_selection_readbacks.items.len > 0) {
                const id_pick_available = can_render_scene and self.id_pass.texture() != null and !(viewport_active and self.editor_viewport_state.pipeline_mode == .path_trace);
                if (id_pick_available) {
                    const id_texture = self.id_pass.texture().?;
                    try self.enqueueSelectionReadbacks(frame, id_texture);
                } else {
                    try self.rhi.submitFrame(frame);
                    try self.applyPendingSelectionMisses();
                }
            } else {
                try self.rhi.submitFrame(frame);
            }
            try self.resolveSelectionReadbacks();

            // Collect RHI stats
            var cache_hits: u64 = 0;
            var cache_misses: u64 = 0;
            var delta_hits: u64 = 0;
            var delta_misses: u64 = 0;
            var delta_evictions: u64 = 0;
            var slot_errors: usize = 0;
            if (self.rhi_device) |dev| {
                const cs = dev.bindingSetCacheStats();
                cache_hits = cs.hits;
                cache_misses = cs.misses;
                const frame_delta = dev.snapshotFrameStats();
                delta_hits = frame_delta.hits;
                delta_misses = frame_delta.misses;
                delta_evictions = frame_delta.evictions;

                // Slot-layout consistency validation against compiled graph
                const errs = self.graph.validateSlotLayoutConstraints(self.allocator, dev) catch &.{};
                slot_errors = errs.len;
                if (errs.len > 0) {
                    for (errs) |se| {
                        std.log.warn("slot-layout mismatch: pass={s} slot={} expected_layout={}", .{ se.pass_name, se.slot, se.expected_layout_id });
                    }
                    self.allocator.free(errs);
                }
            }

            break :blk FrameReport{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .graph_resources = self.graph.resourceCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
                .draw_calls = draw_stats.draw_calls,
                .triangles_drawn = draw_stats.triangles_drawn,
                .binding_cache_hits = cache_hits,
                .binding_cache_misses = cache_misses,
                .slot_layout_errors = slot_errors,
                .binding_cache_hits_delta = delta_hits,
                .binding_cache_misses_delta = delta_misses,
                .binding_cache_evictions_delta = delta_evictions,
            };
        };

        // Only write frame report on first frame to avoid per-frame disk I/O
        if (!g_logged_viewport_backend) {
            const entry_count: u32 = if (self.rhi_device) |dev| dev.bindingSetCacheEntryCount() else 0;
            self.graph.writeFrameReportWithCacheStats(
                self.allocator,
                "dist/reports/latest_frame_report.json",
                rhi_types.graphicsApiName(self.rhi.api),
                result.draw_calls,
                result.triangles_drawn,
                pass_stats,
                .{ .hits = result.binding_cache_hits, .misses = result.binding_cache_misses, .entries = entry_count },
            ) catch |err| {
                std.log.warn("failed to write frame report: {}", .{err});
            };
        }
        return result;
    }

    fn renderPathTraceViewport(self: *Renderer, prepared_scene: *const mesh_pass_mod.PreparedScene, scene: *scene_mod.Scene) !void {
        const target = self.scene_viewport.color() orelse return;
        const width = target.desc.width;
        const height = target.desc.height;
        if (width == 0 or height == 0) return;

        const samples = std.math.clamp(self.editor_viewport_state.path_trace_samples, 1, 64);
        const bounces = std.math.clamp(self.editor_viewport_state.path_trace_bounces, 1, 8);
        const resolution_scale = std.math.clamp(self.editor_viewport_state.path_trace_resolution_scale, 0.25, 1.0);
        const trace_width = @max(@as(u32, 1), @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * resolution_scale)));
        const trace_height = @max(@as(u32, 1), @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * resolution_scale)));

        // --- 尝试 GPU 硬件加速路径追踪 ---
        if (self.tryRenderHwRtPath(prepared_scene, scene, target, width, height, trace_width, trace_height, samples, bounces, resolution_scale)) {
            return;
        }

        // --- 回退到 CPU 渐进式路径追踪 ---

        if (!g_logged_path_trace_active) {
            render_log.info("CPU path trace viewport active (progressive)", .{});
            g_logged_path_trace_active = true;
        }

        var pt = &self.path_trace_state;

        // --- 检测变化，需要时重置 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&pt.last_view_projection));
        const size_changed = trace_width != pt.trace_width or trace_height != pt.trace_height or width != pt.target_width or height != pt.target_height;
        const params_changed = samples != pt.last_samples or bounces != pt.last_bounces or resolution_scale != pt.last_resolution_scale;

        if (vp_changed or params_changed) {
            pt.reset(self.allocator);
        }

        if (size_changed) {
            pt.reset(self.allocator);
            if (pt.trace_pixels) |p| self.allocator.free(p);
            if (pt.display_pixels) |p| self.allocator.free(p);
            pt.trace_pixels = null;
            pt.display_pixels = null;
        }

        // 更新变化检测用的缓存值
        pt.last_view_projection = prepared_scene.view_projection;
        pt.last_samples = samples;
        pt.last_bounces = bounces;
        pt.last_resolution_scale = resolution_scale;

        // --- 分配/复用持久缓冲区 ---
        if (pt.trace_pixels == null) {
            pt.trace_pixels = try self.allocator.alloc(u8, @as(usize, trace_width) * trace_height * 4);
            @memset(pt.trace_pixels.?, 0);
            pt.trace_width = trace_width;
            pt.trace_height = trace_height;
        }
        if (pt.display_pixels == null) {
            pt.display_pixels = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
            @memset(pt.display_pixels.?, 0);
            pt.target_width = width;
            pt.target_height = height;
        }

        // 如果已经渲染完成，直接上传缓存结果
        if (pt.complete) {
            try self.rhi.uploadTextureData(target, pt.display_pixels.?, width, height);
            return;
        }

        // --- 构建/缓存场景三角形数据 ---
        if (pt.triangles == null) {
            var triangle_list = std.ArrayList(PathTraceTriangle).empty;
            defer triangle_list.deinit(self.allocator);
            var mesh_list = std.ArrayList(PathTraceMesh).empty;
            defer mesh_list.deinit(self.allocator);
            var texture_list = std.ArrayList(PathTraceTexture).empty;
            defer texture_list.deinit(self.allocator);
            // 去重: TextureHandle.value → texture_list index
            var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
            defer texture_index_map.deinit();

            for (prepared_scene.opaque_meshes) |item| {
                const mesh_res = if (handles.isValid(item.mesh_handle))
                    scene.resources.mesh(item.mesh_handle)
                else
                    null;

                if (mesh_res) |mesh| {
                    const tri_start: u32 = @intCast(triangle_list.items.len);
                    const indices = mesh.indices;
                    const vertices = mesh.vertices;
                    const albedo = [3]f32{
                        std.math.clamp(item.base_color_factor[0], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[1], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[2], 0.02, 1.0),
                    };
                    const emissive = [3]f32{
                        item.emissive_factor[0] * item.emissive_factor[3],
                        item.emissive_factor[1] * item.emissive_factor[3],
                        item.emissive_factor[2] * item.emissive_factor[3],
                    };
                    const metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                    const roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);

                    // 解析 base_color 纹理（如果存在）
                    const tex_idx: i32 = blk_tex: {
                        if (item.has_textures[0] == 0) break :blk_tex @as(i32, -1);
                        const entity = scene.getEntityConst(item.entity_id) orelse break :blk_tex @as(i32, -1);
                        const mat_comp = entity.material orelse break :blk_tex @as(i32, -1);
                        const mat_handle = mat_comp.handle orelse break :blk_tex @as(i32, -1);
                        const mat_res = scene.resources.material(mat_handle) orelse break :blk_tex @as(i32, -1);
                        const tex_handle = mat_res.base_color_texture orelse break :blk_tex @as(i32, -1);
                        // 去重查询
                        const tex_key = @intFromEnum(tex_handle);
                        if (texture_index_map.get(tex_key)) |existing| break :blk_tex existing;
                        const tex_res = scene.resources.texture(tex_handle) orelse break :blk_tex @as(i32, -1);
                        if (tex_res.pixels.len == 0 or tex_res.width == 0 or tex_res.height == 0) break :blk_tex @as(i32, -1);
                        const idx_i32: i32 = @intCast(texture_list.items.len);
                        try texture_list.append(self.allocator, .{
                            .pixels = tex_res.pixels,
                            .width = tex_res.width,
                            .height = tex_res.height,
                        });
                        try texture_index_map.put(tex_key, idx_i32);
                        break :blk_tex idx_i32;
                    };

                    var aabb = AABB.empty();
                    var i: usize = 0;
                    while (i + 2 < indices.len) : (i += 3) {
                        const idx0 = indices[i];
                        const idx1 = indices[i + 1];
                        const idx2 = indices[i + 2];
                        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                        const v0 = transformPoint(item.model, vertices[idx0].position);
                        const v1 = transformPoint(item.model, vertices[idx1].position);
                        const v2 = transformPoint(item.model, vertices[idx2].position);
                        const n0 = transformNormal(item.model, vertices[idx0].normal);
                        const n1 = transformNormal(item.model, vertices[idx1].normal);
                        const n2 = transformNormal(item.model, vertices[idx2].normal);

                        aabb.expand(v0);
                        aabb.expand(v1);
                        aabb.expand(v2);

                        try triangle_list.append(self.allocator, .{
                            .v0 = v0,
                            .v1 = v1,
                            .v2 = v2,
                            .n0 = n0,
                            .n1 = n1,
                            .n2 = n2,
                            .uv0 = vertices[idx0].uv,
                            .uv1 = vertices[idx1].uv,
                            .uv2 = vertices[idx2].uv,
                            .albedo = albedo,
                            .emissive = emissive,
                            .metallic = metallic,
                            .roughness = roughness,
                            .texture_index = tex_idx,
                        });
                    }

                    const tri_count: u32 = @intCast(triangle_list.items.len - tri_start);
                    if (tri_count > 0) {
                        try mesh_list.append(self.allocator, .{
                            .aabb = aabb,
                            .tri_start = tri_start,
                            .tri_count = tri_count,
                        });
                    }
                }
            }

            // 无网格时显示地面平面
            if (triangle_list.items.len == 0) {
                try triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, -5.0 },
                    .v2 = .{ 5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .uv0 = .{ 0.0, 0.0 },
                    .uv1 = .{ 1.0, 0.0 },
                    .uv2 = .{ 1.0, 1.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                    .texture_index = -1,
                });
                try triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, 5.0 },
                    .v2 = .{ -5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .uv0 = .{ 0.0, 0.0 },
                    .uv1 = .{ 1.0, 1.0 },
                    .uv2 = .{ 0.0, 1.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                    .texture_index = -1,
                });
                try mesh_list.append(self.allocator, .{
                    .aabb = .{ .min = .{ -5.0, -0.01, -5.0 }, .max = .{ 5.0, 0.01, 5.0 } },
                    .tri_start = 0,
                    .tri_count = 2,
                });
            }

            pt.triangles = try self.allocator.dupe(PathTraceTriangle, triangle_list.items);
            pt.meshes = try self.allocator.dupe(PathTraceMesh, mesh_list.items);
            pt.textures = try self.allocator.dupe(PathTraceTexture, texture_list.items);
            pt.inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
            pt.camera_origin = .{
                prepared_scene.camera_world_position[0],
                prepared_scene.camera_world_position[1],
                prepared_scene.camera_world_position[2],
            };
            pt.light_direction = if (prepared_scene.lights.directional_lights.len > 0)
                vec3.normalize(vec3.scale(prepared_scene.lights.directional_lights[0].direction, -1.0))
            else
                vec3.normalize(.{ 0.38, 0.82, 0.42 });
            pt.cached_samples = samples;
            pt.cached_bounces = bounces;

            const pixel_budget: u32 = 960 * 540;
            const area = trace_width * trace_height;
            pt.sample_step = if (area > pixel_budget * 4)
                4
            else if (area > pixel_budget * 2)
                3
            else if (area > pixel_budget)
                2
            else
                1;
        }

        // --- 渐进追踪：每帧只渲染时间预算内的扫描行 ---
        const budget_ns: i128 = 8_000_000; // 8ms
        const start_time = std.time.nanoTimestamp();
        const trace_pixels = pt.trace_pixels.?;
        const triangles = pt.triangles.?;
        const meshes = pt.meshes.?;
        const pt_textures = pt.textures orelse &[_]PathTraceTexture{};

        while (pt.current_scanline < trace_height) {
            const y = pt.current_scanline;
            var x: u32 = 0;
            while (x < trace_width) : (x += pt.sample_step) {
                var traced_color = [3]f32{ 0.0, 0.0, 0.0 };
                const seed_base = hashU32(x ^ (y << 16) ^ 0x7f4a7c15);

                var s: u32 = 0;
                while (s < pt.cached_samples) : (s += 1) {
                    const jitter_seed = seed_base ^ (s *% 0x45d9f3b);
                    const jitter_x = hashUnitFloat(jitter_seed ^ 0x18f0e149) - 0.5;
                    const jitter_y = hashUnitFloat(jitter_seed ^ 0x6c8e9cf5) - 0.5;
                    const uv_x = (@as(f32, @floatFromInt(x)) + 0.5 + jitter_x) /
                        @as(f32, @floatFromInt(trace_width));
                    const uv_y = (@as(f32, @floatFromInt(y)) + 0.5 + jitter_y) /
                        @as(f32, @floatFromInt(trace_height));
                    const ndc_x = uv_x * 2.0 - 1.0;
                    const ndc_y = 1.0 - uv_y * 2.0;

                    const world_near = unprojectNdc(pt.inv_view_projection, ndc_x, ndc_y, 0.0);
                    const world_far = unprojectNdc(pt.inv_view_projection, ndc_x, ndc_y, 1.0);
                    const ray_origin = pt.camera_origin;
                    var ray_direction = vec3.normalize(vec3.sub(world_far, world_near));
                    if (vec3.length(ray_direction) <= 0.0001) {
                        ray_direction = vec3.normalize(vec3.sub(world_far, ray_origin));
                    }

                    const sample_color = pathTraceRay(
                        ray_origin,
                        ray_direction,
                        triangles,
                        meshes,
                        pt_textures,
                        pt.light_direction,
                        jitter_seed,
                        pt.cached_bounces,
                    );
                    traced_color = vec3.add(traced_color, sample_color);
                }

                traced_color = vec3.scale(traced_color, 1.0 / @as(f32, @floatFromInt(pt.cached_samples)));
                const bgra = linearToSrgb8(traced_color);

                var fy: u32 = 0;
                while (fy < pt.sample_step and y + fy < trace_height) : (fy += 1) {
                    var fx: u32 = 0;
                    while (fx < pt.sample_step and x + fx < trace_width) : (fx += 1) {
                        const out_x = x + fx;
                        const out_y = y + fy;
                        const pixel_index: usize = (@as(usize, out_y) * @as(usize, trace_width) + @as(usize, out_x)) * 4;
                        trace_pixels[pixel_index + 0] = bgra[0];
                        trace_pixels[pixel_index + 1] = bgra[1];
                        trace_pixels[pixel_index + 2] = bgra[2];
                        trace_pixels[pixel_index + 3] = bgra[3];
                    }
                }
            }

            pt.current_scanline += pt.sample_step;

            // 超出时间预算后让出控制权，下帧继续
            if (std.time.nanoTimestamp() - start_time >= budget_ns) break;
        }

        if (pt.current_scanline >= trace_height) {
            pt.complete = true;
        }

        // --- 上采样 trace_pixels → display_pixels ---
        const display_pixels = pt.display_pixels.?;
        var out_y: u32 = 0;
        while (out_y < height) : (out_y += 1) {
            const src_y_u64 = (@as(u64, out_y) * @as(u64, trace_height)) / @as(u64, height);
            const src_y: u32 = @min(trace_height - 1, @as(u32, @intCast(src_y_u64)));
            var out_x: u32 = 0;
            while (out_x < width) : (out_x += 1) {
                const src_x_u64 = (@as(u64, out_x) * @as(u64, trace_width)) / @as(u64, width);
                const src_x: u32 = @min(trace_width - 1, @as(u32, @intCast(src_x_u64)));
                const src_index: usize = (@as(usize, src_y) * @as(usize, trace_width) + @as(usize, src_x)) * 4;
                const dst_index: usize = (@as(usize, out_y) * @as(usize, width) + @as(usize, out_x)) * 4;
                display_pixels[dst_index + 0] = trace_pixels[src_index + 0];
                display_pixels[dst_index + 1] = trace_pixels[src_index + 1];
                display_pixels[dst_index + 2] = trace_pixels[src_index + 2];
                display_pixels[dst_index + 3] = trace_pixels[src_index + 3];
            }
        }

        try self.rhi.uploadTextureData(target, display_pixels, width, height);
    }

    // ==================================================================
    // RT Shadows — 光栅模式下的硬件 RT 阴影遮罩
    // ==================================================================

    /// 尝试渲染 RT 阴影遮罩用于光栅模式。成功返回 true，遮罩纹理可用于合成。
    fn tryRenderRtShadows(
        self: *Renderer,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        scene: *scene_mod.Scene,
        width: u32,
        height: u32,
    ) bool {
        if (width == 0 or height == 0) return false;

        // 懒初始化硬件 RT 后端
        if (self.rt_device == null) {
            self.rt_device = rt_device_mod.RtDevice.init();
            if (!self.rt_device.?.isAvailable()) {
                self.rt_device.?.deinit();
                self.rt_device = null;
                return false;
            }
        }

        var rt_dev = &self.rt_device.?;
        var mrt = &self.hw_rt_state;

        // --- 变化检测 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&self.rt_shadow_last_vp));
        if (vp_changed) {
            self.rt_shadow_last_vp = prepared_scene.view_projection;
        } else if (self.rt_shadow_mask_texture != null and self.rt_shadow_width == width and self.rt_shadow_height == height) {
            return true; // 已缓存的遮罩仍然有效
        }

        // --- 构建三角形数据 (复用 hw_rt_state) ---
        if (mrt.triangles == null) {
            var triangle_list: std.ArrayListUnmanaged(rt_backend.RtTriangle) = .empty;
            defer triangle_list.deinit(self.allocator);

            var texture_list = std.ArrayList(struct { pixels: []const u8, width: u32, height: u32 }).empty;
            defer texture_list.deinit(self.allocator);
            var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
            defer texture_index_map.deinit();

            for (prepared_scene.opaque_meshes) |item| {
                const mesh_res = if (handles.isValid(item.mesh_handle))
                    scene.resources.mesh(item.mesh_handle)
                else
                    null;
                if (mesh_res) |mesh| {
                    const indices = mesh.indices;
                    const vertices = mesh.vertices;
                    const albedo = [3]f32{
                        std.math.clamp(item.base_color_factor[0], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[1], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[2], 0.02, 1.0),
                    };
                    const emissive = [3]f32{
                        item.emissive_factor[0] * item.emissive_factor[3],
                        item.emissive_factor[1] * item.emissive_factor[3],
                        item.emissive_factor[2] * item.emissive_factor[3],
                    };
                    const metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                    const roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);

                    const tex_idx: i32 = blk_tex: {
                        if (item.has_textures[0] == 0) break :blk_tex @as(i32, -1);
                        const entity = scene.getEntityConst(item.entity_id) orelse break :blk_tex @as(i32, -1);
                        const mat_comp = entity.material orelse break :blk_tex @as(i32, -1);
                        const mat_handle = mat_comp.handle orelse break :blk_tex @as(i32, -1);
                        const mat_res = scene.resources.material(mat_handle) orelse break :blk_tex @as(i32, -1);
                        const tex_handle = mat_res.base_color_texture orelse break :blk_tex @as(i32, -1);
                        const tex_key = @intFromEnum(tex_handle);
                        if (texture_index_map.get(tex_key)) |existing| break :blk_tex existing;
                        const tex_res = scene.resources.texture(tex_handle) orelse break :blk_tex @as(i32, -1);
                        if (tex_res.pixels.len == 0 or tex_res.width == 0 or tex_res.height == 0) break :blk_tex @as(i32, -1);
                        const idx_i32: i32 = @intCast(texture_list.items.len);
                        texture_list.append(self.allocator, .{
                            .pixels = tex_res.pixels,
                            .width = tex_res.width,
                            .height = tex_res.height,
                        }) catch break :blk_tex @as(i32, -1);
                        texture_index_map.put(tex_key, idx_i32) catch break :blk_tex @as(i32, -1);
                        break :blk_tex idx_i32;
                    };

                    var i: usize = 0;
                    while (i + 2 < indices.len) : (i += 3) {
                        const idx0 = indices[i];
                        const idx1 = indices[i + 1];
                        const idx2 = indices[i + 2];
                        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                        triangle_list.append(self.allocator, .{
                            .v0 = transformPoint(item.model, vertices[idx0].position),
                            .v1 = transformPoint(item.model, vertices[idx1].position),
                            .v2 = transformPoint(item.model, vertices[idx2].position),
                            .n0 = transformNormal(item.model, vertices[idx0].normal),
                            .n1 = transformNormal(item.model, vertices[idx1].normal),
                            .n2 = transformNormal(item.model, vertices[idx2].normal),
                            .uv0 = vertices[idx0].uv,
                            .uv1 = vertices[idx1].uv,
                            .uv2 = vertices[idx2].uv,
                            .albedo = albedo,
                            .emissive = emissive,
                            .metallic = metallic,
                            .roughness = roughness,
                            .texture_index = tex_idx,
                        }) catch return false;
                    }
                }
            }

            if (triangle_list.items.len == 0) return false;

            mrt.triangles = self.allocator.dupe(rt_backend.RtTriangle, triangle_list.items) catch return false;
            mrt.accel_built = false;

            // 打包纹理图集
            if (texture_list.items.len > 0) {
                var total_size: usize = 0;
                for (texture_list.items) |tex| total_size += tex.pixels.len;
                const atlas = self.allocator.alloc(u8, total_size) catch return false;
                const meta = self.allocator.alloc(rt_backend.RtTextureMeta, texture_list.items.len) catch {
                    self.allocator.free(atlas);
                    return false;
                };
                var offset: u32 = 0;
                for (texture_list.items, 0..) |tex, ti| {
                    @memcpy(atlas[offset..][0..tex.pixels.len], tex.pixels);
                    meta[ti] = .{ .offset = offset, .width = tex.width, .height = tex.height };
                    offset += @intCast(tex.pixels.len);
                }
                mrt.texture_atlas = atlas;
                mrt.texture_meta = meta;
            }
            mrt.textures_uploaded = false;
        }

        // --- 构建加速结构 ---
        if (!mrt.accel_built) {
            if (!rt_dev.buildAccelerationStructure(mrt.triangles.?)) return false;
            mrt.accel_built = true;
        }

        // --- 上传纹理图集到 GPU ---
        if (!mrt.textures_uploaded) {
            if (mrt.texture_atlas != null and mrt.texture_meta != null) {
                _ = rt_dev.uploadTextures(mrt.texture_atlas.?, mrt.texture_meta.?);
            } else {
                _ = rt_dev.uploadTextures(&.{}, &.{});
            }
            mrt.textures_uploaded = true;
        }

        // --- 分辨率缩放 ---
        const scale = std.math.clamp(self.editor_viewport_state.rt_shadow_resolution_scale, 0.25, 1.0);
        const trace_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * scale)));
        const trace_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * scale)));

        // --- 分配像素缓冲 (trace 尺寸) ---
        const trace_needed = @as(usize, trace_w) * trace_h * 4;
        if (self.rt_shadow_pixels == null or self.rt_shadow_width != trace_w or self.rt_shadow_height != trace_h) {
            if (self.rt_shadow_pixels) |p| self.allocator.free(p);
            self.rt_shadow_pixels = self.allocator.alloc(u8, trace_needed) catch return false;
            self.rt_shadow_width = trace_w;
            self.rt_shadow_height = trace_h;
        }

        // --- 光线追踪 (shadow only) ---
        const light_dir: [3]f32 = if (prepared_scene.lights.directional_lights.len > 0)
            vec3.normalize(vec3.scale(prepared_scene.lights.directional_lights[0].direction, -1.0))
        else
            vec3.normalize(.{ 0.38, 0.82, 0.42 });

        var params = rt_backend.RtParams{
            .inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity(),
            .camera_origin = .{
                prepared_scene.camera_world_position[0],
                prepared_scene.camera_world_position[1],
                prepared_scene.camera_world_position[2],
            },
            .light_direction = light_dir,
            .sun_angular_radius = self.editor_viewport_state.rt_shadow_softness,
            .width = trace_w,
            .height = trace_h,
            .samples = 1,
            .bounces = 1,
            .mode = 1, // shadow-only
            .shadow_samples = self.editor_viewport_state.rt_shadow_samples,
        };

        if (!rt_dev.traceRays(&params, self.rt_shadow_pixels.?)) return false;

        // --- 上采样 (如果 trace 分辨率 < 输出分辨率) ---
        const upload_pixels: []u8 = if (trace_w == width and trace_h == height)
            self.rt_shadow_pixels.?
        else blk: {
            const full_size = @as(usize, width) * height * 4;
            const upscaled = self.allocator.alloc(u8, full_size) catch return false;
            // 双线性插值上采样
            const tw_f: f32 = @floatFromInt(trace_w);
            const th_f: f32 = @floatFromInt(trace_h);
            const src = self.rt_shadow_pixels.?;
            for (0..height) |y| {
                const sy = @as(f32, @floatFromInt(y)) * th_f / @as(f32, @floatFromInt(height));
                const y0: u32 = @intFromFloat(@floor(sy));
                const y1: u32 = @min(y0 + 1, trace_h - 1);
                const fy = sy - @floor(sy);
                for (0..width) |x| {
                    const sx = @as(f32, @floatFromInt(x)) * tw_f / @as(f32, @floatFromInt(width));
                    const x0: u32 = @intFromFloat(@floor(sx));
                    const x1: u32 = @min(x0 + 1, trace_w - 1);
                    const fx = sx - @floor(sx);
                    const dst_off = (y * width + x) * 4;
                    inline for (0..4) |ch| {
                        const c00: f32 = @floatFromInt(src[(@as(usize, y0) * trace_w + x0) * 4 + ch]);
                        const c10: f32 = @floatFromInt(src[(@as(usize, y0) * trace_w + x1) * 4 + ch]);
                        const c01: f32 = @floatFromInt(src[(@as(usize, y1) * trace_w + x0) * 4 + ch]);
                        const c11: f32 = @floatFromInt(src[(@as(usize, y1) * trace_w + x1) * 4 + ch]);
                        const top = c00 + (c10 - c00) * fx;
                        const bot = c01 + (c11 - c01) * fx;
                        upscaled[dst_off + ch] = @intFromFloat(std.math.clamp(top + (bot - top) * fy, 0, 255));
                    }
                }
            }
            break :blk upscaled;
        };
        defer if (trace_w != width or trace_h != height) self.allocator.free(upload_pixels);

        // --- 管理 GPU 纹理 ---
        if (self.rt_shadow_mask_texture == null or
            self.rt_shadow_mask_texture.?.desc.width != width or
            self.rt_shadow_mask_texture.?.desc.height != height)
        {
            if (self.rt_shadow_mask_texture) |*t| self.rhi.releaseTexture(t);
            self.rt_shadow_mask_texture = self.rhi.createTexture(.{
                .width = width,
                .height = height,
                .format = .bgra8_unorm,
                .usage = rhi_types.TextureUsage.sampler,
            }) catch return false;
        }

        self.rhi.uploadTextureData(&self.rt_shadow_mask_texture.?, upload_pixels, width, height) catch return false;
        return true;
    }

    // ==================================================================
    // Hardware RT — GPU 硬件加速路径追踪内部调度（自动集成在 PathTrace 模式中）
    // ==================================================================

    /// 尝试使用 GPU 硬件加速路径追踪。成功返回 true，不可用返回 false。
    fn tryRenderHwRtPath(
        self: *Renderer,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        scene: *scene_mod.Scene,
        target: anytype,
        width: u32,
        height: u32,
        trace_width: u32,
        trace_height: u32,
        samples: u32,
        bounces: u32,
        resolution_scale: f32,
    ) bool {
        // 懒初始化硬件 RT 后端
        if (self.rt_device == null) {
            self.rt_device = rt_device_mod.RtDevice.init();
            if (!self.rt_device.?.isAvailable()) {
                self.rt_device.?.deinit();
                self.rt_device = null;
                if (!g_logged_path_trace_active) {
                    render_log.info("{s} not available, using CPU path trace", .{rt_device_mod.RtDevice.backendName()});
                }
                return false;
            }
            render_log.info("{s} backend initialized — GPU path trace active", .{rt_device_mod.RtDevice.backendName()});
        }

        var rt_dev = &self.rt_device.?;
        var mrt = &self.hw_rt_state;

        // --- 变化检测 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&mrt.last_view_projection));
        const size_changed = trace_width != mrt.trace_width or trace_height != mrt.trace_height or width != mrt.target_width or height != mrt.target_height;
        const params_changed = samples != mrt.last_samples or bounces != mrt.last_bounces or resolution_scale != mrt.last_resolution_scale;

        if (vp_changed or params_changed) {
            mrt.needs_retrace = true;
        }
        if (size_changed) {
            mrt.reset(self.allocator);
            if (mrt.trace_pixels) |p| self.allocator.free(p);
            if (mrt.display_pixels) |p| self.allocator.free(p);
            mrt.trace_pixels = null;
            mrt.display_pixels = null;
        }

        mrt.last_view_projection = prepared_scene.view_projection;
        mrt.last_samples = samples;
        mrt.last_bounces = bounces;
        mrt.last_resolution_scale = resolution_scale;

        // --- 分配缓冲区 ---
        mrt.trace_pixels = mrt.trace_pixels orelse self.allocator.alloc(u8, @as(usize, trace_width) * trace_height * 4) catch return false;
        if (mrt.trace_width != trace_width or mrt.trace_height != trace_height) {
            @memset(mrt.trace_pixels.?, 0);
            mrt.trace_width = trace_width;
            mrt.trace_height = trace_height;
        }
        mrt.display_pixels = mrt.display_pixels orelse self.allocator.alloc(u8, @as(usize, width) * height * 4) catch return false;
        if (mrt.target_width != width or mrt.target_height != height) {
            @memset(mrt.display_pixels.?, 0);
            mrt.target_width = width;
            mrt.target_height = height;
        }

        // 若无变化且已追踪完成，直接上传缓存
        if (!mrt.needs_retrace and mrt.accel_built) {
            self.rhi.uploadTextureData(target, mrt.display_pixels.?, width, height) catch return false;
            return true;
        }

        // --- 构建/重建三角形数据 ---
        if (mrt.triangles == null) {
            var triangle_list: std.ArrayListUnmanaged(rt_backend.RtTriangle) = .empty;
            defer triangle_list.deinit(self.allocator);

            var texture_list = std.ArrayList(struct { pixels: []const u8, width: u32, height: u32 }).empty;
            defer texture_list.deinit(self.allocator);
            var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
            defer texture_index_map.deinit();

            for (prepared_scene.opaque_meshes) |item| {
                const mesh_res = if (handles.isValid(item.mesh_handle))
                    scene.resources.mesh(item.mesh_handle)
                else
                    null;
                if (mesh_res) |mesh| {
                    const indices = mesh.indices;
                    const vertices = mesh.vertices;
                    const albedo = [3]f32{
                        std.math.clamp(item.base_color_factor[0], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[1], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[2], 0.02, 1.0),
                    };
                    const emissive = [3]f32{
                        item.emissive_factor[0] * item.emissive_factor[3],
                        item.emissive_factor[1] * item.emissive_factor[3],
                        item.emissive_factor[2] * item.emissive_factor[3],
                    };
                    const metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                    const roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);

                    const tex_idx: i32 = blk_tex: {
                        if (item.has_textures[0] == 0) break :blk_tex @as(i32, -1);
                        const entity = scene.getEntityConst(item.entity_id) orelse break :blk_tex @as(i32, -1);
                        const mat_comp = entity.material orelse break :blk_tex @as(i32, -1);
                        const mat_handle = mat_comp.handle orelse break :blk_tex @as(i32, -1);
                        const mat_res = scene.resources.material(mat_handle) orelse break :blk_tex @as(i32, -1);
                        const tex_handle = mat_res.base_color_texture orelse break :blk_tex @as(i32, -1);
                        const tex_key = @intFromEnum(tex_handle);
                        if (texture_index_map.get(tex_key)) |existing| break :blk_tex existing;
                        const tex_res = scene.resources.texture(tex_handle) orelse break :blk_tex @as(i32, -1);
                        if (tex_res.pixels.len == 0 or tex_res.width == 0 or tex_res.height == 0) break :blk_tex @as(i32, -1);
                        const idx_i32: i32 = @intCast(texture_list.items.len);
                        texture_list.append(self.allocator, .{
                            .pixels = tex_res.pixels,
                            .width = tex_res.width,
                            .height = tex_res.height,
                        }) catch break :blk_tex @as(i32, -1);
                        texture_index_map.put(tex_key, idx_i32) catch break :blk_tex @as(i32, -1);
                        break :blk_tex idx_i32;
                    };

                    var i: usize = 0;
                    while (i + 2 < indices.len) : (i += 3) {
                        const idx0 = indices[i];
                        const idx1 = indices[i + 1];
                        const idx2 = indices[i + 2];
                        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                        triangle_list.append(self.allocator, .{
                            .v0 = transformPoint(item.model, vertices[idx0].position),
                            .v1 = transformPoint(item.model, vertices[idx1].position),
                            .v2 = transformPoint(item.model, vertices[idx2].position),
                            .n0 = transformNormal(item.model, vertices[idx0].normal),
                            .n1 = transformNormal(item.model, vertices[idx1].normal),
                            .n2 = transformNormal(item.model, vertices[idx2].normal),
                            .uv0 = vertices[idx0].uv,
                            .uv1 = vertices[idx1].uv,
                            .uv2 = vertices[idx2].uv,
                            .albedo = albedo,
                            .emissive = emissive,
                            .metallic = metallic,
                            .roughness = roughness,
                            .texture_index = tex_idx,
                        }) catch return false;
                    }
                }
            }

            // 无网格时显示地面平面
            if (triangle_list.items.len == 0) {
                triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, -5.0 },
                    .v2 = .{ 5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                }) catch return false;
                triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, 5.0 },
                    .v2 = .{ -5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                }) catch return false;
            }

            mrt.triangles = self.allocator.dupe(rt_backend.RtTriangle, triangle_list.items) catch return false;
            mrt.accel_built = false;

            // 打包纹理图集
            if (texture_list.items.len > 0) {
                var total_size: usize = 0;
                for (texture_list.items) |tex| total_size += tex.pixels.len;
                const atlas = self.allocator.alloc(u8, total_size) catch return false;
                const meta = self.allocator.alloc(rt_backend.RtTextureMeta, texture_list.items.len) catch {
                    self.allocator.free(atlas);
                    return false;
                };
                var offset: u32 = 0;
                for (texture_list.items, 0..) |tex, ti| {
                    @memcpy(atlas[offset..][0..tex.pixels.len], tex.pixels);
                    meta[ti] = .{ .offset = offset, .width = tex.width, .height = tex.height };
                    offset += @intCast(tex.pixels.len);
                }
                mrt.texture_atlas = atlas;
                mrt.texture_meta = meta;
            }
            mrt.textures_uploaded = false;
        }

        // --- 构建加速结构 ---
        if (!mrt.accel_built) {
            if (!rt_dev.buildAccelerationStructure(mrt.triangles.?)) {
                render_log.err("{s} acceleration structure build failed", .{rt_device_mod.RtDevice.backendName()});
                return false;
            }
            mrt.accel_built = true;
        }

        // --- 上传纹理图集到 GPU ---
        if (!mrt.textures_uploaded) {
            if (mrt.texture_atlas != null and mrt.texture_meta != null) {
                _ = rt_dev.uploadTextures(mrt.texture_atlas.?, mrt.texture_meta.?);
            } else {
                _ = rt_dev.uploadTextures(&.{}, &.{});
            }
            mrt.textures_uploaded = true;
        }

        // --- 光线追踪 ---
        const light_dir: [3]f32 = if (prepared_scene.lights.directional_lights.len > 0)
            vec3.normalize(vec3.scale(prepared_scene.lights.directional_lights[0].direction, -1.0))
        else
            vec3.normalize(.{ 0.38, 0.82, 0.42 });

        var params = rt_backend.RtParams{
            .inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity(),
            .camera_origin = .{
                prepared_scene.camera_world_position[0],
                prepared_scene.camera_world_position[1],
                prepared_scene.camera_world_position[2],
            },
            .light_direction = light_dir,
            .width = trace_width,
            .height = trace_height,
            .samples = samples,
            .bounces = bounces,
        };

        if (!rt_dev.traceRays(&params, mrt.trace_pixels.?)) {
            render_log.err("{s} trace failed", .{rt_device_mod.RtDevice.backendName()});
            return false;
        }
        mrt.needs_retrace = false;

        // --- 上采样 trace → display ---
        const trace_pixels = mrt.trace_pixels.?;
        const display_pixels = mrt.display_pixels.?;
        var out_y: u32 = 0;
        while (out_y < height) : (out_y += 1) {
            const src_y: u32 = @min(trace_height - 1, @as(u32, @intCast((@as(u64, out_y) * @as(u64, trace_height)) / @as(u64, height))));
            var out_x: u32 = 0;
            while (out_x < width) : (out_x += 1) {
                const src_x: u32 = @min(trace_width - 1, @as(u32, @intCast((@as(u64, out_x) * @as(u64, trace_width)) / @as(u64, width))));
                const src_idx: usize = (@as(usize, src_y) * @as(usize, trace_width) + @as(usize, src_x)) * 4;
                const dst_idx: usize = (@as(usize, out_y) * @as(usize, width) + @as(usize, out_x)) * 4;
                display_pixels[dst_idx + 0] = trace_pixels[src_idx + 0];
                display_pixels[dst_idx + 1] = trace_pixels[src_idx + 1];
                display_pixels[dst_idx + 2] = trace_pixels[src_idx + 2];
                display_pixels[dst_idx + 3] = trace_pixels[src_idx + 3];
            }
        }

        self.rhi.uploadTextureData(target, display_pixels, width, height) catch return false;
        return true;
    }

    /// Downloads the final rendered frame from GPU to CPU as RGBA8 pixels.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for returned pixel buffer. Caller owns and must free the slice.
    ///
    /// Returns: []u8 pixel data in RGBA8 format (4 bytes per pixel), row-major layout.
    /// Slice length = (width * height * 4) bytes. Caller must call allocator.free(result).
    ///
    /// Errors:
    /// - error.TextureNotFound: No offscreen render target (viewport not yet rendered).
    /// - error.CommandBufferAcquireFailed: GPU submission failed (GPU device lost?).
    /// - error.OutOfMemory: Allocation failed.
    ///
    /// Performance: Blocks CPU waiting for GPU readback. Do NOT call every frame in tight loops.
    /// Typical use: Screenshot export, video recording (async), debugging visualization.
    /// GPU-CPU sync point: GPU must complete rendering before transfer buffer becomes visible.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from render thread.
    pub fn downloadFinalFrameAlloc(self: *Renderer, allocator: std.mem.Allocator) ![]u8 {
        var pixels = try self.downloadFramePixelsAlloc(allocator);
        var i: usize = 0;
        while (i < pixels.data.len) : (i += 4) {
            const b = pixels.data[i + 0];
            pixels.data[i + 0] = pixels.data[i + 2];
            pixels.data[i + 2] = b;
        }
        return pixels.data;
    }

    /// Download final frame pixels as raw BGRA byte data from the LDR color texture.
    /// Returns allocated byte slice (caller owns memory).
    pub fn downloadFramePixelsAlloc(self: *Renderer, allocator: std.mem.Allocator) !FramePixels {
        const texture = self.scene_viewport.color_texture orelse return error.TextureNotFound;
        const width = texture.desc.width;
        const height = texture.desc.height;
        const row_bytes = width * 4;
        const byte_count = row_bytes * height;

        const data = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(data);

        try self.rhi.readTextureData(&texture, row_bytes, data);

        return .{ .data = data, .width = width, .height = height };
    }

    pub const FramePixels = struct {
        data: []u8,
        width: u32,
        height: u32,
    };

    /// Export a single frame to PNG at the given path.
    /// Performs GPU readback + CPU-side PNG encode + disk write.
    pub fn exportFramePng(self: *Renderer, allocator: std.mem.Allocator, out_path: []const u8) !void {
        const pixels = try self.downloadFramePixelsAlloc(allocator);
        defer allocator.free(pixels.data);

        // BGRA → RGBA in-place
        var i: usize = 0;
        while (i < pixels.data.len) : (i += 4) {
            const b = pixels.data[i];
            pixels.data[i] = pixels.data[i + 2];
            pixels.data[i + 2] = b;
        }

        const c = @cImport({
            @cDefine("STBI_WRITE_NO_STDIO", "1");
            @cInclude("stb_image_write.h");
        });

        var out_len: c_int = 0;
        const png_data = c.stbi_write_png_to_mem(
            pixels.data.ptr,
            @intCast(pixels.width * 4),
            @intCast(pixels.width),
            @intCast(pixels.height),
            4,
            &out_len,
        ) orelse return error.PngEncodingFailed;
        defer c.free(png_data);

        const png_slice: []const u8 = @ptrCast(png_data[0..@intCast(out_len)]);

        const file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        try file.writeAll(png_slice);
    }

    fn buildSceneSnapshot(scene: *const scene_mod.Scene) types.SceneSnapshot {
        const summary = scene.summary();
        return .{
            .entity_count = summary.entity_count,
            .camera_count = summary.camera_count,
            .mesh_count = summary.mesh_count,
            .material_count = summary.material_count,
            .light_count = summary.light_count,
        };
    }

    fn clearAndDepthForScene(snapshot: types.SceneSnapshot, pass_count: usize) rhi_types.ClearState {
        const mesh_bias = @as(f32, @floatFromInt(@min(snapshot.mesh_count, 12))) * 0.01;
        const light_bias = @as(f32, @floatFromInt(@min(snapshot.light_count, 4))) * 0.02;
        const pass_bias = @as(f32, @floatFromInt(@min(pass_count, 8))) * 0.005;

        return .{
            .color = .{
                0.05 + mesh_bias,
                0.06 + light_bias,
                0.1 + pass_bias,
                1.0,
            },
            .depth = 1.0,
        };
    }

    fn processMaterialThumbnailRequests(
        self: *Renderer,
        frame: rhi_mod.Frame,
        scene: *const scene_mod.Scene,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
            return stats;
        }

        var processed: usize = 0;
        while (processed < material_thumbnail_jobs_per_frame and self.material_thumbnail_requests.items.len > 0) : (processed += 1) {
            const asset_id = self.material_thumbnail_requests.orderedRemove(0);
            defer self.allocator.free(asset_id);

            const entry_ptr = self.findMaterialThumbnailCacheIndex(asset_id) orelse continue;
            entry_ptr.queued = false;

            const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
                self.removeMaterialThumbnail(asset_id);
                continue;
            };

            try self.material_thumbnail_preview.syncFromSource(source);
            self.thumbnail_scene_cache.invalidateMaterialResources(&self.rhi);

            _ = try scene_extraction.extractWorld(
                &self.material_thumbnail_preview.world,
                &self.thumbnail_render_world,
                null,
                &.{},
                null,
            );

            var prepared_scene = try self.thumbnail_scene_cache.prepareScene(
                &self.rhi,
                &self.material_thumbnail_preview.world,
                &self.thumbnail_render_world,
                material_thumbnail_dimension,
                material_thumbnail_dimension,
            );
            defer prepared_scene.deinit();

            const render_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                .color = .{
                    .target = .{ .texture = &entry_ptr.target.color_texture },
                    .clear_color = material_thumbnail_clear_color,
                    .load_op = .clear,
                    .store_op = .store,
                },
                .depth = .{
                    .texture = &entry_ptr.target.depth_texture,
                    .clear_depth = 1.0,
                    .clear_stencil = 0,
                    .load_op = .clear,
                    .store_op = .dont_care,
                    .stencil_load_op = .dont_care,
                    .stencil_store_op = .dont_care,
                },
            });

            const depth_stats = self.depth_prepass.draw(&self.rhi, frame, render_pass, &prepared_scene);
            stats.add(depth_stats);
            const base_stats = try self.base_pass.draw(&self.rhi, frame, render_pass, &prepared_scene, .{
                .render_mode = thumbnail_viewport_state.render_mode,
                .target = .ldr,
            });
            stats.add(base_stats);
            self.rhi.endRenderPass(render_pass);

            entry_ptr.signature = source.signature;
            entry_ptr.dirty = false;
            entry_ptr.ready = true;
        }

        return stats;
    }

    fn findMaterialThumbnailCacheIndex(self: *const Renderer, asset_id: []const u8) ?*MaterialThumbnailCacheEntry {
        return self.material_thumbnail_cache.getPtr(asset_id);
    }

    fn ensureMaterialThumbnailEntry(self: *Renderer, asset_id: []const u8) !*MaterialThumbnailCacheEntry {
        if (self.material_thumbnail_cache.getPtr(asset_id)) |entry| {
            return entry;
        }

        if (self.material_thumbnail_cache.count() >= material_thumbnail_cache_limit) {
            self.evictMaterialThumbnailEntry(asset_id);
        }

        const owned_asset_id = try self.allocator.dupe(u8, asset_id);
        errdefer self.allocator.free(owned_asset_id);

        const target = try ThumbnailRenderTarget.init(&self.rhi);
        errdefer {
            var owned = target;
            owned.deinit(&self.rhi);
        }

        const entry = MaterialThumbnailCacheEntry{
            .asset_id = owned_asset_id,
            .target = target,
        };
        try self.material_thumbnail_cache.put(owned_asset_id, entry);
        return self.material_thumbnail_cache.getPtr(owned_asset_id).?;
    }

    fn enqueueMaterialThumbnailRequest(self: *Renderer, entry: *MaterialThumbnailCacheEntry) !void {
        const queued_asset_id = try self.allocator.dupe(u8, entry.asset_id);
        errdefer self.allocator.free(queued_asset_id);

        try self.material_thumbnail_requests.append(self.allocator, queued_asset_id);
        entry.queued = true;
    }

    fn evictMaterialThumbnailEntry(self: *Renderer, keep_asset_id: []const u8) void {
        var oldest_unqueued_key: ?[]const u8 = null;
        var oldest_any_key: ?[]const u8 = null;
        var min_frame_unqueued: u64 = std.math.maxInt(u64);
        var min_frame_any: u64 = std.math.maxInt(u64);

        var it = self.material_thumbnail_cache.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr;
            if (std.mem.eql(u8, key, keep_asset_id)) {
                continue;
            }
            // 记录全局最老的
            if (value.last_requested_frame < min_frame_any) {
                min_frame_any = value.last_requested_frame;
                oldest_any_key = key;
            }
            // 记录非排队中最老的
            if (!value.queued and value.last_requested_frame < min_frame_unqueued) {
                min_frame_unqueued = value.last_requested_frame;
                oldest_unqueued_key = key;
            }
        }

        const key_to_remove = oldest_unqueued_key orelse oldest_any_key;
        if (key_to_remove) |key| {
            if (self.material_thumbnail_cache.fetchRemove(key)) |kv| {
                var value = kv.value;
                value.deinit(self.allocator, &self.rhi);
            }
        }
    }

    fn removeMaterialThumbnail(self: *Renderer, asset_id: []const u8) void {
        if (self.material_thumbnail_cache.fetchRemove(asset_id)) |kv| {
            var value = kv.value;
            value.deinit(self.allocator, &self.rhi);
        }
    }

    fn releaseMaterialThumbnailCache(self: *Renderer) void {
        var it = self.material_thumbnail_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator, &self.rhi);
        }
        self.material_thumbnail_cache.deinit();
        self.material_thumbnail_cache = undefined;
    }

    fn releaseMaterialThumbnailRequests(self: *Renderer) void {
        for (self.material_thumbnail_requests.items) |asset_id| {
            self.allocator.free(asset_id);
        }
        self.material_thumbnail_requests.deinit(self.allocator);
        self.material_thumbnail_requests = .empty;
    }

    fn durationNs(start: i128, end: i128) u64 {
        return if (end > start) @intCast(end - start) else 0;
    }

    fn gizmoPassRequired(self: *const Renderer, _: *const scene_mod.Scene) bool {
        if (!self.gizmo_pass.isReady()) {
            return false;
        }
        return self.selection_history.primarySelection() != null or
            self.preview_gizmo_transform != null or
            self.editor_viewport_state.show_grid or
            self.editor_viewport_state.show_bones or
            self.editor_viewport_state.show_collision;
    }

    fn drawViewportDebugOverlays(
        self: *Renderer,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        scene: *scene_mod.Scene,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        physics_state_opt: ?*physics_mod.PhysicsState,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};

        if (self.editor_viewport_state.show_grid) {
            var grid_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer grid_lines.deinit(self.allocator);
            try appendGridLines(self.allocator, &grid_lines);
            // Darker grid color (0.12, 0.14, 0.18) - subtle gray that won't compete with scene objects
            const grid_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                grid_lines.items,
                .{ 0.12, 0.14, 0.18, 0.7 },
            );
            stats.add(grid_stats);
        }

        if (self.editor_viewport_state.show_bones) {
            var bone_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer bone_lines.deinit(self.allocator);
            try appendBoneLines(self.allocator, scene, &bone_lines);
            const bone_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                bone_lines.items,
                .{ 0.95, 0.58, 0.24, 1.0 },
            );
            stats.add(bone_stats);
        }

        if (self.editor_viewport_state.show_collision) {
            var solid_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer solid_lines.deinit(self.allocator);
            var trigger_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer trigger_lines.deinit(self.allocator);

            try appendCollisionLines(self.allocator, scene, prepared_scene, &solid_lines, &trigger_lines, physics_state_opt);

            var collision_stats = mesh_pass_mod.DrawStats{};
            if (solid_lines.items.len > 0) {
                const solid_stats = try self.gizmo_pass.drawWorldLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    solid_lines.items,
                    .{ 0.30, 0.92, 0.52, 1.0 },
                );
                collision_stats.add(solid_stats);
            }
            if (trigger_lines.items.len > 0) {
                const trigger_stats = try self.gizmo_pass.drawWorldLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    trigger_lines.items,
                    .{ 0.92, 0.70, 0.30, 1.0 },
                );
                collision_stats.add(trigger_stats);
            }
            stats.add(collision_stats);
        }

        return stats;
    }

    fn appendGridLines(
        allocator: std.mem.Allocator,
        lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    ) !void {
        // Reduced grid extent from 16 to 12 - less visual clutter
        const half_extent: i32 = 12;
        var index: i32 = -half_extent;
        while (index <= half_extent) : (index += 1) {
            const offset = @as(f32, @floatFromInt(index));
            try appendLine(allocator, lines, .{ offset, 0.0, -@as(f32, @floatFromInt(half_extent)) }, .{ offset, 0.0, @as(f32, @floatFromInt(half_extent)) });
            try appendLine(allocator, lines, .{ -@as(f32, @floatFromInt(half_extent)), 0.0, offset }, .{ @as(f32, @floatFromInt(half_extent)), 0.0, offset });
        }
    }

    fn appendBoneLines(
        allocator: std.mem.Allocator,
        scene: *const scene_mod.Scene,
        lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    ) !void {
        for (scene.entities.items) |entity| {
            const parent_id = entity.parent orelse continue;
            const parent_transform = scene.worldTransformConst(parent_id) orelse continue;
            const child_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
            try appendLine(allocator, lines, parent_transform.translation, child_transform.translation);
        }
    }

    fn appendCollisionLines(
        allocator: std.mem.Allocator,
        scene: *scene_mod.Scene,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        solid_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
        trigger_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
        physics_state_opt: ?*physics_mod.PhysicsState,
    ) !void {
        // 优先使用物理调试信息绘制真实的 collider 形状
        const debug_shapes = if (physics_state_opt) |ps|
            try ps.collectDebugShapes(scene, allocator)
        else
            &[0]physics_mod.PhysicsDebugInfo{};
        defer allocator.free(debug_shapes);

        if (debug_shapes.len > 0) {
            if (g_logged_collision_overlay_boxes == null or g_logged_collision_overlay_boxes.? != debug_shapes.len) {
                render_log.info("physics debug draw shapes={}", .{debug_shapes.len});
                g_logged_collision_overlay_boxes = debug_shapes.len;
            }

            for (debug_shapes) |shape| {
                switch (shape.shape) {
                    .box => |box| {
                        const aabb = AABB{
                            .min = vec3.sub(box.center, box.half_extents),
                            .max = vec3.add(box.center, box.half_extents),
                        };
                        if (shape.is_trigger) {
                            try appendBoxEdges(allocator, trigger_lines, cornersForAabb(aabb));
                        } else {
                            try appendBoxEdges(allocator, solid_lines, cornersForAabb(aabb));
                        }
                    },
                    .sphere => |sphere| {
                        if (shape.is_trigger) {
                            try appendSphereEdges(allocator, trigger_lines, sphere.center, sphere.radius, 16);
                        } else {
                            try appendSphereEdges(allocator, solid_lines, sphere.center, sphere.radius, 16);
                        }
                    },
                }
            }
            return;
        }

        // 回退到渲染 BVH bounds
        const collision_frustum = frustum_mod.Frustum.fromViewProjection(prepared_scene.view_projection);
        const bounds_items = try scene.queryRenderableBoundsInFrustum(allocator, collision_frustum);
        defer allocator.free(bounds_items);

        if (g_logged_collision_overlay_boxes == null or g_logged_collision_overlay_boxes.? != bounds_items.len) {
            render_log.info("collision overlay reusing renderable BVH bounds boxes={}", .{bounds_items.len});
            g_logged_collision_overlay_boxes = bounds_items.len;
        }

        // 碰撞可视化直接吃 world bounds cache + BVH 视锥候选，后续 selection debug 可以复用同一路。
        for (bounds_items) |item| {
            try appendBoxEdges(allocator, solid_lines, cornersForAabb(item.bounds));
        }
    }

    fn cornersForAabb(bounds: AABB) [8][3]f32 {
        const min = bounds.min;
        const max = bounds.max;
        return .{
            .{ min[0], min[1], min[2] },
            .{ max[0], min[1], min[2] },
            .{ max[0], max[1], min[2] },
            .{ min[0], max[1], min[2] },
            .{ min[0], min[1], max[2] },
            .{ max[0], min[1], max[2] },
            .{ max[0], max[1], max[2] },
            .{ min[0], max[1], max[2] },
        };
    }

    fn appendBoxEdges(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), corners: [8][3]f32) !void {
        try appendLine(allocator, lines, corners[0], corners[1]);
        try appendLine(allocator, lines, corners[1], corners[2]);
        try appendLine(allocator, lines, corners[2], corners[3]);
        try appendLine(allocator, lines, corners[3], corners[0]);
        try appendLine(allocator, lines, corners[4], corners[5]);
        try appendLine(allocator, lines, corners[5], corners[6]);
        try appendLine(allocator, lines, corners[6], corners[7]);
        try appendLine(allocator, lines, corners[7], corners[4]);
        try appendLine(allocator, lines, corners[0], corners[4]);
        try appendLine(allocator, lines, corners[1], corners[5]);
        try appendLine(allocator, lines, corners[2], corners[6]);
        try appendLine(allocator, lines, corners[3], corners[7]);
    }

    fn appendLine(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), a: [3]f32, b: [3]f32) !void {
        try lines.append(allocator, .{ .position = a });
        try lines.append(allocator, .{ .position = b });
    }

    fn appendSphereEdges(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), center: [3]f32, radius: f32, segments: u32) !void {
        const pi = std.math.pi;

        // 绘制纬线
        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const lat1 = pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) - pi / 2.0;
            const lat2 = pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) - pi / 2.0;

            var j: u32 = 0;
            while (j < segments) : (j += 1) {
                const lon1 = 2.0 * pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segments));
                const lon2 = 2.0 * pi * @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(segments));

                const p1 = sphericalToCartesian(center, radius, lat1, lon1);
                const p2 = sphericalToCartesian(center, radius, lat1, lon2);
                const p3 = sphericalToCartesian(center, radius, lat2, lon1);

                try appendLine(allocator, lines, p1, p2);
                try appendLine(allocator, lines, p1, p3);
            }
        }
    }

    fn sphericalToCartesian(center: [3]f32, radius: f32, lat: f32, lon: f32) [3]f32 {
        const x = radius * std.math.cos(lat) * std.math.cos(lon);
        const y = radius * std.math.sin(lat);
        const z = radius * std.math.cos(lat) * std.math.sin(lon);
        return .{ center[0] + x, center[1] + y, center[2] + z };
    }

    fn enqueueSelectionReadbacks(self: *Renderer, frame: rhi_mod.Frame, id_texture: *const rhi_mod.Texture) !void {
        const pending = self.pending_selection_readbacks.items;
        const total_buffer_size = std.math.cast(u32, pending.len * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory;

        if (id_texture.desc.width == 0 or id_texture.desc.height == 0) {
            try self.rhi.submitFrame(frame);
            try self.applyPendingSelectionMisses();
            return;
        }

        var readbacks = try self.allocator.alloc(InFlightSelectionReadback, pending.len);
        errdefer self.allocator.free(readbacks);

        var transfer_buffer = try self.rhi.createTransferBuffer(.{
            .size = total_buffer_size,
            .upload = false,
        });
        errdefer self.rhi.releaseTransferBuffer(&transfer_buffer);

        for (pending, 0..) |request, index| {
            readbacks[index] = .{
                .request = request,
                .offset = std.math.cast(u32, index * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory,
            };
        }

        const copy_pass = try self.rhi.beginCopyPass(frame);

        for (readbacks) |readback| {
            const pixel_x = @min(readback.request.pixel_x, id_texture.desc.width - 1);
            const pixel_y = @min(readback.request.pixel_y, id_texture.desc.height - 1);
            self.rhi.downloadTexturePixelToOffset(copy_pass, id_texture, &transfer_buffer, readback.offset, pixel_x, pixel_y);
        }

        self.rhi.endCopyPass(copy_pass);

        var fence = try self.rhi.submitFrameAndAcquireFence(frame);
        errdefer self.rhi.releaseFence(&fence);

        try self.in_flight_selection_batches.append(self.allocator, .{
            .fence = fence,
            .transfer_buffer = transfer_buffer,
            .readbacks = readbacks,
        });
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn resolveSelectionReadbacks(self: *Renderer) !void {
        while (self.in_flight_selection_batches.items.len > 0) {
            if (!self.rhi.isFenceSignaled(&self.in_flight_selection_batches.items[0].fence)) {
                break;
            }

            var batch = self.in_flight_selection_batches.orderedRemove(0);
            defer batch.deinit(self.allocator, &self.rhi);

            for (batch.readbacks) |readback| {
                var pixel: [4]u8 = undefined;
                try self.rhi.readTransferBufferBytesAt(&batch.transfer_buffer, readback.offset, pixel[0..]);
                const entity = id_pass_mod.decodeEntityIdBgra(pixel);
                _ = try self.selection_history.applyPick(entity, readback.request.mode);
            }
        }
    }

    fn applyPendingSelectionMisses(self: *Renderer) !void {
        for (self.pending_selection_readbacks.items) |request| {
            _ = try self.selection_history.applyPick(null, request.mode);
        }
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn releaseInFlightSelectionBatches(self: *Renderer) void {
        for (self.in_flight_selection_batches.items) |*batch| {
            batch.deinit(self.allocator, &self.rhi);
        }
        self.in_flight_selection_batches.deinit(self.allocator);
    }
};

fn shadowViewUpVector(light_dir: [3]f32) [3]f32 {
    const default_up = [3]f32{ 0.0, 1.0, 0.0 };
    if (@abs(vec3.dot(light_dir, default_up)) > 0.99) {
        return .{ 0.0, 0.0, 1.0 };
    }
    return default_up;
}

/// Practical split scheme: lerp between logarithmic and uniform distribution.
/// lambda = 1.0 → fully logarithmic, lambda = 0.0 → fully uniform.
fn computeCascadeSplits(near: f32, far: f32, comptime count: usize, lambda: f32) [count]f32 {
    var splits: [count]f32 = undefined;
    for (0..count) |i| {
        const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(count));
        const log_split = near * std.math.pow(f32, far / near, p);
        const uni_split = near + (far - near) * p;
        splits[i] = lambda * log_split + (1.0 - lambda) * uni_split;
    }
    return splits;
}

/// Transform a Vec4 (x,y,z,w) by a 4×4 column-major matrix, return (x,y,z) after perspective divide.
fn transformPoint4(m: [16]f32, pt: [4]f32) [3]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |r| {
        out[r] = m[0 * 4 + r] * pt[0] + m[1 * 4 + r] * pt[1] + m[2 * 4 + r] * pt[2] + m[3 * 4 + r] * pt[3];
    }
    const w = if (@abs(out[3]) > 1e-7) out[3] else 1.0;
    return .{ out[0] / w, out[1] / w, out[2] / w };
}

/// Compute a tight-fit light-space VP matrix for one cascade.
/// `split_near`/`split_far` are view-space Z distances (positive values).
fn computeCascadeMatrix(
    camera_inv_vp: [16]f32,
    split_near: f32,
    split_far: f32,
    cam_near: f32,
    cam_far: f32,
    light_dir: [3]f32,
    texel_size: f32,
) [16]f32 {
    const mat4 = @import("../math/mat4.zig");

    // Map split_near/split_far into NDC Z range [0,1] (our perspective maps near→0, far→1).
    // perspective: Z_ndc = far*(z - near) / (z*(near - far))  ... after w divide.
    // We need the clip-space z/w for a given view-space depth.
    // For our reversed-depth-style: z_ndc = (far * near / z - near) / (far - near) ... simplified.
    // Actually let's just linearly remap: NDC_z for a view-space depth d =
    //   (far / (near - far)) * (near / d) + far*near/(near-far) ... let's compute directly.
    // Our perspective: M[2][2] = far/(near-far), M[3][2] = far*near/(near-far), M[2][3] = -1
    // clip_z = M[2][2]*z_view + M[3][2],  clip_w = -z_view  →  ndc_z = clip_z / clip_w
    // z_view is negative in view space (camera looks -Z).  So for a depth d (positive):
    //   z_view = -d, clip_z = M[2][2]*(-d) + M[3][2], clip_w = d
    //   ndc_z = (-M[2][2]*d + M[3][2]) / d
    // With M[2][2] = far/(near-far), M[3][2] = far*near/(near-far):
    //   ndc_z = (-far*d/(near-far) + far*near/(near-far)) / d
    //         = far*(near - d) / (d*(near - far))
    const ndc_near = cam_far * (cam_near - split_near) / (split_near * (cam_near - cam_far));
    const ndc_far = cam_far * (cam_near - split_far) / (split_far * (cam_near - cam_far));

    // 8 corners of the sub-frustum in NDC: x,y ∈ {-1,1}, z ∈ {ndc_near, ndc_far}
    const ndc_corners = [8][4]f32{
        .{ -1, -1, ndc_near, 1 }, .{ 1, -1, ndc_near, 1 },
        .{ -1, 1, ndc_near, 1 },  .{ 1, 1, ndc_near, 1 },
        .{ -1, -1, ndc_far, 1 },  .{ 1, -1, ndc_far, 1 },
        .{ -1, 1, ndc_far, 1 },   .{ 1, 1, ndc_far, 1 },
    };

    // Transform corners to world space
    var world_corners: [8][3]f32 = undefined;
    var center: [3]f32 = .{ 0, 0, 0 };
    for (0..8) |i| {
        world_corners[i] = transformPoint4(camera_inv_vp, ndc_corners[i]);
        center[0] += world_corners[i][0];
        center[1] += world_corners[i][1];
        center[2] += world_corners[i][2];
    }
    center = vec3.scale(center, 1.0 / 8.0);

    // Build light view looking at cascade center
    const light_pos = vec3.sub(center, vec3.scale(light_dir, 50.0)); // back away from center
    const light_view = mat4.lookAt(light_pos, center, shadowViewUpVector(light_dir));

    // Transform world corners into light view space, compute AABB
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var min_z: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var max_z: f32 = -std.math.floatMax(f32);
    for (world_corners) |corner| {
        const lv = transformPoint4(light_view, .{ corner[0], corner[1], corner[2], 1.0 });
        min_x = @min(min_x, lv[0]);
        max_x = @max(max_x, lv[0]);
        min_y = @min(min_y, lv[1]);
        max_y = @max(max_y, lv[1]);
        min_z = @min(min_z, lv[2]);
        max_z = @max(max_z, lv[2]);
    }

    // Extend Z range to catch shadow casters behind the camera
    const z_range = max_z - min_z;
    min_z -= z_range * 2.0;

    // Snap to texel grid to prevent shadow swimming when the camera moves
    if (texel_size > 0) {
        const world_units_per_texel_x = (max_x - min_x) / texel_size;
        const world_units_per_texel_y = (max_y - min_y) / texel_size;
        if (world_units_per_texel_x > 0) {
            min_x = @floor(min_x / world_units_per_texel_x) * world_units_per_texel_x;
            max_x = @floor(max_x / world_units_per_texel_x) * world_units_per_texel_x;
        }
        if (world_units_per_texel_y > 0) {
            min_y = @floor(min_y / world_units_per_texel_y) * world_units_per_texel_y;
            max_y = @floor(max_y / world_units_per_texel_y) * world_units_per_texel_y;
        }
    }

    const light_proj = mat4.orthographicOffCenter(min_x, max_x, min_y, max_y, min_z, max_z);
    return mat4.mul(light_proj, light_view);
}

fn resolveEnvironmentTextures(
    self: *Renderer,
    scene: *scene_mod.Scene,
    prepared_scene: *mesh_pass_mod.PreparedScene,
) !void {
    // Use cached textures if already resolved (avoid per-frame disk I/O + IBL decode)
    if (self.cached_env_textures.resolved) {
        prepared_scene.environment_map = self.cached_env_textures.environment_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.irradiance_map = self.cached_env_textures.irradiance_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.prefiltered_env_map = self.cached_env_textures.prefiltered_env_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.brdf_lut = self.cached_env_textures.brdf_lut orelse self.scene_cache.fallbackBrdfLut();
        return;
    }

    prepared_scene.environment_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.irradiance_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.prefiltered_env_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.brdf_lut = self.scene_cache.fallbackBrdfLut();

    // Mark resolved early so we never retry on failure (each attempt costs ~9s of disk I/O)
    self.cached_env_textures = .{
        .resolved = true,
        .environment_map = null,
        .irradiance_map = null,
        .prefiltered_env_map = null,
        .brdf_lut = null,
    };

    const environment_asset_id = findSceneEnvironmentAssetId(&scene.resources) orelse {
        if (!g_logged_environment_status) {
            render_log.warn("no HDR environment asset found; using fallback environment textures", .{});
            g_logged_environment_status = true;
        }
        return;
    };
    if (!g_logged_environment_status) {
        render_log.info("environment asset selected: {s}", .{environment_asset_id});
        g_logged_environment_status = true;
    }
    _ = texture_import_mod.loadTextureAsset(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load environment texture asset '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        return;
    };

    var environment = environment_map_import_mod.loadIBLData(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load IBL data for '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        return;
    };
    defer environment.deinit(self.allocator);

    if (environment.environment_map_handle) |handle| {
        prepared_scene.environment_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.irradiance_map_handle) |handle| {
        prepared_scene.irradiance_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.prefiltered_map_handle) |handle| {
        prepared_scene.prefiltered_env_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.brdf_lut_handle) |handle| {
        prepared_scene.brdf_lut = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }

    // Cache resolved textures for subsequent frames
    self.cached_env_textures = .{
        .resolved = true,
        .environment_map = prepared_scene.environment_map,
        .irradiance_map = prepared_scene.irradiance_map,
        .prefiltered_env_map = prepared_scene.prefiltered_env_map,
        .brdf_lut = prepared_scene.brdf_lut,
    };
}

fn findSceneEnvironmentAssetId(resources: *const assets_lib.ResourceLibrary) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (resources.asset_registry.records.items) |record| {
        if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
            continue;
        }
        fallback = fallback orelse record.id;
        if (isLikelyEnvironmentPath(record.source_path)) {
            return record.id;
        }
    }
    return fallback;
}

fn isLikelyEnvironmentPath(path: []const u8) bool {
    return containsIgnoreCase(path, "sky") or
        containsIgnoreCase(path, "env") or
        containsIgnoreCase(path, "ibl") or
        containsIgnoreCase(path, "ticknock");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matched = false;
                break;
            }
        }
        if (matched) {
            return true;
        }
    }
    return false;
}

fn resolveMaterialThumbnailSource(
    resources: *const assets_lib.ResourceLibrary,
    asset_id: []const u8,
) ?MaterialThumbnailSource {
    const material_handle = resources.materialHandleByAssetId(asset_id) orelse return null;
    const material = resources.material(material_handle) orelse return null;

    var source = MaterialThumbnailSource{
        .material_handle = material_handle,
        .material = material,
        .signature = .{
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
        },
    };

    if (material.base_color_texture) |texture_handle| {
        if (resources.texture(texture_handle)) |texture| {
            source.texture = texture;
            source.signature.texture = .{
                .handle = texture_handle,
                .width = texture.width,
                .height = texture.height,
                .format = texture.format,
            };
        }
    }

    return source;
}

fn lookRotationEuler(from: [3]f32, to: [3]f32) [3]f32 {
    const direction = vec3.normalize(vec3.sub(to, from));
    return .{
        std.math.asin(std.math.clamp(direction[1], -1.0, 1.0)),
        std.math.atan2(-direction[0], -direction[2]),
        0.0,
    };
}

fn makeOwnedTestAssetRecord(
    allocator: std.mem.Allocator,
    asset_type: registry_mod.AssetType,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !registry_mod.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = asset_type,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "thumbnail-test-source"),
        .import_settings_hash = try allocator.dupe(u8, "thumbnail-test-settings"),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ".thumb"),
        },
    };
}

test "resolveMaterialThumbnailSource captures loaded material signatures" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewAlbedo",
        .width = 4,
        .height = 2,
        .pixels = &[_]u8{
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://preview", "assets/textures/preview.png", "Preview Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewMaterial",
        .shading = .lambert,
        .base_color_factor = .{ 0.2, 0.4, 0.6, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://preview", "assets/materials/preview.guava_material", "Preview Material"),
    );

    const source = resolveMaterialThumbnailSource(world.assets(), "material://preview").?;
    try std.testing.expectEqual(material_handle, source.material_handle);
    try std.testing.expectEqual(components.ShadingModel.lambert, source.signature.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.2, 0.4, 0.6, 1.0 }, source.signature.base_color_factor);
    try std.testing.expectEqual(texture_handle, source.signature.texture.handle.?);
    try std.testing.expectEqual(@as(u32, 4), source.signature.texture.width);
    try std.testing.expectEqual(@as(u32, 2), source.signature.texture.height);
}

test "material thumbnail preview scene mirrors source material resources" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewSyncTexture",
        .width = 2,
        .height = 2,
        .pixels = &[_]u8{
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://sync", "assets/textures/sync.png", "Sync Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewSyncMaterial",
        .shading = .unlit,
        .base_color_factor = .{ 0.9, 0.3, 0.1, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://sync", "assets/materials/sync.guava_material", "Sync Material"),
    );

    var preview = try MaterialThumbnailPreview.init(std.testing.allocator);
    defer preview.deinit();

    const source = resolveMaterialThumbnailSource(world.assets(), "material://sync").?;
    try preview.syncFromSource(source);

    const preview_material = preview.world.resources.material(preview.preview_material_handle).?;
    try std.testing.expectEqual(components.ShadingModel.unlit, preview_material.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.9, 0.3, 0.1, 1.0 }, preview_material.base_color_factor);
    try std.testing.expect(preview_material.base_color_texture != null);

    const preview_texture = preview.world.resources.texture(preview_material.base_color_texture.?).?;
    try std.testing.expectEqual(@as(u32, 2), preview_texture.width);
    try std.testing.expectEqual(@as(u32, 2), preview_texture.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
    }, preview_texture.pixels);
}
