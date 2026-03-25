#import <AppKit/AppKit.h>

#include <SDL3/SDL.h>
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

extern "C" bool guava_window_apply_macos_native_titlebar_style(SDL_Window* window) {
    @autoreleasepool {
        NSWindow* native_window = guava_ns_window_from_sdl(window);
        if (native_window == nil) {
            return false;
        }

        native_window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        native_window.titleVisibility = NSWindowTitleHidden;
        native_window.titlebarAppearsTransparent = YES;
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
