# 技术设计

## 技术决策

采用 Swift 原生 macOS 应用。SwiftUI 承担设置和记录界面，AppKit 承担菜单栏、浮层与窗口行为。第一版不引入 Rust、WebView 或 Node 常驻服务。

生产存储采用 SQLite 元数据与独立附件目录；交互原型采用原子写入的 JSON，不能视为生产级 outbox 或跨进程幂等实现。

## 模块

| 模块 | 责任 |
|---|---|
| Capture | 全局输入、目标窗口快照、截图、坐标转换 |
| Resolver | AX/OCR 线索、渠道消息定位、候选与置信证据 |
| SourceAdapter | 微信 / 飞书 / 钉钉查询和规范化 |
| DraftBuilder | 动作模板、项目映射、上下文边界、确认内容 |
| TaskCoordinator | 去重、逐轮提交、持久化队列、恢复 |
| ExecutorAdapter | 启动、查询、续接、取消、执行事件 |
| RecordStore | 原始材料、提交快照、事件、产物和关联 |
| Presentation | 轮盘、确认卡、任务列表、配置 |

仅在用户触发或活跃任务需要更新时工作；后台定时器有明确生命周期。

## 原生系统能力

- 输入手势：评估 CGEventTap，回调仅记录输入，不在回调执行截图或 CLI。
- 窗口和元素定位：系统窗口信息 + Accessibility。应用可能不暴露消息文本，必须有降级路径。
- 截图：ScreenCaptureKit，隐藏/过滤本应用覆盖层；单次捕获，不建立永久录屏。
- OCR：优先评估系统 Vision，遇到无法解析的目标交给执行器进一步分析。
- 多显示器：统一屏幕 ID、逻辑坐标、像素坐标与缩放，不直接混用 NSEvent 与截图像素位置。
- 权限：辅助功能与屏幕录制分别检测；拒绝时给出明确降级，不循环弹窗。

最低系统版本暂定 macOS 13；具体截图 API 可用性需要做版本分支或提高最低版本。本机已安装的 SDK 编译通过不代表 macOS 13 实机兼容已验证。

## 渠道接口契约（设计，非现有 API）

`resolve(capture) -> candidates`

`context(anchor, budget) -> ContextBundle`

`capabilities() -> identity / freshness / media / thread`

ContextBundle 包含：

- platform、accountID / tenantID、conversationID。
- messageID（平台稳定 ID 或明确注明范围的复合键）。
- sender、time、text、quotes、attachments。
- 数据来源、本次读取时间、是否完整、截断原因。
- 本地缓存新鲜度及消息是否尚未落盘。

微信使用 wxview 的 contacts / search / messages；不推进共享 new-messages checkpoint。缺密钥或缓存不能视为没有消息，也不能自动初始化。建议未来为 wxview 增加按锚点取前后消息的接口。

飞书、钉钉使用已授权 CLI 的结构化输出。参数使用独立 argv，禁止拼接 shell 命令。每次操作固定账号/组织，不跨 profile 混用 ID。

## 执行器接口契约（设计）

`submit(Submission) -> accepted(externalID) | rejected | unknown`

`resume(externalID, Submission) -> ...`

`observe(externalID) -> events`

`cancel(externalID) -> supportedResult`

适配器声明能力：幂等键、恢复查询、事件流、取消、图片输入、工作目录、原生客户端可见性。

Codex 评估本地 App Server 接入，避免为了 SDK 再捆绑 Node。与用户已有桌面线程是否能互通，必须单独验证，不能默认。

WorkBuddy 评估官方本地助理 API；需要第三方应用及 OAuth。官方流程涉及的应用 secret 不嵌入桌面包，应通过合适的后端交换或平台正式支持的公共客户端流程解决。云端任务不能直接访问本机 wxview 和仓库。

平台缺少能力时呈现“未支持 / 待核对”，不以模拟事件补齐真实状态。

## 数据模型

- Capture：原始截图引用、坐标、窗口身份、时间。
- SourceAnchor：平台、账号、会话、消息标识、定位依据。
- IntentDraft：动作 ID、模板版本、项目、执行器、补充说明。
- Task：内部 ID、源消息关联集合、外部会话/任务 ID。
- Submission：taskID、revision、冻结 payload、payload hash、operationID。
- Event：本地单调序号、外部 eventID、时间、阶段、脱敏详情。
- Artifact：类型、位置、来源轮次、可用状态。

截图和原消息是捕获快照；后续刷新内容追加版本，不覆盖旧证据。展示“执行器报告完成”和“已验证”两个不同状态。

## 实现边界

生产数据库需要事务、唯一约束和 outbox；原型只用于规则和交互评审。
配置变化不能改变已经确认的 Submission。事件按外部 ID 去重；无 ID 时按适配器明确规则处理。
对持续输出设置容量与截断策略，按需展开，避免保存无限日志。

## 来源

- lolPing：https://github.com/darrenprx/lolPing
- Apple ScreenCaptureKit：https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple Accessibility：https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- Codex App Server：https://learn.chatgpt.com/docs/app-server
- WorkBuddy Open API：https://open.workbuddy.cn/docs/openapi

外部接口以集成时官方契约为准，本轮没有进行真实账号接入验证。
