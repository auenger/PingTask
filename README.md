# PingTask

Swift 原生 macOS 桌面任务入口：指向一条信息，选择意图，确认后交给现有 Agent，并保存来源与推进记录。

**指一下信息，确认要做什么，让已有 Agent 接着推进。**

PingTask 负责桌面捕获、上下文交接和任务留痕。代码实现与复杂任务执行交给 Codex / WorkBuddy；微信、飞书和钉钉计划分别通过 wxview、lark-cli 和 dws 接入。项目独立于 wxview。

> 当前阶段：可运行的原生交互原型。所有渠道消息与执行结果均为模拟数据，尚未接入真实截图或外部服务。

## 功能状态

| 能力 | 当前状态 |
|---|---|
| 原生窗口、菜单栏入口 | 已实现 |
| 四方向 Ping 轮盘、点击和窗口内拖动 | 已实现 |
| 每个动作独立编辑名称和提示词 | 已实现 |
| 确认卡、提示词快照、补充说明 | 已实现 |
| 重复 Ping 合并、提交保护、显式续接 | 已实现，限本地模拟 |
| 历史记录、配置和推进细节持久化 | 已实现，JSON 原型存储 |
| 全局手势、真实截图、窗口和消息识别 | 规划中 |
| wxview / lark-cli / dws 查询 | 规划中 |
| Codex / WorkBuddy 调度和状态同步 | 规划中 |
| SQLite outbox、远端幂等与故障恢复 | 规划中 |

## 当前交付

- [产品设计](docs/01-product.md)：用户流程、边界、确认卡和界面设计。
- [技术设计](docs/02-architecture.md)：原生框架、渠道和执行器接口、记录模型。
- [确认与幂等协议](docs/03-confirmation-idempotency.md)：重复 Ping、续接、超时和恢复。
- [功能清单与路线](docs/04-roadmap.md)：原型已实现内容与生产能力区分。
- [原型验收](docs/05-prototype-checklist.md)：手工验证步骤及测试边界。
- 可编译运行的 SwiftUI / AppKit 原型，无第三方依赖。

## 运行

要求：macOS、Swift 6.0+ 工具链及 macOS SDK（Xcode 或 Command Line Tools）。部署目标为 macOS 13+，旧版本兼容性仍需实机验证。本轮在 Intel Mac、Swift 6.2.3 下编译验证。

```sh
git clone https://github.com/auenger/PingTask.git
cd PingTask
swift run PingTask
```

生成可双击打开的应用：

```sh
bash scripts/package-app.sh
open dist/PingTask.app
```

检查核心规则：

```sh
swift run PingTask --self-test
```

## 原型能体验什么

1. 选择虚构的微信 / 飞书 / 钉钉消息。
2. 点击轮盘动作，或从中心按住拖向动作并松手。
3. 编辑确认卡的提示词与补充说明，明确确认后模拟提交。
4. 重复 Ping 同一目标，打开同一条记录，不重复提交。
5. 模拟完成后，输入新增信息，确认后续接下一轮。
6. 编辑各 Ping 的名称和内置提示词；重启后保留配置和记录。

**当前是交互原型，不会截图真实桌面、读取聊天或调用 Codex / WorkBuddy。**
没有全局快捷键、真实窗口识别、真实 CLI 调用、真实 Agent 输出和跨消息任务关联。不能以模拟完成作为真实任务完成。

原型状态文件：`~/Library/Application Support/PingTaskPrototype/state.json`。
仅保存用户在原型输入的内容和虚构消息。删除该文件可重置演示数据；应用自身没有自动删除行为。

## 确认与重复操作

- 松手只生成草稿，用户点击“确认提交”才进入模拟执行。
- 同一消息、动作、项目及执行器再次 Ping，打开原记录并保留编辑。
- 执行中重复点击不创建下一轮。
- 完成后需添加新信息并明确确认，才能继续。
- 模板更新不会覆盖已经捕获的提示词快照。
- 重启发现未结束的模拟执行时，标记“待核对”，不自动重新提交。

本地去重不能替代远端幂等。未来接入执行器时，超时但结果未知的请求需要先核对，不能直接创建新任务。完整规则见 [确认与幂等协议](docs/03-confirmation-idempotency.md)。

## 项目结构

```text
PingTask/
├── Package.swift
├── Sources/PingTask/main.swift   # 原型 UI、状态管理、演示数据、自检入口
├── scripts/package-app.sh        # 本机 .app 打包及 ad-hoc 签名
├── docs/                        # 产品、架构、幂等、路线和验收
├── AGENTS.md                    # AI 协作与开发约定
└── README.md
```

当前采用 SwiftUI + AppKit，无第三方依赖。源码为便于评审的单文件原型；真实接入时按 Capture、Resolver、SourceAdapter、TaskCoordinator、ExecutorAdapter 和 RecordStore 拆分，参见 [技术设计](docs/02-architecture.md)。

## 开发与验证

```sh
swift build
swift run PingTask --self-test
bash scripts/package-app.sh
./dist/PingTask.app/Contents/MacOS/PingTask --self-test
codesign --verify --deep --strict dist/PingTask.app
plutil -lint dist/PingTask.app/Contents/Info.plist
```

自检使用临时目录，覆盖去重边界、编辑保留、双击提交保护、模板快照、取消后重建和重启恢复，不修改日常使用的记录。界面交互按 [验收清单](docs/05-prototype-checklist.md) 手工检查。

打包脚本生成当前机器架构的应用，不是 Universal 二进制；ad-hoc 签名仅用于本机开发，不等于 Developer ID 签名或公证。发布包、多架构构建和自动更新尚未配置。

不要提交 `.build/`、`dist/`、真实截图、聊天记录、令牌或运行状态。现阶段 JSON 存储按单实例使用，不支持多实例并发写入。

## 下一步

1. 实现系统权限引导、全局轮盘和单次截图。
2. 接入 wxview 消息定位及有范围的上下文读取。
3. 完成 Codex 单项目闭环和生产级提交恢复。
4. 扩展飞书、钉钉和 WorkBuddy。

完整优先级见 [功能清单与路线](docs/04-roadmap.md)。参与开发前请阅读 [AGENTS.md](AGENTS.md)。

## 设计参考

借鉴 [lolPing](https://github.com/darrenprx/lolPing) 的按住、指向、松手和轮盘反馈交互。未复制其代码、游戏图标或音效；原型使用系统 SF Symbols 和自定义布局。

框架与外部接口参考见技术设计。当前不包含开发者签名、公证或自动更新，打包脚本仅用于本机原型。
