#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <vector>
#include "metal_rhi_bridge.h"

// ---------------------------------------------------------------------------
// Metal RHI Bridge — real Metal API implementation
// ---------------------------------------------------------------------------

// Per-set binding data stored after registration
struct BindingSetData {
    std::vector<GuavaMetalBindingEntry> entries;
};

// Main bridge context — owns all Metal objects
struct GuavaMetalRhiContext {
    id<MTLDevice>       device;
    id<MTLCommandQueue> graphics_queue;
    id<MTLCommandQueue> compute_queue;

    // Swapchain state
    CAMetalLayer*        metal_layer    = nil;
    id<CAMetalDrawable>  current_drawable = nil;
    uint32_t             swapchain_texture_id = 0; // texture ID for current drawable

    uint32_t next_buffer_id   = 1;
    uint32_t next_texture_id  = 1;
    uint32_t next_sampler_id  = 1;
    uint32_t next_shader_id   = 1;
    uint32_t next_gfx_pipe_id = 1;
    uint32_t next_cmp_pipe_id = 1;

    std::unordered_map<uint32_t, id<MTLBuffer>>               buffers;
    std::unordered_map<uint32_t, id<MTLTexture>>              textures;
    std::unordered_map<uint32_t, id<MTLSamplerState>>         samplers;
    std::unordered_map<uint32_t, id<MTLFunction>>             shader_functions;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>>  gfx_pipelines;
    std::unordered_map<uint32_t, id<MTLComputePipelineState>> cmp_pipelines;
    std::unordered_map<uint32_t, BindingSetData>              binding_sets;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>>    depth_stencil_states;

    // Shader libraries cached per shader module (for Metal library compilation)
    std::unordered_map<uint32_t, id<MTLLibrary>>              shader_libraries;
};

