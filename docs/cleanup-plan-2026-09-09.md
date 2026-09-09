# 清理方案：先收拢边界，再删除实现

日期：2026-09-09。基线：`6091b82`。状态：**已实施并通过验收**。执行与验证记录见 [清理验收报告](cleanup-acceptance-2026-09-09.md)。

下文保留方案编制时的取舍与范围；文中的“本轮未执行”指方案阶段。后续执行结果以上述验收报告为准。

本方案承接 [9 月 7 日功能评估](product-review-2026-09-07/README.md)，已重新检查当前工作树。目标是减少无效入口、重复维护和配置分支，保持本地项目会话主流程及新抽离包的可复用能力。范围是产品、源码、依赖、测试和文档清理，不包括删除用户会话、缓存、密钥或磁盘工作区。

## 一、相比上次评估，必须修正的前提

9 月 8 日的 `6091b82` 已抽离 `packages/ianvs_agent_chat`，主应用通过 `AcpChatSession → AgentChatView` 使用共享界面，并在 Agent 菜单接入独立 LLM API 聊天页。不能继续按 9 月 7 日的文件位置执行删除。

| 当前证据 | 对清理的影响 |
|---|---|
| `lib/chat/acp_chat_session.dart` 转发 controller 状态与操作；`lib/ui/shell/app_shell.dart` 使用 `AgentChatView` | 保留适配器；不要把会话生命周期、恢复和权限重新搬入通用 widget |
| 主应用有 27 个不超过三行的包转发文件，另有 ACP 类型别名桥接 | 它们不是两份业务实现；先迁移消费者，最后删无引用入口 |
| `packages/ianvs_agent_chat/lib/mermaid/mermaid.dart` 显式导出 `MermaidExamplePage` | 该类已属于包可访问接口；撤回上次“不区分包边界直接删除”的建议 |
| `docs/agent_chat_module.md` 记录包 0.1.0 已发布，包 README 有公开接入示例 | 按对外接口保护处理；本轮未联网核验发布状态，不依赖远端状态开展清理 |
| `LlmChatPanel` 保存内存会话，关闭时 dispose；主应用默认没有给它注册工具 | 这是新的独立模型聊天入口，不是 ACP 工作区会话恢复链路，也不是已废弃代码 |
| 根 Makefile 的格式检查只指定 `lib test`；CI 只显式运行根 Flutter 测试，没有包/example 独立测试命令 | 清理共享实现前先补各工程测试入口；根测试通过不能替代包消费者验证 |

当前物理行数含空行/注释：主应用 `lib` 112 个 Dart 文件、54,675 行；包 `lib` 48 个 Dart 文件、21,677 行。主应用行数下降主要来自迁移，不能作为复杂度已经消失的证据。

## 二、确定的取舍

| 类型 | 清理对象 | 处理方式 |
|---|---|---|
| 直接清理候选 | 旧 `SessionSidebar`、`WorkspaceHeader`、`StatusBar` | 当前仅定义和各自测试引用；按第二批删除，保留仍有效的行为测试 |
| 纠正/退役 | 静态 Protocol Coverage 完成度与错误功能承诺 | 先修正现状，再移除独立完成度页面；真实 capability 详情保留 |
| 合并 | Activity、Permission History、Runtime Inventory、Compatibility | 合并导航和呈现容器，保持各自数据源、权限语义和保留策略 |
| 迁移后清理 | 转发文件、重复直接依赖、包所属测试 | 按消费者和责任归属逐项迁移，不能按文件名批量删除 |
| 保留高级 | MCP/provider、模板、权限 reviewer、worktree、本地终端 | 收拢入口，不删除能力或配置数据 |
| 保留现状、暂缓扩张 | AI 标题、逐回合总结、LLM API 聊天 | 保留当前边界；助手总开关默认关闭，不增加持久化/新账号体系 |
| 不重新建设 | Memory、Inbox、持久 Task/Workflow、远程 ACP、Registry | 当前未实现或已删除；不为填平旧文案而补建子系统 |

优先清理的是“不能执行却承诺可用”和“已被新实现替代的宿主代码”。可选功能的使用收益尚未验证，不把猜测的低使用率作为立即删除理由。

## 三、实施批次

### C0：建立应用、包、示例的验证边界

**目标：** 后续移动实现和测试时，能证明三个使用面仍然成立。

文件范围：`Makefile`、`.github/workflows/macos.yml`、`tool/flutter_test_isolated.sh` 的调用方式、`packages/ianvs_agent_chat/test`、`packages/ianvs_agent_chat/example/test`。

动作：

