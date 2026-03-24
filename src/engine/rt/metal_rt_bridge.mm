#import <Metal/Metal.h>
#include <cstring>
#include <cstdio>
#include "metal_rt_bridge.h"

// ---------------------------------------------------------------------------
// Metal Shading Language — 路径追踪 compute kernel (Metal RT)
// ---------------------------------------------------------------------------
static const char* kMetalRTShaderSource = R"METAL(
#include <metal_stdlib>
#include <metal_raytracing>

using namespace metal;
using namespace raytracing;

struct RTTriangle {
    packed_float3 v0, v1, v2;
    packed_float3 n0, n1, n2;
    packed_float2 uv0, uv1, uv2;
    packed_float3 albedo;
    packed_float3 emissive;
    float metallic;
    float roughness;
    float transmission;
    float ior;
    float thickness;
    int texture_index;
    uint _tri_pad;
};

struct RTTextureMeta {
    uint offset;  // byte offset in packed BGRA8 pixel buffer
    uint width;
    uint height;
    uint format;
};

struct RTParams {
    float4x4 inv_view_projection;
    packed_float3 camera_origin;
    float _pad0;
    packed_float3 light_direction;
    float sun_angular_radius;       // 太阳角半径（弧度），控制软阴影半影宽度
    uint2 dimensions;
    uint samples;
    uint bounces;
    uint mode;       // 0 = path trace, 1 = shadow only
    uint shadow_samples; // shadow-only 每像素采样数 (1=硬阴影, 4+=软阴影)
    uint output_is_half;
    int environment_texture_index;
    uint _pad2;
    packed_float4 exposure_params;
    packed_float4 color_grading_params;
    uint _pad3;
    uint _pad4;
    uint _pad5;
};

// ---- deterministic hash RNG (与 CPU 路径追踪保持一致) ----
static uint hash_u32(uint x) {
    x ^= x >> 17;
    x *= 0xed5ad4bbu;
    x ^= x >> 11;
    x *= 0xac4c1b51u;
    x ^= x >> 15;
    x *= 0x31848babu;
    x ^= x >> 14;
    return x;
}

static float hash_unit_float(uint seed) {
    return float(hash_u32(seed) & 0x00FFFFFFu) / 16777215.0f;
}

static float3 random_hemisphere(float3 normal, uint seed) {
    float3 jitter = normalize(float3(
        hash_unit_float(seed ^ 0x68bc21ebu) * 2.0f - 1.0f,
        hash_unit_float(seed ^ 0x02e5be93u) * 2.0f - 1.0f,
        hash_unit_float(seed ^ 0xa3d95fa1u) * 2.0f - 1.0f
    ));
    return normalize(normal + jitter);
}

// 在光方向周围的锥体内随机采样方向 (用于软阴影)
static float3 sample_cone(float3 dir, float cone_angle, uint seed) {
    if (cone_angle < 1e-6f) return dir;
    // 构建切线空间
    float3 up = (abs(dir.y) < 0.999f) ? float3(0,1,0) : float3(1,0,0);
    float3 T = normalize(cross(up, dir));
    float3 B = cross(dir, T);
    // 均匀分布采样锥体
    float u1 = hash_unit_float(seed ^ 0x3c84ef95u);
    float u2 = hash_unit_float(seed ^ 0x7e6b2f31u);
    float cos_max = cos(cone_angle);
    float cos_theta = 1.0f - u1 * (1.0f - cos_max);
    float sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    float phi = 2.0f * 3.14159265f * u2;
    return normalize(sin_theta * cos(phi) * T + sin_theta * sin(phi) * B + cos_theta * dir);
}

static float3 sample_sky(float3 dir) {
    float horizon = saturate(dir.y * 0.5f + 0.5f);
    return float3(0.12f + 0.42f * horizon,
                  0.18f + 0.48f * horizon,
                  0.24f + 0.58f * horizon);
}