// ---------------------------------------------------------------------------
// Helper: map RHI TextureFormat ordinal → MTLPixelFormat
// ---------------------------------------------------------------------------
static MTLPixelFormat mapPixelFormat(uint32_t fmt) {
    // Must match types.zig TextureFormat enum ordering:
    // unknown=0, r8_unorm=1, rgba8_unorm=2, bgra8_unorm=3,
    // bgra8_unorm_srgb=4, rgba16_float=5, rgba32_float=6,
    // d24_unorm=7, d24_unorm_s8_uint=8, d32_float=9
    switch (fmt) {
        case 1:  return MTLPixelFormatR8Unorm;
        case 2:  return MTLPixelFormatRGBA8Unorm;
        case 3:  return MTLPixelFormatBGRA8Unorm;
        case 4:  return MTLPixelFormatBGRA8Unorm_sRGB;
        case 5:  return MTLPixelFormatRGBA16Float;
        case 6:  return MTLPixelFormatRGBA32Float;
        case 7:  return MTLPixelFormatDepth24Unorm_Stencil8; // closest on macOS
        case 8:  return MTLPixelFormatDepth24Unorm_Stencil8;
        case 9:  return MTLPixelFormatDepth32Float;
        default: return MTLPixelFormatRGBA8Unorm;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI SamplerAddressMode ordinal → MTLSamplerAddressMode
// ---------------------------------------------------------------------------
static MTLSamplerAddressMode mapAddressMode(uint32_t mode) {
    switch (mode) {
        case 0:  return MTLSamplerAddressModeRepeat;
        case 1:  return MTLSamplerAddressModeMirrorRepeat;
        case 2:  return MTLSamplerAddressModeClampToEdge;
        default: return MTLSamplerAddressModeRepeat;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI PrimitiveType ordinal → MTLPrimitiveType
// ---------------------------------------------------------------------------
static MTLPrimitiveType mapPrimitive(uint32_t prim) {
    switch (prim) {
        case 0:  return MTLPrimitiveTypeTriangle;
        case 1:  return MTLPrimitiveTypeTriangleStrip;
        case 2:  return MTLPrimitiveTypeLine;
        case 3:  return MTLPrimitiveTypeLineStrip;
        case 4:  return MTLPrimitiveTypePoint;
        default: return MTLPrimitiveTypeTriangle;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI TextureFormat ordinal → bytes per pixel
// ---------------------------------------------------------------------------
static uint32_t bytesPerPixel(uint32_t fmt) {
    switch (fmt) {
        case 1:  return 1;   // r8_unorm
        case 2:  return 4;   // rgba8_unorm
        case 3:  return 4;   // bgra8_unorm
        case 4:  return 4;   // bgra8_unorm_srgb
        case 5:  return 8;   // rgba16_float
        case 6:  return 16;  // rgba32_float
        case 9:  return 4;   // d32_float
        default: return 4;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI CompareOp ordinal → MTLCompareFunction
// ---------------------------------------------------------------------------
static MTLCompareFunction mapCompareOp(uint32_t op) {
    switch (op) {
        case 0:  return MTLCompareFunctionNever;
        case 1:  return MTLCompareFunctionLess;
        case 2:  return MTLCompareFunctionEqual;
        case 3:  return MTLCompareFunctionLessEqual;
        case 4:  return MTLCompareFunctionGreater;
        case 5:  return MTLCompareFunctionNotEqual;
        case 6:  return MTLCompareFunctionGreaterEqual;
        case 7:  return MTLCompareFunctionAlways;
        default: return MTLCompareFunctionAlways;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI VertexElementFormat ordinal → MTLVertexFormat
// ---------------------------------------------------------------------------
static MTLVertexFormat mapVertexFormat(uint32_t fmt) {
    switch (fmt) {
        case 0:  return MTLVertexFormatFloat2;
        case 1:  return MTLVertexFormatFloat3;
        case 2:  return MTLVertexFormatFloat4;
        default: return MTLVertexFormatFloat3;
    }
}

// Vertex buffer base index in Metal argument table (must match submit decoder)
static constexpr uint32_t kVertexBufferBaseIndex = 30;

// ── Command buffer opcode constants (must match command_buffer.zig) ────────
enum RhiOpCode : uint8_t {
    OP_BEGIN_RENDER_PASS  = 0,
    OP_END_RENDER_PASS    = 1,
    OP_BEGIN_COMPUTE_PASS = 2,
    OP_END_COMPUTE_PASS   = 3,
    OP_BEGIN_COPY_PASS    = 4,
    OP_END_COPY_PASS      = 5,
    OP_SET_BINDING_SET    = 6,
    OP_SET_VERTEX_BUFFER  = 7,
    OP_SET_INDEX_BUFFER   = 8,
    OP_SET_PIPELINE       = 9,
    OP_DRAW_INDEXED       = 10,
    OP_DRAW_INDIRECT      = 11,
    OP_DISPATCH           = 12,
    OP_DISPATCH_INDIRECT  = 13,
    OP_PIPELINE_BARRIER   = 14,
};

// Packed command structs (must match command_buffer.zig extern struct layout)
#pragma pack(push, 1)
struct CmdBeginRenderPass  { uint32_t color_target_id; uint32_t depth_target_id; uint32_t clear_mask; };
struct CmdBeginComputePass { uint32_t reserved; };
struct CmdBeginCopyPass    { uint32_t reserved; };
struct CmdSetBindingSet    { uint32_t slot; uint32_t set_id; };
struct CmdSetVertexBuffer  { uint32_t slot; uint32_t buffer_id; uint64_t offset; };
struct CmdSetIndexBuffer   { uint32_t buffer_id; uint64_t offset; uint32_t format; };
struct CmdSetPipeline      { uint32_t pipeline_id; };
struct CmdDrawIndexed      { uint32_t index_count; uint32_t instance_count; uint32_t first_index; int32_t vertex_offset; uint32_t first_instance; };
struct CmdDrawIndirect     { uint32_t buffer_id; uint64_t offset; uint32_t draw_count; };
struct CmdDispatch         { uint32_t x; uint32_t y; uint32_t z; };
struct CmdDispatchIndirect { uint32_t buffer_id; uint64_t offset; };
struct CmdPipelineBarrier  { uint32_t resource_id; uint32_t src_state_bits; uint32_t dst_state_bits; uint8_t src_queue; uint8_t dst_queue; };
#pragma pack(pop)

// Max entries per binding set slot in the Metal argument table
static constexpr uint32_t kEntriesPerSlot = 8;

// ===================================================================
// Public C API
// ===================================================================

void* guava_metal_rhi_init(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[GuavaMetal] MTLCreateSystemDefaultDevice failed\n");
            return nullptr;
        }

        auto* ctx = new GuavaMetalRhiContext();
        ctx->device = device;
        ctx->graphics_queue = [device newCommandQueue];
        ctx->compute_queue  = [device newCommandQueue];

        fprintf(stderr, "[GuavaMetal] RHI init — device: %s\n",
                [[device name] UTF8String]);
        return ctx;
    }
}

void guava_metal_rhi_destroy(void* raw) {
    if (!raw) return;
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        // ARC handles Metal object release
        ctx->buffers.clear();
        ctx->textures.clear();
        ctx->samplers.clear();
        ctx->shader_functions.clear();
        ctx->shader_libraries.clear();
        ctx->gfx_pipelines.clear();
        ctx->cmp_pipelines.clear();
        ctx->binding_sets.clear();
        ctx->depth_stencil_states.clear();
        ctx->current_drawable = nil;
        ctx->metal_layer = nil;
        delete ctx;
    }
}

// ---------------------------------------------------------------------------
// Swapchain layer configuration
// ---------------------------------------------------------------------------

void guava_metal_rhi_set_layer(void* raw, void* ca_metal_layer) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
    ctx->metal_layer.device = ctx->device;
    ctx->metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    ctx->metal_layer.framebufferOnly = YES;
    fprintf(stderr, "[GuavaMetal] CAMetalLayer configured — size: %.0fx%.0f\n",
            ctx->metal_layer.drawableSize.width,
            ctx->metal_layer.drawableSize.height);
}

// ---------------------------------------------------------------------------
// Resource creation
// ---------------------------------------------------------------------------

uint32_t guava_metal_rhi_create_buffer(void* raw, uint64_t size,
                                       uint32_t usage_bits,
                                       const char* label) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLResourceOptions opts = MTLResourceStorageModeShared;
        id<MTLBuffer> buf = [ctx->device newBufferWithLength:(NSUInteger)size
                                                     options:opts];
        if (!buf) return 0;

        if (label) buf.label = [NSString stringWithUTF8String:label];

        uint32_t id = ctx->next_buffer_id++;
        ctx->buffers[id] = buf;
        return id;
    }
}

uint32_t guava_metal_rhi_create_texture(void* raw,
                                        const GuavaMetalTextureDesc* desc,
                                        const char* label) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLTextureDescriptor* td = [[MTLTextureDescriptor alloc] init];
        td.pixelFormat = mapPixelFormat(desc->format);
        td.width  = desc->width;
        td.height = desc->height;
        td.depth  = desc->depth;
        td.mipmapLevelCount = desc->mip_levels;
        td.sampleCount = desc->sample_count;
        td.storageMode = MTLStorageModePrivate;

        // Dimension
        switch (desc->dimension) {
            case 1:  td.textureType = MTLTextureType3D; break;
            case 2:  td.textureType = MTLTextureTypeCube;
                     td.arrayLength = 1; break;
            case 3:  td.textureType = MTLTextureType2DArray;
                     td.arrayLength = desc->layers; break;
            default: td.textureType = MTLTextureType2D; break;
        }

        // Usage flags
        MTLTextureUsage usage = 0;
        if (desc->usage_bits & 0x01) usage |= MTLTextureUsageShaderRead;       // sampled
        if (desc->usage_bits & 0x02) usage |= MTLTextureUsageRenderTarget;     // color_target
        if (desc->usage_bits & 0x04) usage |= MTLTextureUsageRenderTarget;     // depth_stencil_target
        if (desc->usage_bits & 0x08) usage |= MTLTextureUsageShaderRead;       // storage_read
        if (desc->usage_bits & 0x10) usage |= MTLTextureUsageShaderWrite;      // storage_write
        td.usage = usage;

        id<MTLTexture> tex = [ctx->device newTextureWithDescriptor:td];
        if (!tex) return 0;

        if (label) tex.label = [NSString stringWithUTF8String:label];

        uint32_t id = ctx->next_texture_id++;
        ctx->textures[id] = tex;
        return id;
    }
}

uint32_t guava_metal_rhi_create_sampler(void* raw,
                                        const GuavaMetalSamplerDesc* desc) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter    = desc->min_filter == 0 ? MTLSamplerMinMagFilterNearest
                                                : MTLSamplerMinMagFilterLinear;
        sd.magFilter    = desc->mag_filter == 0 ? MTLSamplerMinMagFilterNearest
                                                : MTLSamplerMinMagFilterLinear;
        sd.mipFilter    = desc->mipmap_mode == 0 ? MTLSamplerMipFilterNearest
                                                  : MTLSamplerMipFilterLinear;
        sd.sAddressMode = mapAddressMode(desc->address_u);
        sd.tAddressMode = mapAddressMode(desc->address_v);
        sd.rAddressMode = mapAddressMode(desc->address_w);

        id<MTLSamplerState> sampler = [ctx->device newSamplerStateWithDescriptor:sd];
        if (!sampler) return 0;

        uint32_t id = ctx->next_sampler_id++;
        ctx->samplers[id] = sampler;
        return id;
    }
}