1. 为包和示例分别建立 analyze/test 入口，格式检查显式覆盖各自 `lib test`；解析各自依赖和 lockfile，不假设根 pub get 能代替所有工程。
2. 默认运行离线测试。`deepseek_live_test.dart` 的真实请求仍显式启用，不在每次清理回归中使用凭据或产生模型调用。
3. 保留宿主隔离用户 HOME 的既有测试方式。调用现有隔离脚本时选择正确工作目录，避免包测试误落在根项目。
4. 确认现有测试分别覆盖：包的展示/事件路由，ACP bridge 的状态投影，宿主的恢复/授权/队列，以及 LLM 的取消/工具配对/上下文。

验收：CI 日志明确显示三个工程的测试分别被执行，失败能阻断检查；包/example 测试不能是零发现或默认全跳过。根应用真实集成测试继续保留，不以包测试替换。

风险/回退：仅改变验证入口，低风险；单独回退 CI/Makefile 变更即可。**C2–C4 开始前完成 C0。**

### C1：校准能力和文档，停止误导

**目标：** 不增加新能力，也能让产品如实说明现状。

文件范围：`lib/ui/components/protocol_feature_review_dialog.dart`、`README.md`、`docs/product_capabilities.md`、`docs/runtime_architecture.md`、`docs/conversation_loading_architecture.md`、`docs/manual_followups.md`、相关 UI/docs 测试。

当前仍可复核的问题：

- Coverage 仍称远程 Agent 配置后可用，但 `lib/app.dart` 明确返回 unavailable。
- `RustAcpAgentClient.forkSession` 仍 unsupported，产品文档却把 fork 列为交付能力。
- Extension Request 和若干实验协议仍有静态“完成”说明，生产 Rust 命令面不支持。
- 旧文档混写 available commands、目录 SessionInfo、实时 session-info、usage；必须分别追踪 Rust 事件和 Dart 消费，不能按 UI 类型推断。

动作：

1. `docs/product_capabilities.md` 作为主应用现状清单；包能力由包 README / `docs/agent_chat_module.md` 描述。其他文档链接事实来源，不各自维护完成率。
2. Coverage 先改准确：只报告实际实现/Agent 协商结果；去掉静态完成百分比。独立页面在 C4 合并后删除。
3. 配置模型保留旧值读取，但不可用的 transport/MCP-over-ACP 不引导用户创建有效 recipe；显示明确不可用原因，不静默丢弃配置中的条目。
4. `Fork to New Worktree` 与“创建 worktree + 空会话”分别描述；后者继续保留。
5. 把 9 月 7 日评估标明历史基线和本方案后继关系；旧截图评审保持日期，不重写成最新验收。

验收：每个“支持”声明都能定位生产路径；已禁用能力不被显示为可执行；缺失 usage 不填零冒充真实值；slash commands 不因错误旧文档被删。

风险/回退：低到中；若影响现有配置加载，回退配置/UI 校验部分，保留文档事实修正。可以与 C0 同期推进。

### C2：删除确认无生产引用的宿主旧组件

**候选删除清单：**

| 实现 | 关联测试 | 处理要求 |
|---|---|---|
| `lib/ui/components/session_sidebar.dart` | `test/ui/session_sidebar_test.dart` | 删除旧组件和纯旧组件断言；如有当前侧栏仍需要的排序/选择契约，迁到 `workspace_sidebar_test.dart` |
| `lib/ui/components/workspace_header.dart` | `test/ui/workspace_header_test.dart` | 迁移仍有效的工具栏动作/标签要求后删除旧实现测试 |
| `lib/ui/components/status_bar.dart` | `test/ui/status_bar_test.dart` | 不把旧状态栏删除误作 usage 功能删除；当前详情显示由 inspector/共享视图负责 |

本轮已全仓搜索类构造和文件引用，只看到实现、各自测试及历史评审引用。执行删除当天再次检查 imports、exports、harness 和 docs，避免基线后新增消费者。

明确排除：`WorkspaceSidebar`、`AgentToolbar`、`MacosWorkspaceLayout`、`CapabilitiesDialog`、共享包的 `MermaidExamplePage`。最后一项通过包的 Mermaid barrel 导出，即使仓库内没有调用也不能据此证明无外部使用。

验收：没有生产悬空 import/export；当前导航、标题、侧栏快捷键和窄窗口行为保持；运行相关宿主 UI 测试及 analyze。不要为了证明删除另写镜像测试。

风险/回退：低。一个独立提交，回退该提交可恢复；历史文档引用可保留为历史，补基线说明即可。

### C3：完成包迁移后的收尾

**目标：** 一处实现、明确测试归属、最小宿主依赖；不破坏公开包接口。

#### C3a：测试归属

迁到包的候选：渲染预算、Markdown/代码、Mermaid、timeline/prompt 的纯组件行为。涉及 `ChatController`、Rust/FFI、工作区恢复、权限生命周期、原生剪贴板和宿主文件打开的测试继续留在应用。

