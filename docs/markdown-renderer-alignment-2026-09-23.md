# ACP / Omnivore / Markdown 渲染版本协商

> 状态更新：用户后续已要求完成实现并同步 Omnivore，本文的“本轮仅方案、未授权实施/发布”描述保留为前期协商记录，已被后续实施要求取代。实际发布授权与验证证据见 `agent-chat-release-0.2.0.md`。

日期：2026-09-23。状态：Omnivore、ACP、Markdown 三方已确认能力边界与发布顺序，待后续实施；本轮不实现或发布。

本文补充[对话组件统一方案](agent-chat-convergence-2026-09-23.md)。参与任务为 Omnivore `01a0cbe8-4b31-79f3-9408-95820503c855`、ACP `01a0cbea-130b-71a2-8569-5dbd85412e6c`、Markdown `01a0cbda-1723-7331-96f0-84cff0f03438`（“提交并推送代码”）。Markdown 任务独立获授权的 `0.3.0` 发布已完成，本次协商没有改变其发布范围。

ACP 基线为 `9be41c9`，工作树 `/Users/robinfai/.codex/worktrees/ffe1/ianvs-acp`，只读核对主目录 UI 无差异。Markdown 只读检查目录为 `/Users/robinfai/flutter_projects/ianvs-markdown`，观察到 HEAD `d3427f7`、源码版本 `0.3.0`。发布状态由 Markdown 任务另行提供：[`ianvs_markdown 0.3.0`](https://pub.dev/packages/ianvs_markdown/versions/0.3.0) 已发布，[源码标签 `v0.3.0`](https://github.com/robinfai/ianvs-markdown/tree/v0.3.0) 对应提交 `d3427f7eab2f9ff988e854684457bc975cf0121d`，归档 SHA-256 为 `48f434fd90bbc5ce261a592c5666a78beee24105382eac420f40f80df0a45445`。该任务推送了 Git tag，未另建 GitHub Release。ACP 未独立重新下载核验归档，也未重跑该任务的发布验证。

## 1. 共用内核，不迁移会话职责

优先评估现有 `IanvsMarkdown` 只读组件作为公共 Markdown 内核，不预设另拆包或再造公共 `ChatMarkdownRenderer` 接口。`ianvs_agent_chat` 内部用一个薄适配层映射主题、预算和扩展 builder，迁移范围先限消息正文。

依赖版本相同只说明解析到相同库，不能证明选用的语法、预处理、图片策略、复制行为、主题和扩展相同。目标是记录“发布版本 + 实际依赖解析 + 渲染配置 + 场景适配”的兼容组合，并使用相同 fixture 验收。

| 层 | 保留责任 |
| --- | --- |
| `ianvs_markdown` | Markdown 解析/渲染语义、只读正文组件、代码与链接基础能力、通用语法预算、theme/style 与 renderer 扩展点 |
| `ianvs_agent_chat` | 消息与回合 identity/revision、流式合并/保留上限、ChatInputOmission、工具/思考/权限卡、聊天图片解码预算、轮次与滚动；ACP 专属扩展通过 renderer hooks 接入 |
| ACP / Omnivore 宿主 | 链接目标与文件/文章权限、附件来源、业务文档/引用/保存、平台能力、阅读器图片许可与图表后端 |
| Markdown 编辑器 | 光标、输入、文档修改与撤销等编辑职责；聊天正文不创建 editor controller 或 LiveEditor |

阅读器 16.5/1.65 与聊天正文 15/1.58 可作为明确的场景字号/行高配置，不要求它们强制相同；相同内容的文字语义、代码原文和链接目标应一致。两端聊天区域仍遵循原方案的同宽同主题验收。

## 2. 已核对的依赖组合

| 依赖 | ACP 根 lock / chat 声明 | Markdown 当前根 lock | Omnivore 当前 lock（协调方核对） |
| --- | --- | --- | --- |
| `ianvs_markdown` | 尚未依赖 | 已发布 `0.3.0`，对应上文发布记录 | hosted `0.2.0` |
| `ianvs_agent_chat` | 仓库 path，源码标 `0.1.0` | 无依赖 | hosted `0.1.0` |
| `flutter_markdown_plus` | `1.0.7` / `^1.0.7` | `1.0.12` | `1.0.12` |
| `markdown` | `7.3.1` / `^7.3.1` | `7.3.1` | `7.3.1` |
| `re_highlight` | `0.0.3` / `^0.0.3` | `0.0.3` | `0.0.3` |
| `merman` | `0.7.0` / `^0.7.0` | renderer 不内置 Merman | `0.7.0` |
| `flutter_svg` | `2.3.0` / `^2.3.0` | `2.3.0` | `2.3.0` |

Markdown 的 `flutter_markdown_plus ^1.0.7` 允许多个实际版本；库自己的 lockfile 不会替下游锁定解析结果。发布兼容说明需记录最低支持版本和验证过的实际组合；若只在 `1.0.12` 验证，不能把 `1.0.7` 当作已证明兼容。最终由各宿主 lockfile 和 hosted 内容 hash 固定验收组合。

## 3. `0.3.0` 源码已有的最小接口

以下依据 Markdown `lib/src/ianvs_markdown.dart`，不是在 ACP 已完成接入的声明。

| ACP 需要 | 现有接口与接法 |
| --- | --- |
| 无编辑器的正文 | `IanvsMarkdown(data: ...)` 本身是只读 StatelessWidget，传完整 source 快照即可；不需要编辑器或独立滚动容器。 |
| 主题和排版 | `styleSheet`、`theme`；薄适配从 ChatTheme/IanvsTypography 映射，不依赖 Markdown 自带默认色值恰好一致。 |
| 用户软换行 | `softLineBreak` 已存在；ACP user=true、assistant=false，不能直接接受其默认 true。 |
| 选择与复制 | `selectable`、`documentSelection`、`clipboardWriter`、`onSelectionChanged`；第一步可用 `documentSelection:false` 保持当前块级选择，整文档富文本复制另验收。 |
| 链接 | `onTapLink`、`enableFileLinkChips` 及 `builders['a']`；旧 ACP builder 的强调/inline-code 标签防重复逻辑可先保留，不能仅凭同名 chip 判等。 |
| 图片无默认 I/O | 缺省 imageBuilder 返回 blocked 占位；不提供 wikiEmbedBuilder 等资源 resolver。若要原 ACP 占位外观，注入无 I/O builder，并验证其包装交互。附件图片继续使用独立 bounded decoder。 |
| 代码与图表 | `builders['pre']` 最后覆盖默认 builder；`diagramBuilder`、`onCopyCode` 可扩展默认 pre。若保留 ACP pre，Mermaid 必须继续由该 builder 路由，不能假设单独传 diagramBuilder 仍会被调用。 |
| 预算与降级 | `renderBudget`、`fallbackBuilder` 可用；聊天外层 preflight 拒绝后不创建 renderer，公共层若再次拒绝，适配为可见的 ChatInputOmission。 |

`super_clipboard ^0.9.1` 及传递的 `super_native_extensions` 是 Markdown 包当前依赖（本次根 lock 二者均为 `0.9.1`）。自定义 clipboardWriter 只改变剪贴板写入路径，不移除插件的构建依赖；只读 renderer 入口也不等于没有原生传递依赖。ACP 独立 hosted 消费验证必须覆盖这些新增平台依赖，包括目标平台的构建、注册与剪贴板 fallback。无需为此立即拆新包。

## 4. 不能静默改变的行为

**语法预设是当前主要缺口。** `IanvsMarkdown` 的 block/inline syntax 列表始终加入 Obsidian、HTML、math 等扩展，随后执行 Obsidian 预处理与任务/表格投影。`extensionSet: gitHubFlavored` 不能关闭这些额外行为。reading 模式会移除 `%%...%%` 注释和 block ID；editing 模式也不是普通聊天模式，仍有编辑呈现与图像/HTML扩展。

因此 `0.3.0` 现有 hooks 可以支撑 ACP 自有仓库/example 的受控适配验证，但不能直接宣称它是原 `MarkdownBody` 的无损替代。Markdown 维护方已确认此缺口，并认可在后续同包版本提供单个显式 opt-in 语法/预处理 preset，例如标准 GFM 聊天与 Obsidian 阅读；名称与版本号在实施时确定。聊天 preset 应完整选择语法、预处理和默认交互，不要求宿主覆盖十几个 builder，也不改变现有阅读/编辑默认行为。严格兼容所需能力尚未发布，聊天正文切换应等待满足门槛的后续版本。

**预算不只比较默认数值。** ACP `ui/markdown_render_budget.dart` 由 ChatInputBudget 驱动，默认 4096 syntax tokens 与 64 KiB UTF-8 有界降级；消息保留还受 2 MiB/10000 行、思考 512 KiB 等上游限制。Markdown 公共 scanner 默认同为 4096/64 KiB，但额外计算 `$`，与新增 math 语法相关。初期保留两层检查及各自降级理由；不能设 `renderBudget:null` 后让旧 scanner 未覆盖的新增语法绕过检查。将来只有语法和 exact-boundary fixture 对齐后才合并扫描算法；Chat 的总量预算和 omission 语义继续留在 Chat。

**流式更新仍需专项验收。** `data` 更新会重新解析，不等于已有增量 AST 或流式性能保证。Markdown 文档级 selection 在 source 改变时清选择状态；不能把默认 `documentSelection:true` 当作 token 更新时保持选择的证明。保留消息 widget identity，测试未闭合 fence、同长替换、分片 Unicode、source 改变时旧图表结果失效及滚动锚点；不把这些职责转给编辑器。

**代码与图表分步收敛。** ACP 现有代码 UI 包括原文复制、语言 alias、横向滚动/换行、长代码折叠与浅深色高亮；高亮上限为 200 Ki UTF-16 code units/2000 行，cache 为 64 项/1 Mi code units。Markdown 暴露同类 builder、`collapseLongBlocks` 等，但默认表现不同，需同 fixture 验证后才移除 ACP 覆盖。

ACP Mermaid 使用 Merman、resvg-safe、CSS normalization、source 512 KiB/SVG 8 MiB 限额，缓存键含 source/options/engine version，native 动态库还有 CocoaPods/签名要求。先保留 ACP Mermaid renderer，通过 pre 或 diagram hook 接入。Omnivore 阅读器当前未传 diagramBuilder，即使依赖里有 Merman，也不等于阅读器已有同一图表行为；阅读器补齐 adapter 后才可以验收图表一致。平台不支持时保留可复制原始 fence 或明确降级，不能丢图表源码。

## 5. 发布与消费顺序

1. Markdown 的独立 `0.3.0` 发布已完成；本次聊天 profile 不在该版本内。Omnivore 阅读器升级 `0.3.0` 可单独验收，不能据此宣称聊天渲染已同步；当前任务不代为执行升级。
2. ACP 在自有仓库/example 对已发布 `ianvs_markdown` 做薄适配验证；保留原有预算、builder、Mermaid 与聊天状态。发现必须由公共包解决的缺口，先由 Markdown 后续版本发布并完成独立 hosted 消费验证。
3. ACP 消费满足门槛的已发布 renderer，完成消息/平台回归后发布新的 `ianvs_agent_chat`。其依赖声明不能指向未发布 Markdown 源码；干净 hosted 消费项目确认兼容组合。
4. Omnivore 最后同时升级所需的已发布 Markdown/chat 版本及 lockfile，再做阅读器与聊天适配验收。开发、测试、交付均保持 pub.dev；不得使用 path、Git 或 dependency_overrides。

同步的是兼容组合，不要求两个包使用相同版本号。阅读器已有 `ianvs_markdown` 直接依赖、chat 未来也会间接依赖它，最终 Omnivore 解析出的单一版本须满足两者约束，并覆盖双方场景 fixture；不能只验证依赖求解成功。

`^0.2.0` 不会自动进入 `0.3.0`，`^0.1.0` 也不会自动进入 chat 的未来 `0.2.x`；每次升级需显式更新约束并审阅 lockfile。后续 renderer 版本记为 M、chat 版本记为 C：满足 profile/fixture 的 M 发布 → chat 消费 M、验收并发布 C → Omnivore 从 pub.dev 升 M/C。三方已确认此顺序，不以源码版本代替发布边界。

## 6. 合并到三方验收的门槛

三方共用一份带版本和 hash 的源文本与语义断言 fixture 契约，在兼容组合记录中同时固定 fixture 版本、依赖解析、profile 和平台。golden 按宿主声明的字体/主题生成；不把不同场景密度误判为解析漂移。流式选择保留等条目是后续目标，不是 `0.3.0` 已经提供的集成保证。

| Fixture / 检查 | 必须保留的结果 |
| --- | --- |
| 普通 GFM、链接、表格、用户软换行 | 文字、链接目标、表格结构和换行一致；场景字体密度差异显式配置。 |
| `%%...%%`、block ID、wiki/tag、`$`、HTML input/button | 按声明的 chat/reading profile 解释；聊天迁移不能静默隐藏内容或新增可编辑控件。 |
| 代码与未闭合 fence | 原始复制、缩进/末尾换行、alias、高亮/纯文降级、窄宽 wrap/scroll、流式片段最终结果均有回归证据。 |
| 链接标签含 emphasis/inline code | 不重复标签，不失去目标和可访问语义；文件 chip 不改变宿主实际导航。 |
| Markdown 图片、HTML/wiki 嵌入、附件图片 | Chat 的任意资源路径都不触发未经宿主允许的 I/O；独立附件预算仍生效；Reader 使用其明确的图片策略。 |
| 预算 exact/plus-one、emoji/无效 surrogate、math | 拒绝发生在完整解析前，UTF-8 截断完整，typed omission 可见，无双层扫描导致的含糊提示；不通过关闭预算来通过测试。 |
| 流式 source 更新、选区、图表迟到结果 | 不串消息、不覆盖新版本、不抢阅读位置；selection 和代码折叠状态变化有明确约定和测试。 |
| Mermaid | 同 source/options/backend 的输出、主题和错误降级一致；无后端时可读可复制；真实 macOS native build/sign 与窄屏显示另验收。 |
| hosted 兼容组合 | 记录 renderer/chat 发布版本、底层解析版本/hash、profile、主题与平台；Omnivore 全程 pub.dev，独立消费不依赖本机路径。 |

ACP 本轮只读源码和现有测试：`test/ui/markdown_render_budget_test.dart`、`markdown_code_block_test.dart`、`chat_timeline_test.dart` 以及 `test/mermaid/`；没有运行这些测试或实现 renderer 替换。Markdown 中的未闭合 fence 等已有测试是候选依据，不代表 ACP 流式集成已通过。

## 7. 三方互审记录

- Markdown 方已只读互审本稿并认可 `0.3.0` 的图片零默认 I/O、builder 覆盖顺序、selection/softLineBreak/theme/budget 等现成接口；确认没有纯 GFM/chat preset，也没有通用 streaming revision/异步取消协议。后续方向已认可，尚未承诺具体实现时间或版本号。
- 三方认可同包后续 opt-in preset、保留 Chat 专属预算与 typed omission、先量化 code/link 差异再收敛公共实现；不把 ACP 状态模型移入 Markdown。
- ACP 已只读互审 Omnivore `docs/markdown-rendering-version-sync-2026-09-23.md`，确认主题密度、图表接线、原生依赖和 M→C→Omnivore 发布链；实际恢复事务/持久化仍由宿主负责。
- Markdown 发布任务报告工具链 Flutter `3.44.2 stable` / Dart `3.12.2`，格式检查、三处 analyze、937 项测试及发布 dry-run 0 warnings；未测试 `flutter_markdown_plus 1.0.7` 最低组合，也未运行新的独立 hosted ACP/Omnivore 原生消费测试。该证据属于其独立发布，不代表 ACP/Omnivore 新组合已测试；本轮 ACP 只修改方案文档。
