# Cocoa 指针输入

Rating 的原生验收暴露了 SDL 3.4.18 的输入问题。macOS 26+ 的 SDL 窗口位置补偿用当前全局硬件查询替代每条移动事件的位置；焦点窗口的按键事件又读取这个缓存。当前查询与排队事件不同步时，点中正确目标的 NSEvent 会变成旧坐标。Cocoa 的按钮对账还可能在拖动事件前按当前硬件状态插入松开，破坏捕获与取消。

保留 macOS 26 的全局位置补偿，但从事件的 `CGEvent` 读取全局坐标；没有 CGEvent 时保留原查询回退。绝对模式的按键使用事件位置，后台窗口仍临时保存/恢复缓存；相对模式保留虚拟位置。明确的按钮/拖动事件按队列顺序处理，不用当前硬件状态覆盖它们；其他事件的原有按钮对账保留。

修补在 `Engine/third-party/patches/sdl3-cocoa-event-coordinate.patch`，由 `cmake/PatchSDL3Cocoa.cmake` 在 macOS 构建时应用到 CMake build tree 的一次性 SDL 副本。原始 submodule revision 保持固定，工作区中的 submodule 不会被改写；文件不匹配时配置失败，要求检查上游变更。重复配置先检查反向补丁，不重复应用。父仓库提交修补与构建规则。

重建并记录 SDK：

```sh
cmake --build Engine/build/native --target manifest_SDL3 --parallel 8
swift build --package-path GuavaUI --product GuavaUIDemo
```

对全新源码副本、重复配置、上游上下文变化的拒绝进行了检查，并确认构建后 `git -C Engine/third-party/sdl3 status` 干净。独立 SDL 窗口验证两次完整点击与拖动的按下/移动/松开坐标；生产画廊验证 Rating 的预览、整星/半星、重复清零、内部释放、拖出取消和禁用，以及连续 Slider 拖动后的 Idle 状态。GuavaUI/Editor 全量测试通过。[原生记录](evidence/sdl-cocoa-input-native.json)。

当前证据来自原生窗口的 CUA 输入，尚未覆盖物理鼠标、多显示器、Spaces 和相对模式的原生验收，也没有延迟或吞吐测量。生产 Swift 源码没有遗留临时探针。
