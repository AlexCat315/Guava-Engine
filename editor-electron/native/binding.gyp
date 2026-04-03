{
  "targets": [
    {
      "target_name": "iosurface_view",
      "conditions": [
        ["OS=='mac'", {
          "sources": ["src/iosurface_view.mm"],
          "xcode_settings": {
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "OTHER_LDFLAGS": [
              "-framework", "Cocoa",
              "-framework", "IOSurface",
              "-framework", "QuartzCore"
            ],
            "MACOSX_DEPLOYMENT_TARGET": "13.0"
          }
        }],
        ["OS=='linux'", {
          "sources": ["src/shm_view.cpp"],
          "libraries": ["-lrt"]
        }]
      ],
      "include_dirs": [
        "<!(node -p \"require('node-addon-api').include_dir\")"
      ],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"]
    }
  ]
}
