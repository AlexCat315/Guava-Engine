{
  "targets": [
    {
      "target_name": "iosurface_view",
      "sources": ["src/iosurface_view.mm"],
      "include_dirs": [
        "<!(node -p \"require('node-addon-api').include_dir\")"
      ],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
      "xcode_settings": {
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "OTHER_LDFLAGS": [
          "-framework", "Cocoa",
          "-framework", "IOSurface",
          "-framework", "QuartzCore"
        ],
        "MACOSX_DEPLOYMENT_TARGET": "13.0"
      }
    }
  ]
}