拆分混合测试文件时保留断言意图；先在包中通过对应行为，再移除根目录的重复部分。包使用通用 `Chat*` 模型及测试用 session，不能反向依赖 `ianvs_acp`。至少保留 ACP 宿主与 LLM 宿主各一组真实共享组件接入回归。

#### C3b：转发文件与类型别名

宿主 import 改为包路径后，逐个删除没有剩余消费者的纯转发文件。优先迁渲染/theme，避免一次性改遍整个 controller。

`lib/acp/acp_input_budget.dart`、`acp_permission_request.dart` 等包含 `Acp* → Chat*` typedef 和函数别名，属于语义兼容桥接，暂时保留。不能用“文件很短”作为删除依据，也不把整个宿主统一改名纳入此次清理。

包内 public import 路径及 barrel 导出保持兼容。若以后要移动到 `src/` 或删除导出，单独设计弃用/版本迁移，不与应用清理混在一个提交。示例和包自述文件继续保留，避免发布包失去独立接入证据。

#### C3c：依赖

本轮对宿主 `lib/test/tool` 的 package import/export 搜索结果：

| 依赖 | 当前使用 | 方案 |
|---|---|---|
| `xml`、`re_highlight` | 未见宿主直接导入，共享包有使用 | 首选移除宿主直接声明的候选；先再查所有受分析源码和 build 脚本，再重解依赖 |
| `desktop_drop` | 宿主测试直接导入 | 测试未迁移前保留直接测试依赖；迁移后再决定宿主是否需要声明 |
| `merman` | 宿主原生 renderer 测试导入；macOS bundle 脚本检查动态库 | 不能仅凭宿主生产 Dart 无 import 删除原生集成；验证插件注册、动态库、包独立 example |
| `mime` | 宿主文件预览使用 | 保留 |
| `flutter_svg` | 宿主 Markdown 图片和预览测试使用 | 保留 |
| `file_picker`、Markdown 相关、`path` 等 | 宿主仍直接使用 | 不因为共享包也声明就去掉宿主直接依赖 |

验收：根/包/example 的依赖解析、静态分析和离线测试均通过；包不 import 宿主；宿主真实桥接契约不变；涉及原生依赖时主应用和 example 的 macOS 构建都验证。lockfile 由对应解析工具生成，不手工删 Pods 或生成插件注册代码。

风险/回退：中。测试迁移、imports 转换、依赖变更分开提交；回退失败子批次，不能靠删测试获得通过。减少行数和转发文件数量不单独作为验收目标。

### C4：合并诊断与设置入口

**目标结构：**

| 入口 | 内容 | 数据边界 |
|---|---|---|
| Agent 菜单 | Agent 选择、认证、管理 | Agent 配置/账号 |
| 会话详情 | 当前项目、模型/模式、有效目录、完整参数 | 当前会话 |
| 活动与诊断 → 事件 | Session Activity | 当前会话活动投影 |
| 活动与诊断 → 权限 | Permission History 与导出 | 保留当前审计范围，不静默改成另一会话 |
| 活动与诊断 → 运行环境 | Runtime Inventory + Compatibility | 实际 recipe、协商能力、降级和脱敏信息 |

文件范围：`lib/ui/components/agent_toolbar.dart`、`lib/ui/shell/app_shell.dart`、`session_activity_dialog.dart`、`permission_history_dialog.dart`、`runtime_inventory_dialog.dart`、`capabilities_dialog.dart`、`protocol_feature_review_dialog.dart`、`workspace_inspector.dart` 及对应测试。

先提取可复用内容，再切换入口，再移除旧弹窗包装。事件、权限和 runtime 数据源可继续独立，不合并成新持久数据库。权限 JSON 导出、空态、范围提示、超时/断线信息仍可访问。只有新容器功能完整后才删除旧路由。

输入区保留常用模型和推理强度快捷选择；完整参数进入会话详情且共用状态。项目菜单和工具栏各有新建入口属于上下文便利，无需机械删重。

Inspector 的“来源”分组可改名或并入详情；它的添加来源回调为 null，而且加号不会渲染，**不是一个可见按钮点击无反应的已确认缺陷**。

验收：在同一会话中能查看事件、权限、运行环境并导出原权限数据；切换/关闭会话不串数据；窄窗口、键盘、Escape、焦点返回正常。前端变化需要实际 macOS 流程验收；此方案没有用静态源码代替该验收。

风险/回退：中。入口与内容迁移同批可逆，保留老数据模型。容器稳定前不同时调整权限匹配或恢复策略。

### C5：可选产品层收拢，作为独立决策批次