static float3 reflect_vec(float3 incident, float3 normal) {
    return incident - 2.0f * dot(incident, normal) * normal;
}

static bool refract_vec(float3 incident, float3 normal, float eta, thread float3& out_dir) {
    float cos_i = clamp(-dot(normal, incident), -1.0f, 1.0f);
    float k = 1.0f - eta * eta * (1.0f - cos_i * cos_i);
    if (k < 0.0f) return false;
    out_dir = eta * incident + (eta * cos_i - sqrt(k)) * normal;
    return true;
}

constant uint TEXFMT_BGRA8_UNORM = 3u;
constant uint TEXFMT_BGRA8_UNORM_SRGB = 4u;
constant uint TEXFMT_RGBA16_FLOAT = 5u;
constant uint TEXFMT_RGBA32_FLOAT = 6u;

static float3 read_texel_texture_atlas(
    device const uchar* atlas,
    constant RTTextureMeta& tm,
    uint tx,
    uint ty
) {
    uint index = ty * tm.width + tx;
    uint base = tm.offset;
    if (tm.format == TEXFMT_RGBA32_FLOAT) {
        device const float* f32 = reinterpret_cast<device const float*>(atlas + base + index * 16u);
        return float3(f32[0], f32[1], f32[2]);
    }
    if (tm.format == TEXFMT_RGBA16_FLOAT) {
        device const half* f16 = reinterpret_cast<device const half*>(atlas + base + index * 8u);
        return float3(float(f16[0]), float(f16[1]), float(f16[2]));
    }
    const uint px_off = base + index * 4u;
    float byte0 = float(atlas[px_off + 0]) / 255.0f;
    float byte1 = float(atlas[px_off + 1]) / 255.0f;
    float byte2 = float(atlas[px_off + 2]) / 255.0f;
    if (tm.format == TEXFMT_BGRA8_UNORM || tm.format == TEXFMT_BGRA8_UNORM_SRGB) {
        // BGRA: byte0=B, byte1=G, byte2=R
        return float3(pow(byte2, 2.2f), pow(byte1, 2.2f), pow(byte0, 2.2f));
    }
    // RGBA: byte0=R, byte1=G, byte2=B
    return float3(pow(byte0, 2.2f), pow(byte1, 2.2f), pow(byte2, 2.2f));
}

// 从打包纹理图集中双线性采样 (BGRA8)
static float3 sample_texture_atlas(
    device const uchar* atlas,
    constant RTTextureMeta* meta,
    int tex_index,
    float u_in, float v_in
) {
    constant RTTextureMeta& tm = meta[tex_index];
    uint tw = tm.width;
    uint th = tm.height;

    // wrap UV to [0,1)
    float u = u_in - floor(u_in);
    float v = v_in - floor(v_in);
    if (u < 0.0f) u += 1.0f;
    if (v < 0.0f) v += 1.0f;

    float fx = u * float(tw) - 0.5f;
    float fy = v * float(th) - 0.5f;
    int x0 = int(floor(fx));
    int y0 = int(floor(fy));
    float frac_x = fx - floor(fx);
    float frac_y = fy - floor(fy);

    int iw = int(tw);
    int ih = int(th);
    uint x0u = uint(((x0 % iw) + iw) % iw);
    uint y0u = uint(((y0 % ih) + ih) % ih);
    uint x1u = uint((((x0 + 1) % iw) + iw) % iw);
    uint y1u = uint((((y0 + 1) % ih) + ih) % ih);

    float3 c00 = read_texel_texture_atlas(atlas, tm, x0u, y0u);
    float3 c10 = read_texel_texture_atlas(atlas, tm, x1u, y0u);
    float3 c01 = read_texel_texture_atlas(atlas, tm, x0u, y1u);
    float3 c11 = read_texel_texture_atlas(atlas, tm, x1u, y1u);

    return mix(mix(c00, c10, frac_x), mix(c01, c11, frac_x), frac_y);
}

