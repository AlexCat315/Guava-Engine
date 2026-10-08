# GuavaUI 与 GPUI Kit 对照审计

审计日期：2026-10-08。参照 [GPUI Kit](https://gpui-kit.com/)、[上游代码](https://github.com/longbridge/gpui-kit) 和本机 `/Users/alex/gpui-kit-main` 快照。逐项清单来自该快照 `crates/story/src/gallery.rs` 的 79 个 Story 注册项；Story 包含欢迎页、主题页和平台特定功能，不能当作 79 个独立组件。GuavaUI 新画廊有 63 个 Story，同样不是 63 个完全独立组件。

**结论：GuavaUI 目前没有 GPUI Kit 那样完整，也没有足够依据声称质量相当。** GuavaUI 已有可用的输入编辑、虚拟化、浮层、树和工作区基础；更大的差距在完整的产品组件、统一状态契约、辅助功能、性能证据和示例覆盖。旧组件文档的“✅”仅代表写过设计文档，不代表行为完成或生产成熟度。

本次按照组件职责重构已有实现，保留已有有效基础；没有复制 Rust 源码、上游文档原文或图片。参考的是行为和展示组织方式。Swift 与 Rust 的状态/渲染机制不同，机械翻译上游大结构也会违背本项目的可维护性要求。

## 逐项对应

“已有”表示有明确实现；“基础/部分”表示有相似能力但不足以等同上游完整组件；“缺少”表示没有可直接复用的 first-party 组件。业务面板或手写 Row 不作为完整组件计数。

| GPUI Kit Story | GuavaUI 对应 | 评估与仍有差距的部分 |
| --- | --- | --- |
| Welcome | Introduction | 已有独立总览和导航 |
| Accordion | Accordion / DisclosureGroup | 已有受控单开/多开、禁用、组内键盘焦点与展开语义；仍需更多视觉和动画验证 |
| Alert | Alert（本次新增） | 基础；标题、说明、语义状态，无丰富操作槽位 |
| AlertDialog | AlertDialog | 已有确认/取消、危险操作、提交中禁用及关闭策略；需继续验证业务异步场景 |
| Attachment | — | 缺少附件展示、上传状态与操作组件 |
| Avatar | Avatar / AvatarGroup | 已有图片/首字母/匿名回退、四档尺寸/形状、稳定明暗配色、重叠/溢出及辅助功能；原生远程图片/中文/组边界已验证。macOS 彩色 emoji 已补并完成原生验证；缺状态角标与可交互成员弹层，不宣称跨平台 Unicode 视觉等价 |
| Badge | Badge（本次新增） | 基础状态标签；不是完整数字/图标徽章体系 |
| Breadcrumb | Breadcrumb | 已有路径、当前项、折叠菜单和禁用；缺图标/自定义槽位及更丰富截断策略 |
| Bubble | — | 缺少对话气泡 |
| Button | Button / ButtonGroup | 加载、状态色、图标、受控按钮组及实际组内焦点已有；提示已统一延迟、键盘焦点和 Portal 生命周期；Link 变体仍缺 |
| Calendar | CalendarView | 月网格、多月、禁用日期、区域设置、DST 与跨月键盘导航已有；缺范围选择 |
| Carousel | — | 缺少轮播 |
| Chart | MonitorChart / Sparkline / BarChart | 基础监控图；缺分类坐标、图例、饼图、堆叠与复杂交互 |
| Checkbox | Checkbox | 半选、禁用清理、拖出取消、辅助功能角色/动作已有；关联标签通过 FieldLabel/Form 提供 |
| Clipboard | ClipboardHolder | 部分；平台适配器存在，无独立复制组件/反馈 |
| Collapsible | DisclosureGroup | caller-owned 展开、动画与 expanded 辅助功能语义已有 |
| ColorPicker | ColorField | 部分；RGBA/Hex 存在，无 HSV 面板、取色器等完整选择器 |
| Combobox | Combobox | 受控选择、Unicode 搜索、清空、键盘高亮/确认已有；缺多选和异步选项协议 |
| Command | Editor CommandPaletteOverlay | 业务实现存在；缺可复用命令面板 |
| DataTable | DataTable / DataTableModel | 已有持久模型、后台稳定排序/两投影缓存、双轴窗口化、固定表头、冻结列、多选、验证式单元格编辑；200K × 100 自动化及 200K × 33 原生验证已有。缺列重排、分组表头、远端加载及矩形单元格选择 |
| DatePicker | DatePicker | 日期弹层、选择关闭、清空、禁用已有；缺范围与时间组合选择 |
| DescriptionList | PropertyGrid | 编辑型属性网格存在；缺独立只读描述列表 |
| Dialog | Dialog / Modal | 标题、描述、内容/操作槽、关闭策略、焦点约束与模态辅助功能隔离已有 |
| Diff | — | 缺少差异编辑器 |
| Dock | GuavaUIWorkspace | 已有拖拽、拆分、布局序列化和测试；不能据此声称大规模性能相同 |
| DropdownButton | Button + Popover | 可组合；没有标准分裂按钮 |
| Editor | TextField codeEditing / ScriptCodeEditor | 已迁移 Binding<TextBuffer>、可见行布局与共享根历史；后台 Tree-sitter、真实 LSP 诊断/补全/hover 已接线；200K 行原生连续输入 30 秒、撤销/重做与 Instruments 采样已验证；已验证真实进程中断、有限重连、未保存根保留和手动恢复。仍缺搜索/替换、多光标、折叠和完整 snippet 导航，不能等同上游成熟度 |
| Empty | EmptyState（本次新增） | 基础；解释和操作槽位 |
| Form | Form / FormController | 布局、关联字段标签、验证规则、错误汇总和提交状态已有；值由应用持有，验证/提交为瞬态 |
| GroupBox | Panel | 基础分组容器存在；缺表单分组语义 |
| HoverCard | — | 缺少可交互悬浮卡片 |
| Icon | Icon / UICommonIcons | SVG 语义着色；修正 Demo 密度遗漏、现有节点随密度/尺寸重新栅格化及图标像素对齐；目录仍小 |
| Image | Image / AsyncImage / AsyncImageThumbnail | 已有显式加载/成功/失败/空阶段、文件/HTTP 流式限制、取消/旧结果丢弃/重试、后台解码/UI 上传和尺寸缓存；fill 改为 UV 中央裁切，SVG 按显示密度重新栅格化。仍缺缓存淘汰、在途合并、动画图像及 EXIF 方向归一化 |
| Input | TextField | 配置组、Rope API、可见行布局、IME/历史和延迟可访问性全文值已有；水平超长单行布局仍未分段 |
| InputGroup | TextFieldDecoration | 部分；prefix/suffix/prepend/append 是文字，缺任意视图操作槽位 |
| Kbd | KeyCap / KeyboardShortcut | 平台快捷键格式化与键帽组件已有 |
| Label | FieldLabel / Form | 按场景关联输入焦点、必填、help 和校验错误语义已有 |
| List | List | 本次补键盘导航、滚动到选中项、Hover 和拖出取消；仍仅固定行高/单选 |
| Menu | Menu / MenuDescriptor | 已有嵌套分支/分组、共享会话、逐层键盘/焦点恢复、前缀查找、滚动显露、水平翻转及销毁清理；缺富内容行、图标/链接与更精细指针 intent |
| Marker | ChartMarker | 仅图表标记，不等于通用标记组件 |
| Message | — | 缺少消息内容组件 |
| MessageScroller | — | 缺少聊天滚动锚定/加载历史 |
| NativeMenu | GuavaUIApp.NativeMenu | 已有平台菜单描述与绑定；独立画廊没有修改系统菜单 |
| Notification | ToastController / NotificationHost | 有界队列、替换、悬停暂停、持续通知、超时及销毁清理已有 |
| NumberInput | NumberField | 已有草稿提交、边界和步进；本次示例涵盖无效值、混合值、禁用 |
| OtpInput | — | 缺少验证码输入 |
| Pagination | Pagination | 页码、省略、边界和受控页码已有；空数据及 Int.max 已测试 |
| Popover | Popover / Portal | 已有定位、翻转、焦点及销毁机制；本次独立表单示例 |
| Progress | ProgressView（本次新增） | 基础确定进度，无完整尺寸/布局变体 |
| Questionnaire | — | 缺少问卷 |
| Radio | RadioGroup | 受控选择、禁用、单 Tab 停靠及箭头实际焦点移动已有 |
| Rating | Rating / RatingSelection / RatingAppearance | 新增整星/半星、预览、捕获取消、单个 Tab 停靠点、键盘边界、只读分数及 SVG 密度；原生明暗展示/键盘/辅助功能写入及鼠标命中/预览/拖动/取消已验证；不含 RTL/其他评分图形 |
| Resizable | ResizableEditor / TextArea / Workspace | 部分；可拖拽缩放存在，SplitView 本身仅比例布局 |
| Scrollbar | ScrollView 内置 | 已有拖动/稳定 gutter；无独立滚动条 API |
| Select | Select / EnumField | 已有类型化单选和键盘；缺多选、搜索、异步选项 |
| Separator | Divider | 已有水平/垂直分隔 |
| Settings | PropertyGrid / Editor SettingsPanel | 属性编辑和业务设置存在；缺通用设置页模型 |
| Shell | — | 缺 GPUI Shell 那样的 UI JavaScript 扩展层；引擎脚本运行时不是等价物 |
| Sheet | Sheet | 四侧放置/大小、各自边缘进入/退出、模态焦点与恢复已有；四方向生命周期测试和原生顶部/右侧展示已验证 |
| Shimmer | — | 缺少流光占位 |
| Sidebar | Sidebar | 公开受控导航、分组、header/footer、禁用、Badge 与组内焦点；画廊已复用 |
| Skeleton | — | 缺少骨架占位 |
| Slider | Slider | 本次补方向键/Home/End、禁用清理、只响应左键；缺范围双滑块/刻度 |
| Speech | — | 缺少语音输入组件 |
| Spinner | Spinner（本次新增） | 生命周期管理的基础指示器，需扩展减少动画偏好支持 |
| StatusBar | StatusBarStrip | 基础编辑器状态栏，无完整组合/交互体系 |
| Stepper | — | 缺步骤流程组件；数字步进按钮不是这个组件 |
| Switch | Toggle | 已有开关；同一实现不重复计数 |
| Table | Table / DataTable | Table 保留小数组便捷接口；大型集合使用持久 DataTableModel，避免每次重组排序/扫描选择。表格级导出、撤销和可变行高仍缺 |
| Tabs | TabView / Workspace tabs | 本次补禁用和键盘移动实际焦点；文档拖拽/关闭由 Workspace 负责 |
| Tag | Tag / Badge | 独立删除动作、状态色与禁用已有；缺编辑/输入标签集合 |
| Textarea | ResizableTextArea | 本次分离普通多行输入和代码装饰；保持内部滚动/外部缩放 |
| ThemeColors | Theme / SemanticColorRef | 已有明暗主题和 tokens；ColorScheme 仍有既存结构债务 |
| TimeField | TimeField / TimeOfDay | 受控时间、提交/取消草稿、范围、秒与键盘步进已有；缺时间列表面板 |
| Toggle | Button.isSelected + ToggleButtonStyle | 有选中按钮基础；与 GuavaUI 名为 Toggle 的开关需区分 |
| Toolbar | Row / ToolStrip / ToolbarToggleButtonStyle | 基础；缺完整 Toolbar 组内键盘语义 |
| Tooltip | Tooltip / Button.tooltip | 按钮与通用提示共用延迟、hover/键盘焦点及 Portal 会话；自然宽度/最大宽度、窗口翻转、Escape/点击关闭、禁用/卸载清理已有；坐标/范围锚定接入编辑器 hover |
| Tree | Tree | 分组配置/会话、虚拟化、多选/搜索/拖拽与 treeItem/expanded 语义已有；仍需大规模实测和细节审查 |
| VirtualList | VirtualList / VirtualStack | 已有固定行高窗口化和定位；缺可变行高与加载语义 |

## 本次逐组件修改

- **Button**：加载状态阻止重复提交；Spinner 随组件销毁取消注册；新增 Info/Success/Warning 状态色样式；完整展示现有 primary/secondary/destructive/ghost、图标、tooltip、选中和四档尺寸。
- **Checkbox / Toggle**：半选到全选的激活语义；禁用移出焦点链、清理捕获；按下后拖到外部松开取消；键盘事件仅在正确阶段激活。
- **Slider**：方向键、Home/End；左键约束；禁用途中释放拖拽及编辑状态；无效 step 归一化。步进相对于下界，避免零起点假设。
- **TextField**：37 个扁平参数改为 layout / behavior / decoration / codeEditing / navigation / events；默认值由组持有；组独立校验。PaintIdentity 直接持有可比较组，不再重复平铺。节点中的选区、IME、历史、光标和滚动保持瞬态。迁移所有 first-party 调用方。
- **TextArea / JsonField**：普通多行文本不再默认变成带行号和 Tab 缩进的代码编辑器；JSON 显式复制 codeEditing 组并应用等宽字体；缩放禁用清理捕获。
- **Tree**：配置分组与 TreeSession 分离；行 appearance / geometry / slots / actions / drag 组在 Composite 与 Host 之间整组传递；统一默认值和布局校验，迁移 Editor Hierarchy 和全部测试。
- **List**：方向键、Home/End/Return、滚到选中项、Hover 和拖出取消。嵌套控件仍先处理事件。
- **TabView**：禁用标签；箭头绕过禁用项并循环；Home/End；切换选中项同时移动实际焦点。
- **Modal**：背景右键不再关闭；已有焦点与 Portal 机制保留并单独展示。
- **NumberField / Vec3Field / ColorField / Select / AssetRef / Chart / Panel / Scroll / PropertyGrid / Icon / Image / Animation / Workspace**：保留已有有效实现，新增独立真实示例和状态场景。没有为“重构数量”改写通过验证的逻辑，剩余能力差距见上表。

- **Avatar / Image**：新增独立头像/头像组与共享异步图片阶段接口，复用旧缩略图调用方；实际窗口检查发现并修正 width-only Slider 零高度、SVG 缩略图受自然尺寸限制的模糊问题。随后补齐 macOS 彩色字形的 CoreText shaping/栅格与独立 RGBA 图集，接入普通文字、输入框、应用宿主与游戏内 HUD；字号固定、绘图上下文随密度缩放，避免系统 bitmap strike 改变光标宽度。明暗主题、头像、14/24/40 点混排、文字着色/透明度、单字符删除/选区替换/撤销均已在原生窗口验证。契约与边界见 [头像](../components/avatar.md) 和 [文字渲染](../components/typography.md)。

## 画廊组织

入口：`swift run --package-path GuavaUI GuavaUIDemo`。可用 `--component textField`、`--component Tree`、`--component workspace` 直接打开指定页。`--benchmark` / `--no-vsync` 保留原运行时测试用途；`--shared-counter` 保留 Portable/Wasm 共享示例入口。

画廊实现位于 `GuavaUI/Sources/GuavaUIGallery/`，GPU/平台入口保留在 `GuavaUIDemo/main.swift`。目录、导航壳与按类别划分的 Story 分离。每个 Story 自己持有示例状态；导航和 Reset 用显式身份切换，避免组件间状态串用。Workspace 示例用真实 JSON 编解码保存/恢复布局，不把输入、焦点、拖拽等临时状态写入布局。

“Disabled”只控制具有显式禁用契约的示例控件；树/列表/布局等浏览类示例仍可浏览。画廊不代替 NativeMenu、Viewport 及 ScriptCanvas 的应用宿主集成测试，也不宣称 Wasm 已拥有完整原生画廊。

## 基础质量修正与验证边界

- 字体测量与绘制使用同一当前主题，接通字距与缓存键；CRLF、Unicode 换行、空行和末尾换行保持完整，混合字体和空行共享基线。换行不会拆开一个 shaping cluster。
- macOS 原生彩色字体使用 CoreText 提供同一 positioned-glyph 流；普通文字保留 FreeType alpha 图集，RGBA 只在首次彩色字形绘制时分配。布局不触发 bitmap 分配；两图集均支持脏区域上传/重置。游戏内传输按 alpha/RGBA 独立保留合并后的完整纹理，防止 GPU 启动跳帧丢字形。跨平台彩色字体及浏览器 RGBA 字形传输仍未完成。
- Demo 同步字体和图标的 drawable 密度。已有 SVG 节点在尺寸/密度改变后重新取对应纹理，无需重建节点；alpha-mask 图标对齐物理像素。1×/2×、尺寸变更和无效密度都有测试，Retina 原生窗口已确认按钮图标边缘清楚。
- 表格不再套普通 List 的行内边距；表头/单元格共享列起点，Badge 保持自然尺寸。列拖拽区域与绘制的细分隔线分开，表头/斑马纹铺满视口。新增 DataTable 的持久 ID 索引、后台排序/两投影缓存及横向列窗口，冻结列使用同一几何坐标。原生 200K × 33 验证中部定位/单元格提交/排序完成/横向键盘导航，自动化覆盖 200K × 100 创建窗口；没有定量 FPS 证据。
- 新增不可变 TextBuffer/Rope：Unicode 叶子、编辑接缝修复、缓存索引、AVL join、结构共享、parser LF 与 LSP UTF-16 坐标转换、跨多版本增量范围。测试包括 1,500 次随机 Unicode 编辑、长 RI 串、超长组合字符、CRLF、跨版本/undo delta 和十万行中部 500 次编辑。
- **大文件验证分层报告。** 存储层随机 Unicode/平衡测试、TextField 200K 行输入/绘制/IME 测试、Tree-sitter 子树复用/后台合并测试均已实现。原生生产编辑器在第 100001 行连续输入 30.180 秒、357 字符，一秒窗口 FPS 为 57.5–60.6，中位数 59.8，EditorApp RSS 为约 301–308 MiB；横向光标显露、固定行号和重复撤销/重做已确认。Time Profiler 中 `ts_parser_parse*` 全部位于 worker，未采到主线程解析；Swift grammar 仍有较重解析工作。真实 SourceKit-LSP 诊断、前缀补全/Tab 与 F1 文档浮层均在原生窗口验证。[完整口径、证据和限制](code-editor-validation.md)单独记录，不宣称已达到 GPUI 的成熟程度。

## 后续实现顺序

1. 优先审查已实现组件的排版、图标、焦点、状态与视觉细节，逐页做原生窗口验证；不以目录数量判断质量。
2. 真实编辑器的 Rope/可见行布局/Tree-sitter/LSP 接线与原生 30 秒输入验证已完成；已补意外退出状态、最多三次自动重连、最新未保存根重开、手动重试与初始化取消，并完成原生中断/恢复验证；继续补搜索/替换、折叠、长行分段，扩大跨平台恢复、IME 和长期内存验证。
3. DataTable 当前已具备数据模型/后台排序缓存、双轴虚拟化、冻结、多选和单元格编辑；继续验证长时间滚动/内存、业务使用，并补列重排、分组表头和远端数据协议。
4. 补齐 Attachment、Bubble/Message、Carousel、Command、HoverCard、OtpInput、Skeleton/Shimmer、Stepper 等产品组件，以及 Diff/富文本/复杂图表。Rating 已新增并完成原生指针验收；仍需 RTL 等边界。

已有测试验证本仓库行为，不是上游性能或品质等价证明。缺失/部分项继续保持明确，避免外观占位或仅注册 Story 就宣布完成。