uint32_t guava_metal_rhi_create_shader_module(void* raw,
                                              uint32_t stage,
                                              uint32_t format,
                                              const uint8_t* code,
                                              uint32_t code_len,
                                              const char* entry_point) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        id<MTLLibrary> lib = nil;

        if (format == 2) {  // MSL source
            NSString* src = [[NSString alloc] initWithBytes:code
                                                     length:code_len
                                                   encoding:NSUTF8StringEncoding];
            NSError* err = nil;
            lib = [ctx->device newLibraryWithSource:src options:nil error:&err];
            if (!lib) {
                fprintf(stderr, "[GuavaMetal] MSL compile error: %s\n",
                        err ? [[err localizedDescription] UTF8String] : "unknown");
                return 0;
            }
        } else if (format == 0) {  // SPIRV — needs SPIRV-Cross, stub for now
            fprintf(stderr, "[GuavaMetal] SPIRV shader loading not yet implemented\n");
            return 0;
        } else {
            fprintf(stderr, "[GuavaMetal] Unsupported shader format: %u\n", format);
            return 0;
        }

        NSString* ep = [NSString stringWithUTF8String:entry_point];
        id<MTLFunction> func = [lib newFunctionWithName:ep];
        if (!func) {
            fprintf(stderr, "[GuavaMetal] Function '%s' not found in library\n",
                    entry_point);
            return 0;
        }

        uint32_t id = ctx->next_shader_id++;
        ctx->shader_functions[id] = func;
        ctx->shader_libraries[id] = lib;
        return id;
    }
}

