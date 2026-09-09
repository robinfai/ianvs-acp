# 改版验证基线与缺口

日期：2026-09-09。**历史基线说明**：本文记录改版前的覆盖与缺口，T01–T08 的最终通过结果见 [验收结果](acceptance.md)。在等待布局选择时完成源码与已有测试覆盖核对；本文没有把运行历史当成本轮测试通过，也没有提前实现任何一种布局。

## 已有证据的适用范围

上一轮 [verification.txt](../../artifacts/cleanup-2026-09-09/verification.txt) 记录 `make verify` 成功，app 1368、共享包 283、example 2 项通过，另有 Rust、FFI、原生与构建验证。这是上一轮清理的历史结果。本轮新增的是截图 fixture 的 1 项通过；本轮尚未执行产品重设计后的测试。

下面核对的是实际测试内容与断言，不只按测试名称推测覆盖。最终改版后必须运行受影响测试，并补上确有行为变化或缺口的验证；不需要为分类标题或颜色逐项创建镜像实现的测试。

| 契约 | 当前测试证据 | 能证明 / 不能证明 |
| --- | --- | --- |
| 修改默认 Agent 经外层保存提交 | [acp_client_app_test.dart](../../test/ui/acp_client_app_test.dart#L824) | 断言保存的默认值和新建弹窗可见 Agent；没有建立活动会话或模拟保存失败，不能证明会话无中断 |
| 相同运行配方共享底层客户端 | [acp_client_app_test.dart](../../test/ui/acp_client_app_test.dart#L968) | 更新父配置后 factory 只调用一次且 client 未 dispose；这不代表 ChatController 与前台会话状态不变 |
| 存储配方改变需替换客户端 | [acp_client_app_test.dart](../../test/ui/acp_client_app_test.dart#L1002) | 修改容量/配置路径后旧 client 被释放；支持真实生效提示，不能改写为“仅下次启动” |
| 配置路径缺失不能保存 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L457) | 主 Save 禁用；重设计必须保留配置不可写和启动失败恢复路径 |
| 字段无效不会提交 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L484) | reviewer timeout 非整数时 writer 未调用、错误可见；未证明跨分类错误能正确定位 |
| 旧 remote ACP 与 MCP-over-ACP 保留 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L523)、[同文件 MCP 覆盖](../../test/ui/agent_config_dialog_test.dart#L851) | 已有值可编辑并保留，新建不提供不可用类型；改版不能过滤删除这些对象 |
| reviewer 关闭配置透传 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L1018) | 保存保留 `enabled=false` 和目标名；没有证明 runtime 完全不提供 reviewer，实际存在当前 Agent 回退 |
| 密钥显式修改意图 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L1060) | 修改后恢复原值仍保留 `explicitEnvKeys`；该意图不在普通 `toJson()` 中，单纯 JSON 相等判断不能覆盖 |
| Agent 重命名保留 reviewer 密钥待重新绑定 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart#L1161) | 保留 inline reviewer 的值与重命名结果；配合迁移层处理 owner/target 变化，不能直接复制引用 |
| 未知字段和模板继承保留 | [acp_config_store_test.dart](../../test/config/acp_config_store_test.dart#L112)、[模板缺省字段](../../test/config/acp_config_store_test.dart#L276)、[显式空权限覆盖](../../test/config/acp_config_store_test.dart#L344)、[未知嵌套字段](../../test/config/acp_config_store_test.dart#L443) | writer 合并与序列化契约已有直接断言；尚需在新表单跨分类编辑后确认这些数据到达 writer |
| 密钥保存事务 | [acp_config_secret_migrator_test.dart](../../test/config/acp_config_secret_migrator_test.dart#L187)、[原子写失败](../../test/config/acp_config_secret_migrator_test.dart#L212)、[提交后清理失败](../../test/config/acp_config_secret_migrator_test.dart#L628) | 含写入失败恢复与已提交配置报告；UI 不能把“已提交但清理失败”当成未保存并重复重建 |
| 大量动态参数不会一次构建 | [session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart#L37) | 1024 项首屏少于 32 项构建，滚动可到末项；新布局需保留惰性列表，不得改为全部展开 Column |
| 参数投影缓存 | [session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart#L82) | 未变列表重建读取量小于 128；改版需保留投影依赖与缓存，不能每帧重扫 |
| 大选择集搜索与预算 | [session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart#L184) | 搜索命中第 1024 个 choice、提交正确值、说明按预算截断；不能换成无界 Dropdown |
| 选择器关闭生命周期 | [session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart#L269)、[父窗口卸载](../../test/ui/session_settings_dialog_test.dart#L329) | 操作禁用/父窗口卸载时子选择器关闭，避免迟到提交；移动页面时仍需满足 |

## 本轮新增的必要交互契约

| 编号 | 当前不足 | 改版后需要的可观察结果 |
| --- | --- | --- |
| T01 草稿流转 | 当前无分类状态，也没有完善的脏状态离开处理 | 修改 Agent、切分类和切对象后回到原处，值仍在；放弃会还原；取消离开会继续编辑；不触发 writer |
| T02 无改动保存 | `_canSave` 只检查 callback、路径和 saving | 无实质更改不保存/重载；普通字段恢复原值后可清除脏状态；密钥的显式重新输入意图必须另外保留 |
| T03 保存中关闭 | [当前 Close](../../lib/ui/components/agent_config_dialog.dart#L302) 不检查 `_saving`；writer 已开始后关闭窗口不会取消写入 | 保存开始后窗口退出/返回的行为明确，不能让用户误认为已取消持久化；避免重复点击提交和窗口卸载后的伪成功反馈 |
| T04 保存失败恢复 | `_save` 已捕获异常，但缺少完整交互验收 | 模拟 writer 失败：全部草稿保留、saving 清除、错误定位、可修改后重试；提交后清理警告明确显示已保存 |
| T05 活动操作保护 | 保存链路未按现有活动会话决定是否可应用 | 其它会话正在 streaming/创建/恢复时不允许会中断其 controller 的保存；状态改变时禁用说明更新，最终提交入口仍复核 |
| T06 作用域表述 | 默认、当前、编辑中 Agent 相邻；五类 model 语义不同 | 每个标签能指出所有者；新建会话默认继承当前 Agent 的行为与“启动默认”不混淆 |
| T07 参数与生命周期分离 | Session Settings footer 仍有 fork/close/delete | 参数窗口只含参数与刷新；能力支持的关闭/删除能在相同目标会话菜单到达，危险确认保留；当前不支持的操作不出现 |
| T08 内层编辑一致性 | Agent/MCP 有子弹窗 Save 与外层 Save | 选择布局后，无论使用行内或主从编辑，都只有一个清楚的持久化提交点；保留新增/删除/默认/旧类型等全部现有操作 |

以下是改版前提出的要求；现在 T01–T08 已按 [最终验收表](acceptance.md) 完成。测试设计应围绕这些用户可见结果，避免为了匹配某张草图写只检查组件层级的脆弱测试。

## 完成门槛

选择布局 → 实现完整设置分类与入口 → 运行相关配置/UI/app 回归及必要新增用例 → 分析与格式检查 → 真实 macOS 窗口操作 → 同状态设计/实现截图并列与标注。任何一步缺失，都不能把本轮目标标为完成。
