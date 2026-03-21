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
const fxaa_pass_mod = @import("fxaa_pass.zig");
const tonemap_pass_mod = @import("tonemap_pass.zig");
const depth_prepass_mod = @import("depth_prepass.zig");
const id_pass_mod = @import("id_pass.zig");
const gizmo_pass_mod = @import("gizmo_pass.zig");
const outline_pass_mod = @import("outline_pass.zig");
const platform_mod = @import("../core/platform.zig");
const selection_history_mod = @import("selection_history.zig");
const imgui_mod = @import("../ui/imgui.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const scene_extraction = @import("scene_extraction.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const vec3 = @import("../math/vec3.zig");
const physics_mod = @import("../physics/system.zig");
const PassDescriptors = @import("render_helpers.zig").PassDescriptors;
const render_log = std.log.scoped(.viewport_render);

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
    const camera_id = world.primaryCameraEntity() orelse return null;
    const camera_entity = world.getEntityConst(camera_id) orelse return null;
    const camera_component = camera_entity.camera orelse return null;
    const world_transform = world.worldTransformConst(camera_id) orelse camera_entity.local_transform;
    const camera_block = mesh_pass_mod.CameraBlock{
        .transform = world_transform,
        .camera = camera_component,
        .is_primary = camera_component.is_primary,
    };
    // 主场景现在在 extraction 阶段就拿到主相机视锥，避免 mesh pass 重复扫 mesh。
    const view_projection = scene_cache.calculateViewProjection(camera_block, width, height);
    return frustum_mod.Frustum.fromViewProjection(view_projection);
}

fn previewRenderMode(render_mode: types.EditorViewportRenderMode) types.EditorViewportRenderMode {
    return switch (render_mode) {
        .wireframe => .textured,
        else => render_mode,
    };
}