uint32_t guava_metal_rhi_create_graphics_pipeline(
    void* raw, const GuavaMetalGraphicsPipelineDesc* desc,
    const GuavaMetalVertexAttribute* attrs,
    const GuavaMetalVertexBufferLayout* buf_layouts) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        auto vit = ctx->shader_functions.find(desc->vertex_shader_id);
        auto fit = ctx->shader_functions.find(desc->fragment_shader_id);
        if (vit == ctx->shader_functions.end() ||
            fit == ctx->shader_functions.end()) {
            fprintf(stderr, "[GuavaMetal] Graphics pipeline creation: shader not found\n");
            return 0;
        }

        MTLRenderPipelineDescriptor* pd =
            [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction   = vit->second;
        pd.fragmentFunction = fit->second;
        pd.colorAttachments[0].pixelFormat = mapPixelFormat(desc->color_format);

        if (desc->depth_format != 0) {
            pd.depthAttachmentPixelFormat = mapPixelFormat(desc->depth_format);
        }

        // ── Vertex descriptor ─────────────────────────────────────────
        if (desc->vertex_attr_count > 0 && attrs && buf_layouts) {
            MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];

            for (uint32_t i = 0; i < desc->vertex_attr_count; i++) {
                vd.attributes[attrs[i].location].format =
                    mapVertexFormat(attrs[i].format);
                vd.attributes[attrs[i].location].offset = attrs[i].offset;
                vd.attributes[attrs[i].location].bufferIndex =
                    kVertexBufferBaseIndex + attrs[i].buffer_index;
            }

            for (uint32_t i = 0; i < desc->vertex_buffer_layout_count; i++) {
                vd.layouts[kVertexBufferBaseIndex + i].stride =
                    buf_layouts[i].stride;
                vd.layouts[kVertexBufferBaseIndex + i].stepFunction =
                    (buf_layouts[i].step_rate == 0)
                        ? MTLVertexStepFunctionPerVertex
                        : MTLVertexStepFunctionPerInstance;
                vd.layouts[kVertexBufferBaseIndex + i].stepRate = 1;
            }

            pd.vertexDescriptor = vd;
        }

        NSError* err = nil;
        id<MTLRenderPipelineState> pso =
            [ctx->device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) {
            fprintf(stderr, "[GuavaMetal] Graphics pipeline error: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "unknown");
            return 0;
        }

        uint32_t pipe_id = ctx->next_gfx_pipe_id++;
        ctx->gfx_pipelines[pipe_id] = pso;

        // ── Depth/stencil state (paired with this pipeline) ───────────
        if (desc->depth_format != 0) {
            MTLDepthStencilDescriptor* dsd =
                [[MTLDepthStencilDescriptor alloc] init];
            dsd.depthCompareFunction = mapCompareOp(desc->depth_compare_op);
            dsd.depthWriteEnabled = (desc->depth_write_enabled != 0);
            id<MTLDepthStencilState> dss =
                [ctx->device newDepthStencilStateWithDescriptor:dsd];
            if (dss) {
                ctx->depth_stencil_states[pipe_id] = dss;
            }
        }

        return pipe_id;
    }
}