| 功能 | 建议默认决定 | 后续删除/扩张条件 |
|---|---|---|
| LLM API chat | 保留包适配器、连接表单和示例；主应用入口下沉到清晰的“独立模型聊天/高级”位置 | 不接入 ACP 历史/工作区权限。若要统一会话产品模型，应单独立项；不能在“清理”中默默加入密钥持久化 |
| AI 标题/逐回合总结 | 维持总开关默认关闭，冻结扩展 | 根据真实复用和额外调用成本决定改按需；删除自动总结时保留旧配置读取和本地标题 fallback |
| 自动 reviewer | 放高级设置，保留默认人工、失败回人工 | 先衡量节省决策与等待。`toolCallId` 当 `toolName` 的规则复用问题独立修，不粗暴放宽匹配 |
| Session Template | 保留读取和选择，展示最终解析目录/MCP/参数 | 有反复手工配置证据再增加 GUI 编辑；目录与全局取并集的现状要明确 |
| 手动终端、worktree | 保留高级入口 | 不与 Agent terminal/fork 混并；无真实使用证据前不扩大后台生命周期或 Git 管理 |

这一批不是 C0–C4 的前置条件。本轮仅梳理方案；这些已实现功能的取舍应作为独立产品变更，具备变更说明、迁移和回归后再实施。

## 四、不纳入清理的内容

- 不删除用户的 `settings.json`、Keychain、会话数据库、转录缓存、工作区索引和磁盘 worktree。
- 不把 50GB 存储配置直接改小并触发自动淘汰；容量策略与显式清理入口另行设计，区分 registry/cache/UI index。
- 不清空 `artifacts/`、旧评审和 example 来获得表面体积下降。可整理目录/标注历史，删除需逐项确认无验收和发布用途。
- 不破坏会话身份/revision、原子回放、会话定向取消、草稿隔离、权限撤销、输入预算、秘密迁移、路径验证和进程回收。
- 不将本地 shell 或 Agent 自身工具宣传为受到完整进程沙箱约束。
- 不在此阶段同时重写 `ChatController` 和 Rust runtime。大文件拆分在产品分支收拢后分责任渐进进行。

## 五、执行顺序与验证清单

推荐顺序：**C0 与 C1 → C2 → C3a → C3b/C3c → C4 → 按需 C5**。每批独立提交、写明实际删了什么和保留了什么，可单独回退。此次不创建 PR 或修改生产代码。

执行阶段命令约定（本轮没有运行这些测试）：

| 工作目录 | 命令 / 检查 | 何时执行 |
|---|---|---|
| 仓库根 | `flutter analyze --no-pub`；`./tool/flutter_test_isolated.sh` | 宿主基线与受影响回归；窄批次先传具体测试路径，完成后跑完整门槛 |
| `packages/ianvs_agent_chat` | `flutter analyze --no-pub`；`../../tool/flutter_test_isolated.sh` | 包实现/测试迁移批次 |
| `packages/ianvs_agent_chat/example` | `flutter analyze --no-pub`；`../../../tool/flutter_test_isolated.sh` | 包公开接口/示例兼容验证 |
| 对应工程 | `dart format --output=none --set-exit-if-changed lib test` | 各工程格式检查 |
| 仓库根 | `make test-rust` | 共享模型、ACP bridge、权限或 FFI 相关变化 |
| 仓库根与 example 各自 | `flutter build macos --debug --no-pub` | 原生依赖或打包内容变化；主界面变化还需真实窗口验收 |
| 仓库根 | `git diff --check`，审阅 diff 与导入/导出残留 | 每批 |

上述 `--no-pub` 前提是各工程已完成依赖解析；C3 修改依赖时先执行各自 `flutter pub get`。新增检查应接入统一验证目标，不让开发者长期记三套手动流程。

完成标准：

1. 不可执行能力不再承诺已交付；ACP 与 LLM 的生命周期/能力边界清晰。
2. 三个旧宿主组件及纯旧实现测试被清理，必要行为在现用组件测试中保留。
3. 共享聊天实现只有一份；测试归属清晰，应用/包/example 都实际执行验证。
4. 仅移除确认无宿主直接用途的依赖；包公开接口和原生库集成保持可用。
5. 诊断入口收拢，原有权限导出和真实运行信息没有丢失；没有新增第二套审计/会话数据模型。
6. 没有用户数据删除、不可逆配置迁移或不相关功能重写。

## 六、本轮方案核验

已检查 `6091b82` 差异、宿主与包的 imports/exports、现有三个旧组件的构造/引用、共享包 public barrel、LLM 入口/释放行为、CI 与测试脚本，以及根依赖的直接使用。上次报告仍未被 Git 跟踪，本轮将保留它们，不视为可删除临时文件。

方案编制时尚未实施；随后 C0–C5 的实际执行与验收见[清理验收报告](cleanup-acceptance-2026-09-09.md)。历史测试数仅对应各自基线，后续残留清理与保留项见[兼容维护方案](compatibility-maintenance.md)。
