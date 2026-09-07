# Agent Chat 模块边界

`packages/ianvs_agent_chat` 提供可嵌入的 Flutter 会话界面，同时支持 ACP
客户端投影和 OpenAI 兼容的 Chat Completions 接口。

首版已发布：[ianvs_agent_chat 0.1.0](https://pub.dev/packages/ianvs_agent_chat/versions/0.1.0)。
独立临时宿主已从 pub.dev 安装该版本，公开 UI 和 LLM 接口静态检查通过。

```text
ACP ChatController → AcpChatSession ─┐
                                  ├→ ChatSession → AgentChatView
OpenAI 兼容 API → LlmChatSession ───┘
```

## 独立包负责什么

- 消息时间线、流式文本、Markdown、代码、图片和 Mermaid 展示。
- 输入框、历史提示、工具卡片、执行计划、权限选择和队列展示。
- 中立的消息、能力、会话状态和操作接口。
- 主题、工具展示规则、文件选择和平台服务的扩展接口。
- 可选 LLM 适配器：SSE、内存上下文、取消、工具调用和审批回传。

## 宿主保留什么

本应用继续管理 ACP 子进程、Rust FFI、协议握手、文件和终端回调、
工作区、持久化、恢复事务、队列策略和凭据。`AcpChatSession` 转发状态
和操作，不接管 `ChatController` 的生命周期。

其他宿主可以实现 `ChatSession`，或通过 `CallbackChatSession` 接入现有
控制器。`ChatMessageView` 允许复用已有流式缓冲区；原地更新时必须更新
消息与时间线 revision，切换会话时必须更新 identity。

LLM API 仅提供模型推理。工具执行由宿主显式注册回调，默认先审批。
取消操作会终止当前请求和审批等待；宿主工具需要检查取消令牌，已经
完成的副作用不能被取消操作撤销。

## 生命周期和能力

`AgentChatView` 不销毁传入的会话。宿主负责创建、保留和释放会话实例。
`LlmChatPanel` 是可选的完整接入表单，拥有其内部会话并负责释放。

每个 LLM 会话拥有独立历史和取消令牌。上下文只保留完整成功轮次；
失败和取消内容仍在界面显示，但不会送入下一次模型上下文。裁剪以
完整轮次为单位，保留工具调用和结果的配对关系。

界面按能力显示附件、执行策略、权限和队列操作。LLM 首版支持文本，
可显式启用内联图片；普通文件、音频、服务端恢复和模型发现尚未实现。

## 首版验证

- 主应用完整 Flutter 回归：1,635 项通过。
- 独立包协议及组件测试：16 项通过。
- 示例组件测试：2 项通过。
- DeepSeek 真实测试：多轮记忆、批准加法工具并消费结果，2 项通过。
- 静态检查：无问题。
- macOS 示例：构建和实际启动成功，手动验证发送、审批和回复展示。

DeepSeek 测试通过 `RUN_DEEPSEEK_TESTS=1` 显式启用，从环境变量
`DEEPSEEK_API_KEY` 读取凭据。默认测试不联网；发布归档不包含联调脚本。

macOS 需要 Merman 的 CocoaPods 和动态库路径修正，完整设置见包内
README 与 example。其他平台未完成同等运行验收。首版仅开放主要输入
标签的自定义，完整多语言支持仍需后续扩展。