static float3 sample_environment(
    device const uchar* atlas,
    constant RTTextureMeta* meta,
    int env_tex_index,
    float3 dir
) {
    if (env_tex_index >= 0) {
        float3 nd = normalize(dir);
        float u = atan2(nd.z, nd.x) / (2.0f * 3.14159265f) + 0.5f;
        float v = 0.5f - asin(clamp(nd.y, -1.0f, 1.0f)) / 3.14159265f;
        return sample_texture_atlas(atlas, meta, env_tex_index, u, v);
    }
    return sample_sky(dir);
}

kernel void raytrace_kernel(
    uint2                          tid        [[thread_position_in_grid]],
    constant RTParams&             params     [[buffer(0)]],
    device uchar*                  output     [[buffer(1)]],
    constant RTTriangle*           triangles  [[buffer(2)]],
    primitive_acceleration_structure accel     [[buffer(3)]],
    device const uchar*            tex_atlas  [[buffer(4)]],
    constant RTTextureMeta*        tex_meta   [[buffer(5)]]
) {
    if (tid.x >= params.dimensions.x || tid.y >= params.dimensions.y) return;

    float3 accumulated = float3(0.0f);
    uint pixel_seed = hash_u32(tid.x ^ (tid.y << 16) ^ 0x7f4a7c15u);

    for (uint s = 0; s < params.samples; s++) {
        uint sseed = pixel_seed ^ (s * 0x45d9f3bu);
        float jx = hash_unit_float(sseed ^ 0x18f0e149u) - 0.5f;
        float jy = hash_unit_float(sseed ^ 0x6c8e9cf5u) - 0.5f;
        float2 uv = (float2(tid) + 0.5f + float2(jx, jy)) / float2(params.dimensions);
        float ndc_x = uv.x * 2.0f - 1.0f;
        float ndc_y = 1.0f - uv.y * 2.0f;

        float4 wnear = params.inv_view_projection * float4(ndc_x, ndc_y, 0.0f, 1.0f);
        float4 wfar  = params.inv_view_projection * float4(ndc_x, ndc_y, 1.0f, 1.0f);
        float inv_wn = (abs(wnear.w) > 1e-6f) ? (1.0f / wnear.w) : 1.0f;
        float inv_wf = (abs(wfar.w)  > 1e-6f) ? (1.0f / wfar.w)  : 1.0f;
        float3 near_pos = wnear.xyz * inv_wn;
        float3 far_pos  = wfar.xyz  * inv_wf;
        float3 origin = float3(params.camera_origin);
        float3 direction = normalize(far_pos - near_pos);
        if (length(direction) <= 1e-4f) direction = normalize(far_pos - origin);

        // ---- multi-bounce path trace ----
        float3 throughput = float3(1.0f);
        float3 radiance   = float3(0.0f);
        intersector<triangle_data> inter;
        inter.accept_any_intersection(false);

        for (uint bounce = 0; bounce < params.bounces; bounce++) {
            ray r;
            r.origin       = origin;
            r.direction    = direction;
            r.min_distance = 0.001f;
            r.max_distance = 1e30f;

            auto hit = inter.intersect(r, accel);
            if (hit.type != intersection_type::triangle) {
                radiance += throughput * sample_environment(tex_atlas, tex_meta, params.environment_texture_index, direction);
                break;
            }

            uint pid = hit.primitive_id;
            RTTriangle tri = triangles[pid];
            float2 bary = hit.triangle_barycentric_coord;
            float w0 = 1.0f - bary.x - bary.y;
            float3 normal = normalize(
                float3(tri.n0) * w0 + float3(tri.n1) * bary.x + float3(tri.n2) * bary.y);
            bool front_face = dot(direction, normal) < 0.0f;
            float3 shade_n = front_face ? normal : -normal;
            float3 hit_pos = origin + direction * hit.distance;

            // UV 插值 + 纹理采样
            float2 hit_uv = float2(tri.uv0) * w0 + float2(tri.uv1) * bary.x + float2(tri.uv2) * bary.y;
            float3 alb;
            if (tri.texture_index >= 0) {
                float3 tex_color = sample_texture_atlas(tex_atlas, tex_meta, tri.texture_index, hit_uv.x, hit_uv.y);
                alb = tex_color * float3(tri.albedo);
            } else {
                alb = float3(tri.albedo);
            }

            float3 emis  = float3(tri.emissive);
            float  met   = tri.metallic;
            float  rough = tri.roughness;
            float  transmission = clamp(tri.transmission, 0.0f, 0.96f);
            float  thickness = max(tri.thickness, 0.0f);

            // ---- shadow-only mode: primary ray + N shadow rays → soft visibility ----
            if (params.mode == 1) {
                float3 L = normalize(float3(params.light_direction));
                uint n_shadow = max(1u, params.shadow_samples);
                float total_vis = 0.0f;
                for (uint si = 0; si < n_shadow; si++) {
                    uint sseed2 = pixel_seed ^ (si * 0x9e3779b9u) ^ 0xa1b2c3d4u;
                    float3 jittered_L = sample_cone(L, params.sun_angular_radius, sseed2);
                    ray shadow_ray;
                    shadow_ray.origin       = hit_pos + normal * 0.002f;
                    shadow_ray.direction    = jittered_L;
                    shadow_ray.min_distance = 0.001f;
                    shadow_ray.max_distance = 1e30f;
                    intersector<triangle_data> shadow_inter;
                    shadow_inter.accept_any_intersection(true);
                    auto shadow_hit = shadow_inter.intersect(shadow_ray, accel);
                    total_vis += (shadow_hit.type == intersection_type::triangle) ? 0.0f : 1.0f;
                }
                accumulated += float3(total_vis / float(n_shadow));
                break; // 仅需第一次命中
            }

            // emissive
            if ((emis.x + emis.y + emis.z) > 0.001f) radiance += throughput * emis;

            // direct lighting — keep this cheap, reflective look mainly comes
            // from bounce path so Metal RT and CPU PT stay visually aligned.
            float3 L = float3(params.light_direction);
            float shadow_vis = 1.0f;
            {
                ray shadow_ray;
                shadow_ray.origin       = hit_pos + normal * 0.002f;
                shadow_ray.direction    = L;
                shadow_ray.min_distance = 0.001f;
                shadow_ray.max_distance = 1e30f;
                intersector<triangle_data> shadow_inter;
                shadow_inter.accept_any_intersection(true);
                auto shadow_hit = shadow_inter.intersect(shadow_ray, accel);
                if (shadow_hit.type == intersection_type::triangle) shadow_vis = 0.0f;
            }
            float NdotL = saturate(dot(shade_n, L));
            float3 diffuse = alb * NdotL * (1.0f - met);
            float3 dielectric_f0 = float3(0.04f);
            float3 specular_tint = mix(dielectric_f0, alb, met);
            float3 H = normalize(L - direction);
            float NdotH = saturate(dot(shade_n, H));
            float sp = max(8.0f, 10.0f + (1.0f - rough) * 120.0f);
            float spec_val = pow(NdotH, sp) * (0.1f + 0.9f * (1.0f - rough));
            float3 spec_c = specular_tint * spec_val;
            float surface_lighting_weight = 1.0f - transmission * 0.85f;
            float3 direct = (diffuse + spec_c * NdotL) * shadow_vis * surface_lighting_weight;
            float3 ambient = alb * (0.03f + 0.04f * (1.0f - met)) * surface_lighting_weight;
            radiance += throughput * (direct + ambient);

            // bounce selection: transmission/reflection/diffuse
            uint bseed = sseed ^ (bounce * 0x9e3779b9u);
            float specular_chance = clamp(0.08f + met * 0.84f + (1.0f - rough) * 0.06f, 0.05f, 0.97f);
            float transmission_chance = clamp(transmission * (1.0f - met), 0.0f, 0.92f);
            float3 reflected = normalize(reflect_vec(direction, shade_n));
            float3 glossy = normalize(mix(reflected, random_hemisphere(reflected, bseed ^ 0x51c8e12du), rough * rough));
            float3 diffuse_dir = random_hemisphere(shade_n, bseed ^ 0xa241b3c1u);
            bool choose_specular = hash_unit_float(bseed ^ 0x6b84221fu) < specular_chance;
            bool choose_transmission = transmission_chance > 0.0f && hash_unit_float(bseed ^ 0xb5297a4du) < transmission_chance;

            if (choose_transmission) {
                float eta = front_face ? (1.0f / max(tri.ior, 1.01f)) : max(tri.ior, 1.01f);
                float3 refr_dir;
                if (refract_vec(direction, shade_n, eta, refr_dir)) {
                    direction = normalize(refr_dir);
                } else {
                    direction = reflected;
                }
                float3 transmission_tint = mix(float3(1.0f), alb, 0.2f);
                if (thickness > 1e-4f) {
                    float ndot = max(abs(dot(direction, shade_n)), 0.2f);
                    float optical_distance = thickness / ndot;
                    float3 sigma_a = max(float3(0.0f), 1.0f - alb) * 2.2f;
                    throughput *= exp(-sigma_a * optical_distance);
                }
                throughput *= transmission_tint * (0.96f / max(transmission_chance, 0.05f));
                origin = hit_pos + direction * 0.002f;
            } else if (choose_specular) {
                direction = (dot(glossy, shade_n) > 0.0f) ? glossy : reflected;
                throughput *= specular_tint * (0.92f / specular_chance);
                origin = hit_pos + shade_n * 0.002f;
            } else {
                direction = diffuse_dir;
                throughput *= (alb * (1.0f - met)) * (0.85f / max(1.0f - specular_chance, 0.05f));
                origin = hit_pos + shade_n * 0.002f;
            }

            if (length(throughput) < 0.02f) break;
        }
        accumulated += radiance;
    }
    accumulated /= float(params.samples);

    uint idx = tid.y * params.dimensions.x + tid.x;
    if (params.mode == 1) {
        // shadow-only: output grayscale visibility (no gamma, linear)
        uchar v = uchar(saturate(accumulated.x) * 255.0f);
        uint base = idx * 4;
        output[base + 0] = v;
        output[base + 1] = v;
        output[base + 2] = v;
        output[base + 3] = 255;
    } else if (params.output_is_half != 0u) {
        device half* output_half = (device half*)output;
        uint hbase = idx * 4;
        output_half[hbase + 0] = half(clamp(accumulated.x, -65504.0f, 65504.0f));
        output_half[hbase + 1] = half(clamp(accumulated.y, -65504.0f, 65504.0f));
        output_half[hbase + 2] = half(clamp(accumulated.z, -65504.0f, 65504.0f));
        output_half[hbase + 3] = half(1.0f);
    } else {
        float3 linear = saturate(accumulated);
        uint base = idx * 4;
        output[base + 0] = uchar(linear.z * 255.0f);  // B
        output[base + 1] = uchar(linear.y * 255.0f);  // G
        output[base + 2] = uchar(linear.x * 255.0f);  // R
        output[base + 3] = 255;
    }
}
)METAL";

