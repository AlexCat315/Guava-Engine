#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaMetalRTContext GuavaMetalRTContext;

/// 三角形数据 — 与 Zig RtTriangle / Metal RTTriangle 完全对齐
typedef struct {
    float v0[3], v1[3], v2[3];
    float n0[3], n1[3], n2[3];
    float albedo[3];
    float emissive[3];
    float metallic;
    float roughness;
} GuavaRTTriangle;

/// 光追渲染参数 — 与 Zig RtParams / Metal RTParams 完全对齐
typedef struct {
    float inv_view_projection[16];
    float camera_origin[3];
    float _pad0;
    float light_direction[3];
    float sun_angular_radius;  /* 太阳角半径(弧度)，0=硬阴影 */
    uint32_t width;
    uint32_t height;
    uint32_t samples;
    uint32_t bounces;
    uint32_t mode;             /* 0 = path trace, 1 = shadow only */
    uint32_t shadow_samples;   /* shadow-only 每像素采样数 */
    uint32_t _pad2[2];
} GuavaRTParams;

/// 创建 Metal RT 上下文。返回 NULL 表示当前设备不支持 Metal RT。
GuavaMetalRTContext* guava_metal_rt_init(void);

/// 查询是否支持硬件光追。
bool guava_metal_rt_is_supported(GuavaMetalRTContext* ctx);

/// 从三角形数据构建加速结构 (BLAS)。场景变化时调用。
bool guava_metal_rt_build_accel(GuavaMetalRTContext* ctx,
                                const GuavaRTTriangle* triangles,
                                uint32_t triangle_count);

/// 执行光线追踪，将 BGRA8 像素写入 output_pixels。
/// output_size = width * height * 4。
bool guava_metal_rt_trace(GuavaMetalRTContext* ctx,
                          const GuavaRTParams* params,
                          uint8_t* output_pixels,
                          uint32_t output_size);

/// 销毁上下文，释放所有 Metal 资源。
void guava_metal_rt_destroy(GuavaMetalRTContext* ctx);

#ifdef __cplusplus
}
#endif
