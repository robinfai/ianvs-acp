# Agent Chat 0.2.0 实施与发布记录

用户已要求完成 ACP 更新并同步 Omnivore；Omnivore 的开发、测试和交付始终只消费 pub.dev 包。

## 实施内容

- 共享 `ChatComposerController` 管理正文、selection、真实焦点与 revision；新逻辑会话清理复用草稿，配置、权限、后台首次创建保持身份。
- `ChatSubmissionSession`、不可变 `ChatSubmission`、三态 `ChatSubmitResult` 和 `ChatSubmissionLedger` 明确接收边界；待接收防重发，拒绝/异常保稿，旧回执不清新草稿。legacy send 完成时机保持不变。
- ACP 映射真实接收/队列结果，首次后台创建保持身份，流建立前失败撤销未接收用户占位；LLM/example 接收后后台生成。
- 完整 typed config options 菜单，包括 mode、boolean 与分组选项；高级菜单根据剩余空间弹出并限高。
- composer 使用共享内容宽度和局部高度；320/360/420/600/620/900 × 400/560/800 布局；上滚暂停流式跟随、返回最新恢复。
- 无原生 factory 的宿主默认 Flutter semantics；ACP 显式 `ChatNativeTextFieldScope` 使用已注册代理。
- Markdown 使用 `ianvs_markdown 0.3.1` standard GFM；预检与内部 renderer 使用相同 scanner/budget。保留 chat pre/a/image hook、代码复制/折叠、Mermaid 及 host 链接。
- 原始 HTML 遵循上游 GFM，不承诺全部逐字显示。保留 block selection，完整答案复制由宿主管理。

## 上游制品

- Markdown：`0.3.1`，提交 `33ed67f8396f7bb7c596970afbefb0bab1b76ef4`。
- 官方 archive SHA-256：`39ec2c1d76e44bdfd2c6092b5673e1465b31562c2fa9c402f19b2107a209e126`。
- standard fixture contract v1 SHA-256：`ea194f908f8ce822a8ecf036c4adaec8f33e5acfb18a29b08b0abdc5948b18e7`。
- 解析：`flutter_markdown_plus 1.0.12`、`ianvs_design 0.4.0`；runtime 无需升级，Omnivore 继续 hosted `0.1.0`。
- Markdown 发布曾被自动审批拒绝；用户在 ACP 任务明确批准“发布 Markdown 0.3.1 并推送”后由原任务完成发布。

## 已完成验证

工具链：Flutter 3.44.2 / Dart 3.12.2，macOS，Xcode 27。

- 共享 chat 全量：311 项通过，2 项真实服务测试按既有开关跳过；analyze 无问题。
- standalone example：2 项通过；macOS debug app 成功构建，包含 Markdown 新增原生插件。
- ACP 全仓 analyze 无问题；controller、admission、shell 与 new-session 共 330 项通过，macOS debug `Shift.app` 构建成功。
- 发布候选提交 `11718924b524660a28c95ceddba4d886410dcba6`；提交后的 pub dry-run 零警告。
- 当前 Xcode 要求最低 macOS 12，因此 app/example 与 Pods deployment floor 对齐为 12.0。
- ACP 测试中的 terminal native hook 遇到本机 Rust/Xcode 生成 proc-macro dylib 的 LINKEDIT 对齐问题；兼容 host linker `-Wl,-ld_classic` 在临时编译副本成功。本地生成缓存修复不改变任何发布源文件或 terminal 包版本。复制兼容宏时需保留新的输出时间戳，否则 Cargo 会再次生成不兼容的宏；完成后原始 Flutter host 测试和 build 均已成功。

- 使用原生 macOS 示例（无 ACP factory）实际输入 hello、Enter 提交，在权限等待期间输入 next draft，再 Allow once。实际界面显示“5 characters”，下一份 next draft 保留；未调用真实模型或网络。

## 正式发布