// ---------------------------------------------------------------------------
// GuavaMetalRTContext — 持有所有 Metal 资源
// ---------------------------------------------------------------------------
struct GuavaMetalRTContext {
    id<MTLDevice>                   device;
    id<MTLCommandQueue>             commandQueue;
    id<MTLComputePipelineState>     pipeline;
    id<MTLAccelerationStructure>    accel;
    id<MTLBuffer>                   vertexPositionBuffer;
    id<MTLBuffer>                   triangleDataBuffer;
    id<MTLBuffer>                   outputBuffer;
    id<MTLBuffer>                   paramsBuffer;
    id<MTLBuffer>                   textureAtlasBuffer;
    id<MTLBuffer>                   textureMetaBuffer;
    uint32_t                        triangleCount;
    uint32_t                        outputWidth;
    uint32_t                        outputHeight;
    uint32_t                        outputBytesPerPixel;
    uint32_t                        textureCount;
    bool                            supported;
    bool                            accelBuilt;
};

// ---------------------------------------------------------------------------
// guava_metal_rt_init
// ---------------------------------------------------------------------------
extern "C" GuavaMetalRTContext* guava_metal_rt_init(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[Metal RT] MTLCreateSystemDefaultDevice failed\n");
            return nullptr;
        }

        if (![device supportsRaytracing]) {
            fprintf(stderr, "[Metal RT] Device does not support ray tracing\n");
            return nullptr;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!queue) {
            fprintf(stderr, "[Metal RT] Failed to create command queue\n");
            return nullptr;
        }

        // Compile MSL shader
        NSError* error = nil;
        MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;

        NSString* source = [NSString stringWithUTF8String:kMetalRTShaderSource];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:opts error:&error];
        if (!library) {
            fprintf(stderr, "[Metal RT] Shader compile failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nullptr;
        }

        id<MTLFunction> kernelFunc = [library newFunctionWithName:@"raytrace_kernel"];
        if (!kernelFunc) {
            fprintf(stderr, "[Metal RT] raytrace_kernel function not found\n");
            return nullptr;
        }

        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:kernelFunc error:&error];
        if (!pipeline) {
            fprintf(stderr, "[Metal RT] Pipeline creation failed: %s\n",
                    [[error localizedDescription] UTF8String]);
            return nullptr;
        }

        auto* ctx         = new GuavaMetalRTContext();
        ctx->device        = device;
        ctx->commandQueue  = queue;
        ctx->pipeline      = pipeline;
        ctx->accel         = nil;
        ctx->vertexPositionBuffer = nil;
        ctx->triangleDataBuffer   = nil;
        ctx->outputBuffer  = nil;
        ctx->paramsBuffer  = nil;
        ctx->textureAtlasBuffer = nil;
        ctx->textureMetaBuffer  = nil;
        ctx->triangleCount = 0;
        ctx->outputWidth   = 0;
        ctx->outputHeight  = 0;
        ctx->outputBytesPerPixel = 0;
        ctx->textureCount  = 0;
        ctx->supported     = true;
        ctx->accelBuilt    = false;

        fprintf(stderr, "[Metal RT] Initialized — device: %s\n",
                [[device name] UTF8String]);
        return ctx;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_is_supported
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_is_supported(GuavaMetalRTContext* ctx) {
    return ctx && ctx->supported;
}