const SceneViewportState = struct {
    width: u32 = 0,
    height: u32 = 0,
    hdr_color_texture: ?rhi_mod.Texture = null,
    bloom_texture: ?rhi_mod.Texture = null,
    fxaa_texture: ?rhi_mod.Texture = null,
    color_texture: ?rhi_mod.Texture = null,
    depth_texture: ?rhi_mod.Texture = null,

    fn deinit(self: *SceneViewportState, device: *rhi_mod.RhiDevice) void {
        if (self.hdr_color_texture) |*texture| {
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
            if (self.depth_texture != null and self.hdr_color_texture != null and self.bloom_texture != null and self.fxaa_texture != null and color_texture.desc.width == width and color_texture.desc.height == height) {
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
            .usage = rhi_types.TextureUsage.depth_stencil_target,
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

const ShadowMapState = struct {
    size: u32 = 2048,
    depth_texture: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,

    fn init(device: *rhi_mod.RhiDevice) !ShadowMapState {
        const size: u32 = 2048;
        const depth_texture = try device.createTexture(.{
            .width = size,
            .height = size,
            .format = .d32_float,
            .usage = rhi_types.TextureUsage.depth_stencil_target | rhi_types.TextureUsage.sampler,
            .label = "ShadowMap",
        });

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
            .depth_texture = depth_texture,
            .sampler = sampler,
        };
    }

    fn deinit(self: *ShadowMapState, device: *rhi_mod.RhiDevice) void {
        if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        self.* = .{};
    }
};

const material_thumbnail_dimension: u32 = 128;
const material_thumbnail_jobs_per_frame: usize = 2;
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
    /// 泛光后处理通道
    bloom_pass: bloom_pass_mod.BloomPass,
    /// FXAA 抗锯齿通道
    fxaa_pass: fxaa_pass_mod.FxaaPass,
    /// 轮廓通道（选中物体高亮）
    outline_pass: outline_pass_mod.OutlinePass,
    /// Gizmo 通道（编辑器可视化）
    gizmo_pass: gizmo_pass_mod.GizmoPass,
    /// 色调映射通道
    tonemap_pass: tonemap_pass_mod.TonemapPass,
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
            .bloom_pass = undefined,
            .fxaa_pass = undefined,
            .outline_pass = undefined,
            .gizmo_pass = undefined,
            .tonemap_pass = undefined,
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

        renderer.tonemap_pass = try tonemap_pass_mod.TonemapPass.init(&renderer.rhi);
        errdefer renderer.tonemap_pass.deinit(&renderer.rhi);

        renderer.skybox_pass = try skybox_pass_mod.SkyboxPass.init(&renderer.rhi);
        errdefer if (renderer.skybox_pass) |*pass| {
            pass.deinit(&renderer.rhi);
        };

        renderer.bloom_pass = try bloom_pass_mod.BloomPass.init(&renderer.rhi);
        errdefer renderer.bloom_pass.deinit(&renderer.rhi);

        renderer.fxaa_pass = try fxaa_pass_mod.FxaaPass.init(&renderer.rhi);
        errdefer renderer.fxaa_pass.deinit(&renderer.rhi);

        renderer.outline_pass = try outline_pass_mod.OutlinePass.init(&renderer.rhi);
        errdefer renderer.outline_pass.deinit(&renderer.rhi);

        renderer.gizmo_pass = try gizmo_pass_mod.GizmoPass.init(&renderer.rhi);
        renderer.graph.writeExports("dist/reports/render_graph.dot", "dist/reports/render_graph.json") catch |err| {
            std.log.warn("failed to write render graph exports: {}", .{err});
        };
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
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
        self.tonemap_pass.deinit(&self.rhi);
        if (self.skybox_pass) |*pass| {
            pass.deinit(&self.rhi);
        }
        self.bloom_pass.deinit(&self.rhi);
        self.fxaa_pass.deinit(&self.rhi);
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

    pub fn drawFrame(self: *Renderer, scene: *scene_mod.Scene, physics_state_opt: ?*physics_mod.PhysicsState) !FrameReport {
        try self.resolveSelectionReadbacks();

        const pass_stats = try self.graph.allocatePassStats(self.allocator);
        defer self.allocator.free(pass_stats);

        const snapshot = buildSceneSnapshot(scene);
        const result = blk: {
            const frame = try self.rhi.beginFrame();
            const clear = clearAndDepthForScene(snapshot, self.passCount());
            const has_swapchain = frame.swapchain_texture != null;

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
            const render_width = if (viewport_active) self.scene_viewport.width else frame.width;
            const render_height = if (viewport_active) self.scene_viewport.height else frame.height;
            var draw_stats = mesh_pass_mod.DrawStats{};

            if (can_render_scene) {
                if (!g_logged_viewport_backend) {
                    render_log.info(
                        "draw frame backend={s} viewport_active={} swapchain={} tonemap_ready={} skybox_ready={}",
                        .{
                            @tagName(self.rhi.api),
                            viewport_active,
                            has_swapchain,
                            self.tonemap_pass.isReady(),
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

                    const mat4 = @import("../math/mat4.zig");
                    const light_dir = vec3.normalize(main_light.direction);
                    const light_pos = vec3.scale(light_dir, -20.0);
                    const light_view = mat4.lookAt(light_pos, .{ 0.0, 0.0, 0.0 }, shadowViewUpVector(light_dir));
                    const light_proj = mat4.orthographic(40.0, 1.0, 0.1, 100.0);
                    break :blk_lsm mat4.mul(light_proj, light_view);
                };
                prepared_scene.light_space_matrix = light_space_matrix;
                prepared_scene.shadow_map = &self.shadow_map.depth_texture.?;
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

                const scene_color_target: rhi_mod.ColorTarget = if (viewport_active)
                    .{ .texture = self.scene_viewport.color().? }
                else
                    .swapchain;
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

                if (self.shadow_pass.isReady()) {
                    const shadow_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.shadowOnly(&self.shadow_map.depth_texture.?));
                    const shadow_start = std.time.nanoTimestamp();
                    const shadow_stats = self.shadow_pass.draw(&self.rhi, frame, shadow_render_pass, &prepared_scene, light_space_matrix);
                    self.graph.recordPassStat(pass_stats, .shadow_map, durationNs(shadow_start, std.time.nanoTimestamp()), shadow_stats.draw_calls, shadow_stats.triangles_drawn);
                    draw_stats.add(shadow_stats);
                    self.rhi.endRenderPass(shadow_render_pass);
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

                const scene_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.colorWithDepth(base_pass_target, clear.color, scene_depth_target));
                const depth_start = std.time.nanoTimestamp();
                const depth_stats = self.depth_prepass.draw(&self.rhi, frame, scene_pass, &prepared_scene);
                self.graph.recordPassStat(pass_stats, .depth_prepass, durationNs(depth_start, std.time.nanoTimestamp()), depth_stats.draw_calls, depth_stats.triangles_drawn);
                draw_stats.add(depth_stats);

                const opaque_start = std.time.nanoTimestamp();
                const opaque_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, .{
                    .render_mode = self.editor_viewport_state.render_mode,
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
                        .render_mode = previewRenderMode(self.editor_viewport_state.render_mode),
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
                    .render_mode = self.editor_viewport_state.render_mode,
                    .target = if (viewport_active) .hdr else .ldr,
                    .phase = .transparent_pass,
                });
                self.graph.recordPassStat(pass_stats, .transparent, durationNs(transparent_start, std.time.nanoTimestamp()), transparent_stats.draw_calls, transparent_stats.triangles_drawn);
                draw_stats.add(transparent_stats);

                if (has_prepared_preview_scene) {
                    const preview_transparent_start = std.time.nanoTimestamp();
                    const preview_transparent_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_preview_scene, .{
                        .render_mode = previewRenderMode(self.editor_viewport_state.render_mode),
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
                    const bloom_enabled = self.editor_viewport_state.bloom_enabled and self.bloom_pass.isReady() and self.scene_viewport.bloom() != null;
                    const fxaa_enabled = self.editor_viewport_state.fxaa_enabled and self.fxaa_pass.isReady() and self.scene_viewport.fxaa() != null;
                    if (bloom_enabled) {
                        try self.bloom_pass.syncTexture(&self.rhi, self.scene_viewport.hdrColor().?);
                        const bloom_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.bloom().? }));
                        const bloom_start = std.time.nanoTimestamp();
                        const bloom_stats = self.bloom_pass.draw(
                            &self.rhi,
                            frame,
                            bloom_render_pass,
                            self.editor_viewport_state.bloom_threshold,
                        );
                        self.graph.recordPassStat(pass_stats, .post_process, durationNs(bloom_start, std.time.nanoTimestamp()), bloom_stats.draw_calls, bloom_stats.triangles_drawn);
                        draw_stats.add(bloom_stats);
                        self.rhi.endRenderPass(bloom_render_pass);
                    }

                    if (self.tonemap_pass.isReady()) {
                        const bloom_input = if (bloom_enabled) self.scene_viewport.bloom().? else self.scene_viewport.hdrColor().?;
                        const lut_texture = self.tonemap_pass.lutTexture(self.editor_viewport_state.lut_preset) orelse return error.TextureNotFound;
                        const tonemap_target: rhi_mod.ColorTarget = if (fxaa_enabled)
                            .{ .texture = self.scene_viewport.fxaa().? }
                        else
                            scene_color_target;
                        try self.tonemap_pass.syncTextures(&self.rhi, self.scene_viewport.hdrColor().?, bloom_input, lut_texture);
                        const tonemap_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(tonemap_target));
                        self.tonemap_pass.draw(
                            &self.rhi,
                            frame,
                            tonemap_render_pass,
                            self.editor_viewport_state.exposure_enabled,
                            self.editor_viewport_state.exposure,
                            bloom_enabled,
                            self.editor_viewport_state.bloom_intensity,
                            self.editor_viewport_state.color_grading_enabled,
                            self.editor_viewport_state.color_grading_saturation,
                            self.editor_viewport_state.color_grading_contrast,
                            self.editor_viewport_state.color_grading_gamma,
                            self.editor_viewport_state.lut_enabled,
                            self.editor_viewport_state.lut_intensity,
                        );
                        self.rhi.endRenderPass(tonemap_render_pass);
                    }

                    if (fxaa_enabled) {
                        try self.fxaa_pass.syncTexture(&self.rhi, self.scene_viewport.fxaa().?);
                        const fxaa_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(scene_color_target));
                        const fxaa_start = std.time.nanoTimestamp();
                        const fxaa_stats = self.fxaa_pass.draw(&self.rhi, fxaa_render_pass);
                        self.graph.recordPassStat(pass_stats, .post_process, durationNs(fxaa_start, std.time.nanoTimestamp()), fxaa_stats.draw_calls, fxaa_stats.triangles_drawn);
                        draw_stats.add(fxaa_stats);
                        self.rhi.endRenderPass(fxaa_render_pass);
                    }
                }

                const selected_entities = self.selection_history.currentSelection();
                if (self.outline_pass.isReady() and self.id_pass.texture() != null and selected_entities.len > 0) {
                    try self.outline_pass.syncTexture(&self.rhi, self.id_pass.texture().?);
                    const outline_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(scene_color_target));
                    const outline_start = std.time.nanoTimestamp();
                    const outline_stats = self.outline_pass.draw(&self.rhi, frame, outline_pass, selected_entities);
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
            }

            const thumbnail_stats = try self.processMaterialThumbnailRequests(frame, scene);
            draw_stats.add(thumbnail_stats);

            if (has_swapchain) {
                imgui_mod.prepare(frame.command_buffer);
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
                imgui_mod.render(frame.command_buffer, ui_pass.raw);
                self.graph.recordPassStat(pass_stats, .ui_overlay, durationNs(ui_start, std.time.nanoTimestamp()), 0, 0);
                self.rhi.endRenderPass(ui_pass);
            }

            if (self.pending_selection_readbacks.items.len > 0) {
                if (can_render_scene and self.id_pass.texture() != null) {
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

            break :blk FrameReport{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .graph_resources = self.graph.resourceCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
                .draw_calls = draw_stats.draw_calls,
                .triangles_drawn = draw_stats.triangles_drawn,
            };
        };

        self.graph.writeFrameReport(
            self.allocator,
            "dist/reports/latest_frame_report.json",
            rhi_types.graphicsApiName(self.rhi.api),
            result.draw_calls,
            result.triangles_drawn,
            pass_stats,
        ) catch |err| {
            std.log.warn("failed to write frame report: {}", .{err});
        };
        return result;
    }

    pub fn downloadFinalFrameAlloc(self: *Renderer, allocator: std.mem.Allocator) ![]u8 {
        const texture = self.scene_viewport.color_texture orelse return error.TextureNotFound;
        const width = texture.desc.width;
        const height = texture.desc.height;
        const pixel_count = width * height;
        const byte_count = pixel_count * 4;

        var transfer_buffer = try self.rhi.createTransferBuffer(.{
            .size = byte_count,
            .upload = false,
        });
        defer self.rhi.releaseTransferBuffer(&transfer_buffer);

        const command_buffer = self.rhi.acquireCommandBuffer() orelse return error.CommandBufferAcquireFailed;
        const copy_pass = try self.rhi.beginCopyPass(.{
            .command_buffer = command_buffer,
            .swapchain_texture = null,
            .width = width,
            .height = height,
        });

        const sdl = @import("../platform/sdl.zig").c;
        const source = sdl.SDL_GPUTextureRegion{
            .texture = texture.raw,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        };
        const destination = sdl.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer_buffer.raw,
            .offset = 0,
            .pixels_per_row = width,
            .rows_per_layer = height,
        };
        sdl.SDL_DownloadFromGPUTexture(copy_pass.raw, &source, &destination);

        self.rhi.endCopyPass(copy_pass);
        if (!self.rhi.submitCommandBuffer(command_buffer)) return error.CommandBufferSubmitFailed;
        _ = self.rhi.waitForIdle();

        const rgba_data = try allocator.alloc(u8, byte_count);
        defer allocator.free(rgba_data);
        try self.rhi.readTransferBufferBytes(&transfer_buffer, rgba_data);

        // Convert RGBA to PPM (RGB)
        var ppm_data = try allocator.alloc(u8, 128 + pixel_count * 3);
        var fbs = std.io.fixedBufferStream(ppm_data);
        const writer = fbs.writer();
        try writer.print("P6\n{d} {d}\n255\n", .{ width, height });

        // Batch convert RGBA to RGB and write all at once
        const rgb_data = try allocator.alloc(u8, pixel_count * 3);
        defer allocator.free(rgb_data);
        var rgb_index: usize = 0;
        var rgba_index: usize = 0;
        while (rgba_index < rgba_data.len) : (rgba_index += 4) {
            rgb_data[rgb_index] = rgba_data[rgba_index];
            rgb_data[rgb_index + 1] = rgba_data[rgba_index + 1];
            rgb_data[rgb_index + 2] = rgba_data[rgba_index + 2];
            rgb_index += 3;
        }
        try writer.writeAll(rgb_data);
        return try allocator.dupe(u8, ppm_data[0..fbs.pos]);
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

fn resolveEnvironmentTextures(
    self: *Renderer,
    scene: *scene_mod.Scene,
    prepared_scene: *mesh_pass_mod.PreparedScene,
) !void {
    prepared_scene.environment_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.irradiance_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.prefiltered_env_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.brdf_lut = self.scene_cache.fallbackBrdfLut();

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
    ) catch return;

    var environment = environment_map_import_mod.loadIBLData(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch return;
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
        containsIgnoreCase(path, "ibl");
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