- 用户在 Omnivore 原任务明确授权 Chat 0.2.0 发布并推送分支/tag；核对原始授权及候选包树后执行。
- [ianvs_agent_chat 0.2.0](https://pub.dev/packages/ianvs_agent_chat/versions/0.2.0) 已于 `2026-09-23T02:55:35.158347Z` 发布。
- 官方 archive SHA-256：`f037315173ba5b0db309c963d44e282c001a505739790846872d2cd8bcd31bbe`；下载归档后校验哈希，并确认全部 52 个 lib/元数据文件与获授权提交完全一致。
- 分支 `codex/agent-chat-0.2.0` 已推送；[标签 ianvs_agent_chat-v0.2.0](https://github.com/robinfai/ianvs-acp/tree/ianvs_agent_chat-v0.2.0) 指向 `11718924b524660a28c95ceddba4d886410dcba6`。
- 独立消费者 `/tmp/ianvs-agent-chat-hosted-0.2.0` 使用精确 hosted `ianvs_agent_chat: 0.2.0`，无 path、git 或 override；lock 和 package config 中 Chat/Markdown/design 均来自 pub.dev，Chat/Markdown 哈希匹配官方归档。
- 独立消费者 `flutter analyze --no-pub` 无问题，2 项示例测试通过，`flutter build macos --debug --no-pub` 成功。
- 实际启动该消费者的 macOS app（无 ACP native factory），输入 hello 后提交，在工具审批期间输入 next draft，再允许一次。界面显示 5 characters，next draft 保留；原生插件与输入正常启动。此验证仅使用本地 demo。
- 已独立只读核验 Omnivore `apps/client/pubspec.yaml`、lockfile 与 package config：Chat 0.2.0、Markdown 0.3.1、design 0.4.0、runtime 0.1.0 均为 hosted pub.dev；两个新版本的归档哈希匹配官方，无 override。

## Omnivore 同步

- 文档助手接入共享 `AgentChatView`、composer/controller 与 typed config 菜单；宿主保留文章引用、Agent 选择、答案另存和文档业务动作。
- `DocumentChatSession` 实现 opt-in submission；生成自动保存仍等待原有 send 完成。引用快照按 session、正文 revision 与 quote revision 清理。
- 交互测试覆盖拒绝保稿与引用、IME、接收清理和权限期间下一份草稿；开启 semantics 的 24 种组合（6 个宽度 × 2 个高度 × 2 个主题）通过。
- 15 项正式 hosted Chat/Markdown 共享契约测试通过，使用相同 contract v1 fixture/hash。
- macOS arm64 Debug 构建成功。Omnivore 保持原 deployment 配置；为适配本机 Xcode 27，仅此次构建命令覆盖 `MACOSX_DEPLOYMENT_TARGET=12.0`。
- 客户端全量 `flutter test --no-pub --reporter expanded`：135 项通过、3 项跳过；`flutter analyze --no-pub` 无问题。
- 6 张宿主截图通过检查：浅色/深色 620 宽、浅色 360 宽的聊天区与配置菜单，位于 Omnivore `docs/agent-chat-acceptance-2026-09-23/`。本任务独立查看浅/深色 620 聊天截图，确认正文、表格、代码、引用、输入及保存入口正常显示。
- 只读核对两端主题来源一致：hosted example 的 `IanvsTheme.light()/dark()` 调用同一 `IanvsTheme.build`；Omnivore 使用该 build 与默认 `ChatThemeData`（正文 15、内容最大宽度 800、当前 Ianvs tokens）。
- Omnivore 已完成源码和正式依赖同步；本次未安装或发布 Omnivore 应用。其现有其他工作区改动由原任务保留。

预发布临时 `/tmp` 验证副本曾消费本地 Markdown 源码；最终 311 项测试与示例构建已经全部切回正式 pub.dev Markdown。Omnivore 从未使用该临时副本或本地 override。

验证范围：以上原生交互使用本地 demo，不代表真实模型服务、完整 VoiceOver 或 iOS 真机验收。
