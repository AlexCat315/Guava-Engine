// IOSurface display native addon for macOS.
// Attaches a GPU-rendered IOSurface (from the engine process) to the Electron
// window's NSView layer hierarchy via a CALayer — zero-copy cross-process
// texture sharing.

#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <napi.h>

static CALayer* g_surfaceLayer = nil;
static IOSurfaceRef g_surface = nullptr;
static NSView* g_parentView = nil;

// Convert CSS/web coordinates (origin at top-left) to AppKit layer coordinates
// (origin at bottom-left).
static CGRect webRectToLayerRect(NSView* view, double x, double y, double w, double h) {
    CGFloat viewHeight = view.bounds.size.height;
    return CGRectMake(x, viewHeight - y - h, w, h);
}

// ── attach(nativeHandle: Buffer, surfaceId: number, x, y, w, h) ─────────
// Creates a CALayer backed by the given IOSurface and adds it as a sublayer
// of the Electron window's contentView.
static Napi::Value Attach(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 6) {
        Napi::Error::New(env, "attach: expected 6 arguments").ThrowAsJavaScriptException();
        return env.Undefined();
    }

    auto handleBuf  = info[0].As<Napi::Buffer<uint8_t>>();
    uint32_t sid    = info[1].As<Napi::Number>().Uint32Value();
    double x        = info[2].As<Napi::Number>().DoubleValue();
    double y        = info[3].As<Napi::Number>().DoubleValue();
    double w        = info[4].As<Napi::Number>().DoubleValue();
    double h        = info[5].As<Napi::Number>().DoubleValue();

    // The buffer contains a raw pointer (NSView*) valid in *this* process.
    if (handleBuf.Length() < sizeof(void*)) {
        Napi::Error::New(env, "attach: handle buffer too small").ThrowAsJavaScriptException();
        return env.Undefined();
    }
    void* rawPtr = nullptr;
    std::memcpy(&rawPtr, handleBuf.Data(), sizeof(void*));
    NSView* view = (__bridge NSView*)rawPtr;

    IOSurfaceRef surface = IOSurfaceLookup(sid);
    if (!surface) {
        Napi::Error::New(env, "attach: IOSurfaceLookup failed — invalid surface id")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    // Electron main process N-API callbacks are on the main thread, so we
    // can do AppKit work directly without dispatch_async.

    // Tear down previous layer if any.
    if (g_surfaceLayer) {
        [g_surfaceLayer removeFromSuperlayer];
        g_surfaceLayer = nil;
    }
    if (g_surface) {
        CFRelease(g_surface);
    }
    g_surface = surface;
    g_parentView = view;

    view.wantsLayer = YES;

    CALayer* layer = [CALayer layer];
    layer.contents = (__bridge id)surface;
    layer.contentsGravity = kCAGravityResize;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = webRectToLayerRect(view, x, y, w, h);
    [CATransaction commit];

    [view.layer addSublayer:layer];
    g_surfaceLayer = layer;

    return env.Undefined();
}

// ── updateFrame(x, y, w, h) ─────────────────────────────────────────────
static Napi::Value UpdateFrame(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 4) return env.Undefined();

    double x = info[0].As<Napi::Number>().DoubleValue();
    double y = info[1].As<Napi::Number>().DoubleValue();
    double w = info[2].As<Napi::Number>().DoubleValue();
    double h = info[3].As<Napi::Number>().DoubleValue();

    if (g_surfaceLayer && g_parentView) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_surfaceLayer.frame = webRectToLayerRect(g_parentView, x, y, w, h);
        [CATransaction commit];
    }
    return env.Undefined();
}

// ── updateSurface(surfaceId) ─────────────────────────────────────────────
// Called when the engine re-creates the IOSurface (e.g. on viewport resize).
static Napi::Value UpdateSurface(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1) return env.Undefined();

    uint32_t sid = info[0].As<Napi::Number>().Uint32Value();
    IOSurfaceRef surface = IOSurfaceLookup(sid);
    if (!surface) {
        Napi::Error::New(env, "updateSurface: IOSurfaceLookup failed")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }

    if (g_surface) CFRelease(g_surface);
    g_surface = surface;
    if (g_surfaceLayer) {
        g_surfaceLayer.contents = (__bridge id)surface;
    }
    return env.Undefined();
}

// ── detach() ─────────────────────────────────────────────────────────────
static Napi::Value Detach(const Napi::CallbackInfo& info) {
    if (g_surfaceLayer) {
        [g_surfaceLayer removeFromSuperlayer];
        g_surfaceLayer = nil;
    }
    if (g_surface) {
        CFRelease(g_surface);
        g_surface = nullptr;
    }
    g_parentView = nil;
    return info.Env().Undefined();
}

// ── refresh() ────────────────────────────────────────────────────────────
// Force the layer to re-composite (pick up new IOSurface content).
static Napi::Value Refresh(const Napi::CallbackInfo& info) {
    if (g_surfaceLayer && g_surface) {
        g_surfaceLayer.contents = nil;
        g_surfaceLayer.contents = (__bridge id)g_surface;
    }
    return info.Env().Undefined();
}

// ── Module init ──────────────────────────────────────────────────────────
static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("attach",        Napi::Function::New(env, Attach));
    exports.Set("updateFrame",   Napi::Function::New(env, UpdateFrame));
    exports.Set("updateSurface", Napi::Function::New(env, UpdateSurface));
    exports.Set("detach",        Napi::Function::New(env, Detach));
    exports.Set("refresh",       Napi::Function::New(env, Refresh));
    return exports;
}

NODE_API_MODULE(iosurface_view, Init)
