# 文件预览 Design QA

## Findings

- 无 P0/P1/P2 阻断项。
- [P3] 参考图在 720px 左右的预览宽度下为工具栏动作同时显示图标和文字；实际应用受现有 350px 工作区侧栏约束，预览宽度约 635px，因此保留关键“用其他应用打开”文字，其余动作使用图标和 tooltip。功能完整，属于可接受的密度调整。
- [P3] 参考图示例同时打开两个文件标签；实现按真实状态显示一个或多个标签，不为视觉对齐伪造第二个文件。

## Open Questions

- 无。当前实现沿用已有工作区侧栏宽度、Flutter 字体和 Material 图标，不改变现有 shell 的信息架构。

## Implementation Checklist

- [x] Markdown 本地文件链接可点击，并在应用内打开分屏预览。
- [x] 相对路径、绝对 `file://` 路径、`#L12` 和 `:12:3` 行号可解析。
- [x] 预览路径限制在当前工作区和授权目录内，阻止 `..` 与软链接越界。
- [x] Markdown 支持渲染/源码切换、文档大纲和嵌套文件链接。
- [x] 常见代码、配置、日志、JSON、YAML、CSV 等文本文件支持行号、搜索、换行和指定行定位。
- [x] 图片支持缩放和平移；PDF、Office、iWork、音视频通过 macOS Quick Look 生成只读缩略预览。
- [x] 不支持格式、加载失败和超大文本均有明确降级状态，可复制路径、在 Finder 中显示或用其他应用打开。
- [x] 文件使用标签页复用，最多保留 6 个；分隔线可拖动，窄窗口自动切换为单面板预览。

## Follow-up Polish

- [P3] 如果后续将工作区侧栏做成可收起，可在更宽预览状态下为搜索、复制路径、Finder 等动作补齐常驻文字标签。
- [P3] PDF 若需要逐页浏览，可在 Quick Look 首屏预览之上再接专用 PDF 渲染器；当前常见文件的快速确认场景已覆盖。

## Evidence

- source visual truth path: `/Users/robinfai/.codex/generated_images/019f6ecb-7045-7f00-9feb-5bea889c0f53/exec-01a2b1d1-a9b4-4946-9221-99a42cf09169.png`
- implementation screenshot path: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-pane.png`
- viewport: `1440 x 1024`，Flutter desktop，device pixel ratio 1.0。
- state: 当前工作区存在聊天内容，用户打开一个 Markdown 文件，分屏预览处于“预览”模式。
- full-view comparison evidence: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-comparison.png`
- focused region comparison evidence: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-focused-comparison.png`

## Required Fidelity Surfaces

- Fonts and typography: 保留应用现有 Flutter 字体与字重体系；文件标题、正文、工具栏小字和状态栏层级与参考图一致，未引入额外字体依赖。窄预览中的标题与表格未发生裁切。
- Spacing and layout rhythm: 左侧工作区、聊天区、可拖动分隔线、预览区的比例接近参考图；预览标签、路径、工具栏、正文和状态栏形成稳定的垂直节奏。标准 1440px 窗口下文档大纲可见。
- Colors and visual tokens: 全部使用现有 `AppColors` 的紫色、浅紫选中态、白色表面、冷灰边框和绿色只读安全状态，没有新增渐变或不一致的卡片样式。
- Image quality and asset fidelity: 未伪造图片或图标资产；操作图标来自 Flutter Material。图片和 Quick Look 缩略图使用系统实际渲染结果，并提供缩放。
- Copy and content: 界面文案直接说明动作和状态，包括“预览 / 源码”“用其他应用打开”“只读 · 当前工作区”和超大文件截断提示；没有把设计说明泄漏进产品界面。

## Comparison History

1. 首次实现截图：整体分屏比例、标签、路径、工具栏、正文和底部状态栏已成立，但 635px 预览宽度没有显示文档大纲，和参考图存在 P2 差异。
2. 修正：将大纲展示阈值从 650px 调整为 560px，并把大纲宽度收紧到 150px；同时为聊天和预览内链接补充现有紫色体系的可识别样式。
3. 复核：全图和聚焦对比中，大纲、正文、表格、模式切换与状态栏均完整可见；未发现新的 P0/P1/P2 问题。

final result: passed