uint32_t guava_metal_rhi_create_compute_pipeline(void* raw,
                                                  uint32_t shader_id) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        auto it = ctx->shader_functions.find(shader_id);
        if (it == ctx->shader_functions.end()) {
            fprintf(stderr, "[GuavaMetal] Compute pipeline: shader %u not found\n",
                    shader_id);
            return 0;
        }

        NSError* err = nil;
        id<MTLComputePipelineState> pso =
            [ctx->device newComputePipelineStateWithFunction:it->second
                                                      error:&err];
        if (!pso) {
            fprintf(stderr, "[GuavaMetal] Compute pipeline error: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "unknown");
            return 0;
        }

        uint32_t id = ctx->next_cmp_pipe_id++;
        ctx->cmp_pipelines[id] = pso;
        return id;
    }
}

// ---------------------------------------------------------------------------
// Resource destruction
// ---------------------------------------------------------------------------

void guava_metal_rhi_destroy_buffer(void* raw, uint32_t buffer_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->buffers.erase(buffer_id);
}

void guava_metal_rhi_destroy_texture(void* raw, uint32_t texture_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->textures.erase(texture_id);
}

void guava_metal_rhi_destroy_sampler(void* raw, uint32_t sampler_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->samplers.erase(sampler_id);
}

void guava_metal_rhi_destroy_graphics_pipeline(void* raw, uint32_t id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->gfx_pipelines.erase(id);
    ctx->depth_stencil_states.erase(id);
}

void guava_metal_rhi_destroy_compute_pipeline(void* raw, uint32_t id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->cmp_pipelines.erase(id);
}

// ---------------------------------------------------------------------------
// Data upload
// ---------------------------------------------------------------------------

bool guava_metal_rhi_upload_buffer_data(void* raw, uint32_t buffer_id,
                                        uint64_t offset,
                                        const uint8_t* data, uint64_t size) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    auto it = ctx->buffers.find(buffer_id);
    if (it == ctx->buffers.end()) return false;

    id<MTLBuffer> buf = it->second;
    if (offset + size > buf.length) return false;

    memcpy(static_cast<uint8_t*>(buf.contents) + offset, data, (size_t)size);
    return true;
}

// ---------------------------------------------------------------------------
// Binding set registration
// ---------------------------------------------------------------------------

void guava_metal_rhi_register_binding_set(void* raw, uint32_t set_id,
                                          const GuavaMetalBindingEntry* entries,
                                          uint32_t count) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    BindingSetData bsd;
    bsd.entries.assign(entries, entries + count);
    ctx->binding_sets[set_id] = std::move(bsd);
}

// ---------------------------------------------------------------------------
// Command submission — decode and translate to Metal
// ---------------------------------------------------------------------------

// Mini decoder: reads typed data from the serialized command bytes
struct CmdDecoder {
    const uint8_t* data;
    uint32_t       len;
    uint32_t       cursor;

    bool hasMore() const { return cursor < len; }

