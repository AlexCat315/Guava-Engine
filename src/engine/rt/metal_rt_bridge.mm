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
    packed_float3 albedo;
    packed_float3 emissive;
    float metallic;
    float roughness;
};

struct RTParams {
    float4x4 inv_view_projection;
    packed_float3 camera_origin;
    float _pad0;
    packed_float3 light_direction;
    float _pad1;
    uint2 dimensions;
    uint samples;
    uint bounces;
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

static float3 sample_sky(float3 dir) {
    float horizon = saturate(dir.y * 0.5f + 0.5f);
    return float3(0.12f + 0.42f * horizon,
                  0.18f + 0.48f * horizon,
                  0.24f + 0.58f * horizon);
}

kernel void raytrace_kernel(
    uint2                          tid        [[thread_position_in_grid]],
    constant RTParams&             params     [[buffer(0)]],
    device uchar4*                 output     [[buffer(1)]],
    constant RTTriangle*           triangles  [[buffer(2)]],
    primitive_acceleration_structure accel     [[buffer(3)]]
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
                radiance += throughput * sample_sky(direction);
                break;
            }

            uint pid = hit.primitive_id;
            RTTriangle tri = triangles[pid];
            float2 bary = hit.triangle_barycentric_coord;
            float w0 = 1.0f - bary.x - bary.y;
            float3 normal = normalize(
                float3(tri.n0) * w0 + float3(tri.n1) * bary.x + float3(tri.n2) * bary.y);
            float3 hit_pos = origin + direction * hit.distance;
            float3 alb   = float3(tri.albedo);
            float3 emis  = float3(tri.emissive);
            float  met   = tri.metallic;
            float  rough = tri.roughness;

            // emissive
            if ((emis.x + emis.y + emis.z) > 0.001f) radiance += throughput * emis;

            // direct lighting
            float3 L = float3(params.light_direction);
            float NdotL = saturate(dot(normal, L));
            float3 diffuse = alb * NdotL * (1.0f - met);
            float3 H = normalize(L - direction);
            float NdotH = saturate(dot(normal, H));
            float sp = max(2.0f, 2.0f / (rough * rough + 0.001f));
            float spec_val = pow(NdotH, sp) * (1.0f - rough) * 0.4f;
            float3 spec_c = float3(
                alb.x * met + (1.0f - met) * spec_val,
                alb.y * met + (1.0f - met) * spec_val,
                alb.z * met + (1.0f - met) * spec_val);
            float3 direct = diffuse + spec_c * NdotL;
            float3 ambient = alb * 0.08f;
            radiance += throughput * (direct + ambient);

            // bounce
            throughput *= alb * 0.5f;
            if (length(throughput) < 0.02f) break;
            uint bseed = sseed ^ (bounce * 0x9e3779b9u);
            direction = random_hemisphere(normal, bseed);
            origin    = hit_pos + normal * 0.002f;
        }
        accumulated += radiance;
    }
    accumulated /= float(params.samples);

    // linear → sRGB, BGRA output
    float3 srgb = pow(saturate(accumulated), 1.0f / 2.2f);
    uint idx = tid.y * params.dimensions.x + tid.x;
    output[idx] = uchar4(
        uchar(srgb.z * 255.0f),  // B
        uchar(srgb.y * 255.0f),  // G
        uchar(srgb.x * 255.0f),  // R
        255);                      // A
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
    uint32_t                        triangleCount;
    uint32_t                        outputWidth;
    uint32_t                        outputHeight;
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
        ctx->triangleCount = 0;
        ctx->outputWidth   = 0;
        ctx->outputHeight  = 0;
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
        const uint32_t needed = w * h * 4;
        if (output_size < needed) return false;

        id<MTLDevice> dev = ctx->device;

        // ---- output buffer ----
        if (!ctx->outputBuffer || ctx->outputWidth != w || ctx->outputHeight != h) {
            ctx->outputBuffer = [dev newBufferWithLength:needed
                                                 options:MTLResourceStorageModeShared];
            if (!ctx->outputBuffer) return false;
            ctx->outputWidth  = w;
            ctx->outputHeight = h;
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
        ctx->outputBuffer         = nil;
        ctx->paramsBuffer         = nil;
        ctx->pipeline             = nil;
        ctx->commandQueue         = nil;
        ctx->device               = nil;
        delete ctx;
    }
}
