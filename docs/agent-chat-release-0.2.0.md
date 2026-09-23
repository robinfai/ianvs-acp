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
- ACP 全仓 analyze 无问题。宿主行为测试仍在完成，后续在此补结果。
- pub dry-run 仅提示未提交文件，提交后需再次确认干净预检。
- 当前 Xcode 要求最低 macOS 12，因此 app/example 与 Pods deployment floor 对齐为 12.0。
- ACP 测试中的 terminal native hook 遇到本机 Rust/Xcode 生成 proc-macro dylib 的 LINKEDIT 对齐问题；兼容 host linker `-Wl,-ld_classic` 在临时编译副本成功。本地生成缓存修复不改变任何发布源文件或 terminal 包版本。

chat 公共发布、独立纯 hosted 安装/构建/启动和 Omnivore 最终集成待后续补充。预发布临时 `/tmp` 验证副本曾消费本地 Markdown 源码；最终 311 项测试与示例构建已经全部切回正式 pub.dev Markdown。Omnivore 从未使用该临时副本或本地 override。
