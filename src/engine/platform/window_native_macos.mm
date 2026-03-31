#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "window_native_handles.h"
#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_video.h>

namespace {

NSWindow* guava_ns_window_from_sdl(SDL_Window* window) {
    if (window == nullptr) {
        return nil;
    }

    const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
    if (properties == 0) {
        return nil;
    }

    void* cocoa_window = SDL_GetPointerProperty(properties, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
    if (cocoa_window == nullptr) {
        return nil;
    }

    return (__bridge NSWindow*)cocoa_window;
}

} // namespace

extern "C" bool guava_window_create_metal_layer_binding(void* window_handle, GuavaMetalLayerBinding* out_binding) {
    if (window_handle == nullptr || out_binding == nullptr) {
        return false;
    }

    SDL_MetalView metal_view = SDL_Metal_CreateView(static_cast<SDL_Window*>(window_handle));
    if (metal_view == nullptr) {
        return false;
    }

    void* raw_layer = SDL_Metal_GetLayer(metal_view);
    if (raw_layer == nullptr) {
        SDL_Metal_DestroyView(metal_view);
        return false;
    }

    out_binding->metal_view = metal_view;
    out_binding->layer = raw_layer;
    return true;
}

extern "C" void guava_window_destroy_metal_layer_binding(GuavaMetalLayerBinding binding) {
    if (binding.metal_view != nullptr) {
        SDL_Metal_DestroyView((SDL_MetalView)binding.metal_view);
    }
}

extern "C" void* guava_window_get_native_cocoa_window(void* window_handle) {
    NSWindow* native_window = guava_ns_window_from_sdl(static_cast<SDL_Window*>(window_handle));
    if (native_window == nil) {
        return nullptr;
    }

    return (__bridge void*)native_window;
}

extern "C" bool guava_window_apply_macos_native_titlebar_style(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return false;
        }

        native_window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        native_window.titleVisibility = NSWindowTitleHidden;
        native_window.titlebarAppearsTransparent = YES;
        native_window.movable = NO;
        native_window.movableByWindowBackground = NO;

        NSWindowCollectionBehavior behavior = native_window.collectionBehavior;
        behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
        behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
        behavior |= NSWindowCollectionBehaviorFullScreenNone;
        native_window.collectionBehavior = behavior;
        return true;
    }
}

extern "C" float guava_window_macos_titlebar_leading_inset(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return 0.0f;
        }

        NSButton* zoom_button = [native_window standardWindowButton:NSWindowZoomButton];
        if (zoom_button == nil) {
            return 0.0f;
        }

        return static_cast<float>(NSMaxX(zoom_button.frame) + 12.0);
    }
}

extern "C" void guava_window_activate_macos_app(void) {
    @autoreleasepool {
        [NSApp activate];
    }
}

extern "C" bool guava_window_begin_macos_native_drag(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return false;
        }

        NSEvent* event = [NSApp currentEvent];
        if (event == nil) {
            return false;
        }

        if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseDragged) {
            return false;
        }

        [native_window performWindowDragWithEvent:event];
        return true;
    }
}
