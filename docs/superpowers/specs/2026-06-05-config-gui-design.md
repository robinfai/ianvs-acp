# 配置 GUI 补齐设计

日期：2026-06-05

## 背景

`~/.config/ianvs-acp/settings.json` 已支持 agent、MCP、额外目录、client providers、权限规则和审查 agent 等配置。当前应用里的 `Agent Configuration` 主要用于查看配置，用户仍需要改 JSON 才能完成大多数配置。

本次目标是让已经落入配置文件的配置，都能通过 GUI 完成新增、编辑、删除和保存。JSON 文件仍是持久化格式，但不作为用户操作入口。

## 范围

补齐以下 GUI 配置能力：

- `default_agent_server`：选择启动默认 agent。
- `agent_servers`：新增、编辑、删除 stdio/custom、WebSocket、HTTP/SSE agent。
- `agent_servers.<name>.review_agent`：配置该 agent 的审查模型和可选审查目标。
- `mcp_servers`：新增、编辑、删除 stdio、http、sse、acp MCP server。
- `additional_directories`：新增、删除绝对路径。
- `client_providers.filesystem`：开关读文件、写文件、允许读取工作区外路径。
- `client_providers.terminal.enabled`：开关 terminal provider。
- `client_providers.permissions.trust_rules`：新增、编辑、删除自动允许或拒绝规则。
- `client_providers.permissions.review_agent`：配置全局审查 agent、tool、model、timeout。

不做这些事：

- 不把运行中的 session 配置写回全局默认配置。
- 不实现 ACP Registry 导入。
- 不实现长期权限审计保存。
- 不新增 live terminal 面板。

## 界面设计

沿用当前 `Agent Configuration` 弹窗，不新增独立页面。弹窗从只读信息面板升级为可编辑配置窗口：

- 顶部显示配置文件路径、读取状态和保存状态。
- 主体使用四个分区：Agents、MCP Servers、Directories、Client Providers。
- 每个分区保留当前卡片式密度，但增加 Add、Edit、Delete、Set Default 等明确按钮。
- 新增或编辑复杂对象时打开子弹窗，避免在一个大弹窗里塞太多输入框。
- args、env、headers、trust rules 使用一行一项的表单，而不是 JSON 文本框。
- env 和 headers 的值默认遮挡，可以切换显示；保存时保留完整值。

### Agents

Agent 列表展示名称、类型、目标、默认状态、当前状态。操作包括：

- 新增 agent。
- 编辑 agent。
- 删除非当前使用中的 agent。
- 设置默认 agent。

编辑表单按类型切换字段：

- stdio/custom：name、type、command、cwd、args、env、review model。
- websocket：name、type、url、headers、review model。
- http/sse：name、type、url、headers、review model。

### MCP Servers

MCP 列表展示名称、类型、目标和 header/env key。操作包括新增、编辑、删除。

编辑表单按类型切换字段：

- stdio：name、command、args、env。
- http/sse：name、url、headers。
- acp：name、id。

### Directories

额外目录用路径列表呈现。用户可以新增或删除目录。新增时要求绝对路径，保留当前输入式路径补全的简洁风格。

### Client Providers

Provider 配置使用开关和小表单：

- 文件系统：读文件、写文件、允许读取工作区外路径。
- Terminal：启用 terminal provider。
- 权限规则：按 tool name、可选 tool kind、decision 编辑。
- 审查 agent：启用、选择内联 MCP server 或已有 MCP server 名称、tool name、model、timeout。

## 保存行为

保存时读取当前配置文件，合并 GUI 管理的字段，并保留未知顶层字段。写入后重新解析配置，刷新当前 app 状态和 controller 缓存。

当 `configPath` 不存在时，保存会创建父目录和 `settings.json`。当 `configPath` 解析不到时，配置窗口显示不可保存状态。

当用户编辑会影响当前 agent 或 provider 的字段时，保存后应用立即使用新配置；已有 session 不强制关闭。

## 校验和错误

表单校验复用现有配置解析规则：

- agent 和 MCP 名称不能为空。
- stdio/custom 必须有 command。
- remote agent 必须有符合类型的 URL。
- additional directories 必须是绝对路径。
- header 名称必须合法，值不能为空。
- review timeout 必须是正整数。
- trust rule decision 只能是 allow 或 deny。

保存失败时保留弹窗和草稿，在顶部显示错误，不丢用户输入。

## 测试

新增或更新测试覆盖：

- 配置模型可以把 GUI 草稿写成现有 `settings.json` 结构。
- 保存时保留未知字段，并能创建新配置文件。
- Agent 配置窗口能新增、编辑、删除 agent，并设置默认 agent。
- MCP、额外目录、provider、trust rules 和 review agent 都有可操作控件。
- 无效输入会阻止保存并显示错误。
- 保存后 app 使用新的配置刷新可选 agent、MCP 和 provider 状态。

## 已确认选择

采用“升级当前 Agent Configuration 弹窗”的方案。它比只加零散编辑按钮更完整，也比新建设置页更贴合当前应用结构。