// ---------------------------------------------------------------------------
// guava_metal_rt_build_accel
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_build_accel(GuavaMetalRTContext* ctx,
                                           const GuavaRTTriangle* triangles,
                                           uint32_t triangle_count) {
    if (!ctx || !ctx->supported || triangle_count == 0) return false;

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        // ---- 1. 提取顶点位置到紧凑 buffer ----
        const uint32_t vertex_count  = triangle_count * 3;
        const size_t   pos_buf_size  = (size_t)vertex_count * sizeof(float) * 3;
        id<MTLBuffer>  posBuf = [dev newBufferWithLength:pos_buf_size
                                                 options:MTLResourceStorageModeShared];
        if (!posBuf) return false;

        float* dst = (float*)[posBuf contents];
        for (uint32_t i = 0; i < triangle_count; i++) {
            memcpy(&dst[i * 9 + 0], triangles[i].v0, 12);
            memcpy(&dst[i * 9 + 3], triangles[i].v1, 12);
            memcpy(&dst[i * 9 + 6], triangles[i].v2, 12);
        }

        // ---- 2. 三角形材质 buffer（着色用） ----
        const size_t tri_buf_size = (size_t)triangle_count * sizeof(GuavaRTTriangle);
        id<MTLBuffer> triDataBuf = [dev newBufferWithBytes:triangles
                                                    length:tri_buf_size
                                                   options:MTLResourceStorageModeShared];
        if (!triDataBuf) return false;

        // ---- 3. 加速结构描述 ----
        MTLAccelerationStructureTriangleGeometryDescriptor* geomDesc =
            [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
        geomDesc.vertexBuffer       = posBuf;
        geomDesc.vertexBufferOffset = 0;
        geomDesc.vertexStride       = sizeof(float) * 3;
        geomDesc.triangleCount      = triangle_count;

        MTLPrimitiveAccelerationStructureDescriptor* asDesc =
            [MTLPrimitiveAccelerationStructureDescriptor descriptor];
        asDesc.geometryDescriptors = @[ geomDesc ];

        MTLAccelerationStructureSizes sizes =
            [dev accelerationStructureSizesWithDescriptor:asDesc];

        id<MTLAccelerationStructure> accelStruct =
            [dev newAccelerationStructureWithSize:sizes.accelerationStructureSize];
        if (!accelStruct) return false;

        id<MTLBuffer> scratch = [dev newBufferWithLength:sizes.buildScratchBufferSize
                                                 options:MTLResourceStorageModePrivate];
        if (!scratch) return false;

        // ---- 4. 构建 ----
        id<MTLCommandBuffer> cmdBuf = [ctx->commandQueue commandBuffer];
        id<MTLAccelerationStructureCommandEncoder> enc =
            [cmdBuf accelerationStructureCommandEncoder];
        [enc buildAccelerationStructure:accelStruct
                             descriptor:asDesc
                          scratchBuffer:scratch
                    scratchBufferOffset:0];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            fprintf(stderr, "[Metal RT] AS build failed: %s\n",
                    [[cmdBuf.error localizedDescription] UTF8String]);
            return false;
        }

        // ---- 5. 保存到 ctx ----
        ctx->accel                = accelStruct;
        ctx->vertexPositionBuffer = posBuf;
        ctx->triangleDataBuffer   = triDataBuf;
        ctx->triangleCount        = triangle_count;
        ctx->accelBuilt           = true;
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_upload_textures
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_upload_textures(GuavaMetalRTContext* ctx,
                                               const uint8_t* pixel_data,
                                               uint32_t pixel_data_size,
                                               const GuavaRTTextureMeta* meta,
                                               uint32_t texture_count) {
    if (!ctx || !ctx->supported) return false;
    if (texture_count == 0 || !pixel_data || pixel_data_size == 0) {
        ctx->textureAtlasBuffer = nil;
        ctx->textureMetaBuffer  = nil;
        ctx->textureCount       = 0;
        return true;
    }

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        ctx->textureAtlasBuffer = [dev newBufferWithBytes:pixel_data
                                                   length:pixel_data_size
                                                  options:MTLResourceStorageModeShared];
        if (!ctx->textureAtlasBuffer) return false;

        ctx->textureMetaBuffer = [dev newBufferWithBytes:meta
                                                  length:(size_t)texture_count * sizeof(GuavaRTTextureMeta)
                                                 options:MTLResourceStorageModeShared];
        if (!ctx->textureMetaBuffer) return false;

        ctx->textureCount = texture_count;
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_trace
// ---------------------------------------------------------------------------
extern "C" bool guava_metal_rt_trace(GuavaMetalRTContext* ctx,
                                     const GuavaRTParams* params,
                                     uint8_t* output_pixels,
                                     uint32_t output_size) {
    if (!ctx || !ctx->accelBuilt || !params || !output_pixels) return false;

    @autoreleasepool {
        const uint32_t w = params->width;
        const uint32_t h = params->height;
        const uint32_t bytes_per_pixel = (params->mode == 1) ? 4 : ((params->output_is_half != 0) ? 8 : 4);
        const uint32_t needed = w * h * bytes_per_pixel;
        if (output_size < needed) return false;

        id<MTLDevice> dev = ctx->device;

        // ---- output buffer ----
        if (!ctx->outputBuffer || ctx->outputWidth != w || ctx->outputHeight != h || ctx->outputBytesPerPixel != bytes_per_pixel) {
            ctx->outputBuffer = [dev newBufferWithLength:needed
                                                 options:MTLResourceStorageModeShared];
            if (!ctx->outputBuffer) return false;
            ctx->outputWidth  = w;
            ctx->outputHeight = h;
            ctx->outputBytesPerPixel = bytes_per_pixel;
        }

        // ---- params buffer ----
        if (!ctx->paramsBuffer) {
            ctx->paramsBuffer = [dev newBufferWithLength:sizeof(GuavaRTParams)
                                                 options:MTLResourceStorageModeShared];
            if (!ctx->paramsBuffer) return false;
        }
        memcpy([ctx->paramsBuffer contents], params, sizeof(GuavaRTParams));

        // ---- dispatch ----
        id<MTLCommandBuffer> cmdBuf = [ctx->commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

        [enc setComputePipelineState:ctx->pipeline];
        [enc setBuffer:ctx->paramsBuffer       offset:0 atIndex:0];
        [enc setBuffer:ctx->outputBuffer       offset:0 atIndex:1];
        [enc setBuffer:ctx->triangleDataBuffer offset:0 atIndex:2];
        [enc setAccelerationStructure:ctx->accel atBufferIndex:3];

        // 纹理图集 + 元数据 (可选 — 无纹理时绑定空 1 字节缓冲)
        if (ctx->textureAtlasBuffer && ctx->textureMetaBuffer && ctx->textureCount > 0) {
            [enc setBuffer:ctx->textureAtlasBuffer offset:0 atIndex:4];
            [enc setBuffer:ctx->textureMetaBuffer  offset:0 atIndex:5];
        } else {
            // 绑定空缓冲避免 Metal 验证错误
            static id<MTLBuffer> emptyBuf = nil;
            if (!emptyBuf) {
                emptyBuf = [ctx->device newBufferWithLength:16
                                                    options:MTLResourceStorageModeShared];
            }
            [enc setBuffer:emptyBuf offset:0 atIndex:4];
            [enc setBuffer:emptyBuf offset:0 atIndex:5];
        }

        // Metal 要求 compute encoder 声明加速结构引用的资源
        [enc useResource:ctx->vertexPositionBuffer usage:MTLResourceUsageRead];

        MTLSize gridSize  = MTLSizeMake(w, h, 1);
        MTLSize groupSize = MTLSizeMake(8, 8, 1);
        [enc dispatchThreads:gridSize threadsPerThreadgroup:groupSize];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            fprintf(stderr, "[Metal RT] Trace failed: %s\n",
                    [[cmdBuf.error localizedDescription] UTF8String]);
            return false;
        }

        // ---- readback ----
        memcpy(output_pixels, [ctx->outputBuffer contents], needed);
        return true;
    }
}

// ---------------------------------------------------------------------------
// guava_metal_rt_destroy
// ---------------------------------------------------------------------------
extern "C" void guava_metal_rt_destroy(GuavaMetalRTContext* ctx) {
    if (!ctx) return;
    @autoreleasepool {
        ctx->accel                = nil;
        ctx->vertexPositionBuffer = nil;
        ctx->triangleDataBuffer   = nil;
        ctx->textureAtlasBuffer   = nil;
        ctx->textureMetaBuffer    = nil;
        ctx->outputBuffer         = nil;
        ctx->paramsBuffer         = nil;
        ctx->pipeline             = nil;
        ctx->commandQueue         = nil;
        ctx->device               = nil;
        delete ctx;
    }
}
