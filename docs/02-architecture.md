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
| DraftBuilder | 动作模板、上下文边界、确认内容 |
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

Codex 首版按用户决策采用 tmux + Codex CLI，保存 session 并提供 CLI 找回入口，不接 App Server、不捆绑 Node。实现契约见 [CLI 交接](06-codex-cli.md)。与用户已有桌面客户端是否互通必须单独验证，不能默认。

WorkBuddy 评估官方本地助理 API；需要第三方应用及 OAuth。官方流程涉及的应用 secret 不嵌入桌面包，应通过合适的后端交换或平台正式支持的公共客户端流程解决。云端任务不能直接访问本机 wxview 和仓库。

平台缺少能力时呈现“未支持 / 待核对”，不以模拟事件补齐真实状态。

## 数据模型

- Capture：原始截图引用、坐标、窗口身份、时间。
- SourceAnchor：平台、账号、会话、消息标识、定位依据。
- IntentDraft：动作 ID、模板版本、执行器、补充说明。
- Task：内部 ID、源消息关联集合、外部会话/任务 ID。
- Submission：taskID、revision、冻结 payload、payload hash、operationID。
- Event：本地单调序号、外部 eventID、时间、阶段、脱敏详情。
- Artifact：类型、位置、来源轮次、可用状态。

截图和原消息是捕获快照；后续刷新内容追加版本，不覆盖旧证据。展示“执行器报告完成”和“已验证”两个不同状态。

## 实现边界

Codex 初次提交已采用独立 SQLite 占用表、唯一约束及 queued / dispatching 恢复；任务元数据仍为 JSON。全量事务化任务存储仍待后续迁移。
配置变化不能改变已经确认的 Submission。事件按外部 ID 去重；无 ID 时按适配器明确规则处理。
对持续输出设置容量与截断策略，按需展开，避免保存无限日志。

## 来源

- lolPing：https://github.com/darrenprx/lolPing
- Apple ScreenCaptureKit：https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple Accessibility：https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- Codex App Server：https://learn.chatgpt.com/docs/app-server
- WorkBuddy Open API：https://open.workbuddy.cn/docs/openapi

外部接口以集成时官方契约为准，本轮没有进行真实账号接入验证。

## wxview 当前实现（第一期 A）

`SourceAdapter/WxviewAdapter.swift` 使用 Foundation Process 和独立参数数组，在后台运行并限制时间、输出体积。`Presentation/WeChatSourceView.swift` 串行处理用户触发的检查、候选和消息查询；空闲不启动 CLI。

接口对照本机 0.4.0 帮助及 Go schema：version、me、cache status、contacts、messages。首版手动选择，固定日期与条数，没有自动分页、OCR/AX 定位或完整 ContextBundle。

来源键由平台、账号及数据目录指纹、会话 ID、wxview 本地消息 ID 构成摘要。不承诺缓存重建或跨设备 ID 稳定。草稿保存正文与范围说明；旧 JSON 记录可缺省新增 evidence 字段。

macOS CLI 尚无账号绑定参数：多账号目录拒绝查询，单账号查询前后复核身份。这不是跨进程事务锁；生产集成仍需 CLI 支持显式账号并在响应返回身份。后续已接入有限上下文预览及 Codex CLI 初次派发，见 06 文档。

## 全局捕获与自动定位当前实现（第一期 B）

- `Capture/GlobalPingInput.swift`：显式启用 CGEventTap，只处理所选修饰键/移动/松手/取消并排队通知主线程。15 秒未结束手势自动收起，普通修饰键组合键不被吞掉。
- `Presentation/DesktopWheel.swift`：非激活 NSPanel，自绘四扇区、渐变高亮、图标缩放与中心取消。使用 lolPing PNG 图标并参考灰金色轮盘与动画，来源见 THIRD_PARTY_NOTICES.md。屏幕边缘调整轮盘与选择指针，结束恢复原始指针；捕获锚点仍为最初位置。
- `Capture/DesktopCapture.swift`：按下时冻结指针下的顶层窗口 ID/PID/边界/显示器；松手后使用窗口专用 SCContentFilter，仅捕获该窗口并排除轮盘。窗口移动、关闭或权限不足时明确失败。macOS 14+ 用 SCScreenshotManager；13 用短时 SCStream，首个完整帧后停止，使用内容矩形与像素缩放去除边框。后者仍需旧系统验收。
- 图像最长边 4096 像素，Vision 最多保留 400 行；OCR 失败仍保存截图。截图查询有超时，不建立常驻录屏。PNG 位于 Application Support/PingTaskPrototype/Captures，元数据随 TaskRecord.captures 保存；截图目录/文件分别使用 0700/0600。
- `Resolver/WeChatResolver.swift`：从窗口标题及顶部 OCR 提取最多三个会话线索，使用联系人元数据查询候选。只有唯一精确标题候选才自动进入会话内消息搜索；最终消息均需用户核对。指针行需靠近原始指针且满足置信门槛，不用整屏任意文字推定目标。
- `Capture/DesktopPingController.swift`：一次只处理一条全局捕获链路。默认明确查询近 30 天，最多 20 条消息，用户可改范围（上限 366 天）；不默认把历史屏幕消息当成今天。微信身份、会话、分页总数均复核。当前只自动查询微信 Bundle ID com.tencent.xinWeChat，其他应用保留截图。
- 原始截图用 captureID 保存独立草稿。requiresSourceConfirmation 阻止提交；确认候选后绑定稳定来源，发现已有任务时合并截图证据并保留原编辑与历史提交。用户也可明确保留未知会话的截图来源，不伪造消息 ID。
- 截图与 JSON 不是事务：写入记录失败会回滚内存并尝试删除刚创建的图片；崩溃仍可能留下孤立附件。已增加删除任务时清理独占截图、有限前后文和独立 Codex 提交占用；AX 文字、气泡分组、完整上下文和全量事务存储尚未实现。

实机授权、焦点、多屏/Retina、macOS 13 和真实微信命中率需另行验收。静态渲染和合成图像 OCR 测试不等价于真实截图通过。

## 意图库与图片（已实现）

- `Intent/IntentLibrary.swift` 在主线程管理增删、编辑、排序及默认图片。新意图使用 UUID，默认仅特效；模板修改和删除不改变已有任务快照，保存失败回滚配置。
- `PingAction.artwork` 和 `onWheel` 为可选字段，旧配置保持原有图标及启用状态；中心图和新意图默认图存入同一个 `state.json`。空意图库不会在重启时恢复默认动作。
- 意图库不限数量，轮盘取最多 8 个启用项。一次手势开始时冻结有序动作和中心图片，显示与命中共享相同数量及角度，空轮盘不触发捕获。
- `Intent/PingArtwork.swift` 读取 95 项静态素材目录。保留 44 张 WebP 原文件，但当前只用静态图配合原生弹出、光圈和淡出动画。
- 自定义图片在后台解码，限制 20 MB、8192 像素边长，首帧缩放至 512 像素以内并重新编码为无原始元数据的 PNG。副本位于 `Artwork/<UUID>.png`，目录 / 文件权限为 0700 / 0600；配置只保存不含路径的引用。
- 中心图仅影响外观，中心松手仍取消。图片选择器按分类搜索；删除自定义图片先检查意图、中心和默认图引用，再移入废纸篓。内置素材不提供删除入口。