    uint8_t readU8() {
        if (cursor >= len) return 0xFF;
        return data[cursor++];
    }

    template <typename T>
    T read() {
        T val{};
        if (cursor + sizeof(T) <= len) {
            memcpy(&val, data + cursor, sizeof(T));
            cursor += sizeof(T);
        }
        return val;
    }
};

// Apply a registered binding set to the current render encoder
static void applyBindingSetRender(GuavaMetalRhiContext* ctx,
                                  id<MTLRenderCommandEncoder> enc,
                                  uint32_t pipeline_slot,
                                  uint32_t set_id) {
    auto it = ctx->binding_sets.find(set_id);
    if (it == ctx->binding_sets.end()) return;

    for (auto& e : it->second.entries) {
        uint32_t mtl_index = pipeline_slot * kEntriesPerSlot + e.slot;

        switch (e.resource_type) {
            case 3: { // uniform_buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit == ctx->buffers.end()) break;
                if (e.stage == 0) // vertex
                    [enc setVertexBuffer:bit->second offset:0 atIndex:mtl_index];
                else // fragment
                    [enc setFragmentBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 4: { // storage_buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit == ctx->buffers.end()) break;
                if (e.stage == 0)
                    [enc setVertexBuffer:bit->second offset:0 atIndex:mtl_index];
                else
                    [enc setFragmentBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 1: { // texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit == ctx->textures.end()) break;
                if (e.stage == 0)
                    [enc setVertexTexture:tit->second atIndex:mtl_index];
                else
                    [enc setFragmentTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 2: { // storage_texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit == ctx->textures.end()) break;
                if (e.stage == 0)
                    [enc setVertexTexture:tit->second atIndex:mtl_index];
                else
                    [enc setFragmentTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 0: { // sampler
                auto sit = ctx->samplers.find(e.resource_id);
                if (sit == ctx->samplers.end()) break;
                if (e.stage == 0)
                    [enc setVertexSamplerState:sit->second atIndex:mtl_index];
                else
                    [enc setFragmentSamplerState:sit->second atIndex:mtl_index];
                break;
            }
            default: break;
        }
    }
}

// Apply a registered binding set to the current compute encoder
static void applyBindingSetCompute(GuavaMetalRhiContext* ctx,
                                   id<MTLComputeCommandEncoder> enc,
                                   uint32_t pipeline_slot,
                                   uint32_t set_id) {
    auto it = ctx->binding_sets.find(set_id);
    if (it == ctx->binding_sets.end()) return;

    for (auto& e : it->second.entries) {
        uint32_t mtl_index = pipeline_slot * kEntriesPerSlot + e.slot;

        switch (e.resource_type) {
            case 3: case 4: { // uniform/storage buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit != ctx->buffers.end())
                    [enc setBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 1: case 2: { // texture / storage_texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit != ctx->textures.end())
                    [enc setTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 0: { // sampler
                auto sit = ctx->samplers.find(e.resource_id);
                if (sit != ctx->samplers.end())
                    [enc setSamplerState:sit->second atIndex:mtl_index];
                break;
            }
            default: break;
        }
    }
}

bool guava_metal_rhi_submit(void* raw, uint32_t queue_class,
                            const uint8_t* cmd_bytes, uint32_t cmd_len) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        id<MTLCommandQueue> queue = (queue_class == 1)
            ? ctx->compute_queue : ctx->graphics_queue;

        id<MTLCommandBuffer> mtlCmd = [queue commandBuffer];
        if (!mtlCmd) return false;

        CmdDecoder dec{cmd_bytes, cmd_len, 0};

        id<MTLRenderCommandEncoder>  renderEnc  = nil;
        id<MTLComputeCommandEncoder> computeEnc = nil;

        // Remembered index buffer state for draw_indexed
        id<MTLBuffer> current_index_buffer = nil;
        uint64_t      current_index_offset = 0;
        MTLIndexType   current_index_type  = MTLIndexTypeUInt32;

        while (dec.hasMore()) {
            uint8_t opcode = dec.readU8();

            switch (static_cast<RhiOpCode>(opcode)) {
            case OP_BEGIN_RENDER_PASS: {
                auto cmd = dec.read<CmdBeginRenderPass>();
                MTLRenderPassDescriptor* rpd =
                    [MTLRenderPassDescriptor renderPassDescriptor];

                // Look up color target texture
                auto cit = ctx->textures.find(cmd.color_target_id);
                if (cit != ctx->textures.end()) {
                    rpd.colorAttachments[0].texture = cit->second;
                    rpd.colorAttachments[0].loadAction =
                        (cmd.clear_mask & 0x1) ? MTLLoadActionClear
                                               : MTLLoadActionLoad;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rpd.colorAttachments[0].clearColor =
                        MTLClearColorMake(0, 0, 0, 1);
                }

                // Look up depth target texture
                auto dit = ctx->textures.find(cmd.depth_target_id);
                if (dit != ctx->textures.end()) {
                    rpd.depthAttachment.texture = dit->second;
                    rpd.depthAttachment.loadAction =
                        (cmd.clear_mask & 0x2) ? MTLLoadActionClear
                                               : MTLLoadActionLoad;
                    rpd.depthAttachment.storeAction = MTLStoreActionStore;
                    rpd.depthAttachment.clearDepth = 1.0;
                }

                renderEnc = [mtlCmd renderCommandEncoderWithDescriptor:rpd];
                break;
            }
            case OP_END_RENDER_PASS: {
                if (renderEnc) {
                    [renderEnc endEncoding];
                    renderEnc = nil;
                }
                current_index_buffer = nil;
                break;
            }
            case OP_BEGIN_COMPUTE_PASS: {
                dec.read<CmdBeginComputePass>(); // consume reserved field
                computeEnc = [mtlCmd computeCommandEncoder];
                break;
            }
            case OP_END_COMPUTE_PASS: {
                if (computeEnc) {
                    [computeEnc endEncoding];
                    computeEnc = nil;
                }
                break;
            }
            case OP_BEGIN_COPY_PASS: {
                dec.read<CmdBeginCopyPass>(); // consume reserved
                // Blit encoder — TODO when copy pass is needed
                break;
            }
            case OP_END_COPY_PASS: {
                break;
            }
            case OP_SET_PIPELINE: {
                auto cmd = dec.read<CmdSetPipeline>();
                if (renderEnc) {
                    auto it = ctx->gfx_pipelines.find(cmd.pipeline_id);
                    if (it != ctx->gfx_pipelines.end())
                        [renderEnc setRenderPipelineState:it->second];
                    // Also apply the paired depth/stencil state
                    auto dit = ctx->depth_stencil_states.find(cmd.pipeline_id);
                    if (dit != ctx->depth_stencil_states.end())
                        [renderEnc setDepthStencilState:dit->second];
                } else if (computeEnc) {
                    auto it = ctx->cmp_pipelines.find(cmd.pipeline_id);
                    if (it != ctx->cmp_pipelines.end())
                        [computeEnc setComputePipelineState:it->second];
                }
                break;
            }
            case OP_SET_BINDING_SET: {
                auto cmd = dec.read<CmdSetBindingSet>();
                if (renderEnc) {
                    applyBindingSetRender(ctx, renderEnc, cmd.slot, cmd.set_id);
                } else if (computeEnc) {
                    applyBindingSetCompute(ctx, computeEnc, cmd.slot, cmd.set_id);
                }
                break;
            }
            case OP_SET_VERTEX_BUFFER: {
                auto cmd = dec.read<CmdSetVertexBuffer>();
                if (renderEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        // Vertex buffers use a high base index to avoid
                        // clashing with uniform buffer slots
                        [renderEnc setVertexBuffer:it->second
                                            offset:(NSUInteger)cmd.offset
                                           atIndex:30 + cmd.slot];
                    }
                }
                break;
            }
            case OP_SET_INDEX_BUFFER: {
                auto cmd = dec.read<CmdSetIndexBuffer>();
                auto it = ctx->buffers.find(cmd.buffer_id);
                if (it != ctx->buffers.end()) {
                    current_index_buffer = it->second;
                    current_index_offset = cmd.offset;
                    current_index_type = (cmd.format == 0)
                        ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
                }
                break;
            }
            case OP_DRAW_INDEXED: {
                auto cmd = dec.read<CmdDrawIndexed>();
                if (renderEnc && current_index_buffer) {
                    uint32_t idx_size = (current_index_type == MTLIndexTypeUInt16)
                                            ? 2 : 4;
                    [renderEnc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                         indexCount:cmd.index_count
                                          indexType:current_index_type
                                        indexBuffer:current_index_buffer
                                  indexBufferOffset:current_index_offset +
                                                    cmd.first_index * idx_size
                                      instanceCount:cmd.instance_count
                                         baseVertex:cmd.vertex_offset
                                       baseInstance:cmd.first_instance];
                }
                break;
            }
            case OP_DRAW_INDIRECT: {
                auto cmd = dec.read<CmdDrawIndirect>();
                if (renderEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        // Metal indirect draw uses MTLDrawIndexedPrimitivesIndirectArguments
                        // For now, draw_count=1 indirect
                        [renderEnc drawPrimitives:MTLPrimitiveTypeTriangle
                                   indirectBuffer:it->second
                             indirectBufferOffset:(NSUInteger)cmd.offset];
                    }
                }
                break;
            }
            case OP_DISPATCH: {
                auto cmd = dec.read<CmdDispatch>();
                if (computeEnc) {
                    MTLSize grid = MTLSizeMake(cmd.x, cmd.y, cmd.z);
                    MTLSize tg   = MTLSizeMake(8, 8, 1); // default workgroup
                    [computeEnc dispatchThreadgroups:grid
                               threadsPerThreadgroup:tg];
                }
                break;
            }
            case OP_DISPATCH_INDIRECT: {
                auto cmd = dec.read<CmdDispatchIndirect>();
                if (computeEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        MTLSize tg = MTLSizeMake(8, 8, 1);
                        [computeEnc dispatchThreadgroupsWithIndirectBuffer:it->second
                                                      indirectBufferOffset:(NSUInteger)cmd.offset
                                                     threadsPerThreadgroup:tg];
                    }
                }
                break;
            }
            case OP_PIPELINE_BARRIER: {
                dec.read<CmdPipelineBarrier>(); // state tracking only for now
                break;
            }
            default:
                fprintf(stderr, "[GuavaMetal] Unknown opcode: %u\n", opcode);
                return false;
            }
        }

        // End any still-open encoders
        if (renderEnc)  [renderEnc endEncoding];
        if (computeEnc) [computeEnc endEncoding];

        [mtlCmd commit];
        return true;
    }
}

// ---------------------------------------------------------------------------
// Swapchain — real CAMetalLayer drawable acquisition
// ---------------------------------------------------------------------------

bool guava_metal_rhi_acquire_swapchain(void* raw,
                                       uint32_t* out_id,
                                       uint32_t* out_width,
                                       uint32_t* out_height) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        if (!ctx->metal_layer) {
            fprintf(stderr, "[GuavaMetal] acquire_swapchain: no CAMetalLayer configured\n");
            return false;
        }

        id<CAMetalDrawable> drawable = [ctx->metal_layer nextDrawable];
        if (!drawable) {
            fprintf(stderr, "[GuavaMetal] acquire_swapchain: nextDrawable returned nil\n");
            return false;
        }

        // Remove previous swapchain texture entry if any
        if (ctx->swapchain_texture_id != 0) {
            ctx->textures.erase(ctx->swapchain_texture_id);
        }

        // Register the drawable's texture in the texture map so render passes
        // can reference it by ID like any other texture.
        uint32_t tex_id = ctx->next_texture_id++;
        ctx->textures[tex_id] = drawable.texture;
        ctx->current_drawable = drawable;
        ctx->swapchain_texture_id = tex_id;

        CGSize sz = ctx->metal_layer.drawableSize;
        *out_id    = tex_id;
        *out_width = (uint32_t)sz.width;
        *out_height = (uint32_t)sz.height;
        return true;
    }
}

bool guava_metal_rhi_present(void* raw, uint32_t /*swapchain_id*/) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        if (!ctx->current_drawable) {
            fprintf(stderr, "[GuavaMetal] present: no current drawable\n");
            return false;
        }

        [ctx->current_drawable present];
        ctx->current_drawable = nil;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Debug
// ---------------------------------------------------------------------------

const char* guava_metal_rhi_get_device_name(void* raw) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    return [[ctx->device name] UTF8String];
}
