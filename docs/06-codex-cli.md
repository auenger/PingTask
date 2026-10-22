# 第一期：tmux + Codex CLI 交接

## 实现范围

PingTask 负责来源、用户确认、初次执行、session 关联和找回。Codex 负责推理、执行和后续对话。使用本机已安装的 Codex CLI 与 tmux，不接 App Server，不捆绑 Node，不自动登录。

- 设置：可执行文件自动查找 / 手动选择、工作目录、只读或 workspace-write、连接检查。App 自动创建 `~/Library/Application Support/PingTaskPrototype/Workspace`，迁移旧的空目录设置，保留自定义目录。
- 连接检查分别报告可执行文件、Codex 启动、tmux 启动和登录问题，不把空目录误报成登录失败。目录在提交前单独校验；App 默认目录不要求 Git 仓库，执行时仅对该目录传入 `--skip-git-repo-check`。
- 真实来源确认后启动；虚构练习继续使用模拟执行。
- 独立 tmux socket `pingtask`，每个任务一个 `ping-<task UUID>` 会话。
- `codex exec --json --sandbox <mode> --cd <directory> [--image <snapshot>] -`，提示词经 stdin 文件传入。
- 解析 `thread.started` 的 session ID，以及 turn / item 事件；UI 展示首次执行的状态和最近输出。
- 任务记录的最近输出支持原生 Markdown 预览 / 原文切换、复制 Markdown 和单独复制代码块；兼容已有记录。预览覆盖标题、列表、勾选项、引用、围栏代码和简单表格，不执行 HTML、不加载远程图片。复杂 Markdown 可切换原文查看，完整日志仍从提交目录打开。
- CLI 找回：仍运行时 attach 原 tmux；已结束时在同名 tmux 会话中 `codex resume <session-id>`，后续点击复用该会话。权限审批在 CLI 内处理。
- Codex App 可见性、直达链接、外部续聊状态同步尚未验证 / 实现，界面明确区分“首次执行状态”。
- wxview 可预览目标前后 15 分钟内最多 100 条消息，从中选择锚点前后各最多 5 条；缺少锚点时拒绝附加。只在用户确认后把上下文写入草稿。

本机接口核对：Codex CLI 0.163.0、wxview 0.4.0、tmux 本机帮助。JSONL 事件与 [Codex 官方事件定义](https://github.com/openai/codex/blob/main/codex-rs/exec/src/exec_events.rs) 对照。

进程环境：wxview 默认继承 App 环境；Codex 明确加入所选可执行文件同目录的 Node 路径。不能给 Foundation Process 设置 `environment = nil`，这会清空 HOME，使 wxview 的账号识别退出码为 1。连接错误只显示阶段和安全分类，不输出原始 stderr 中的账号路径或消息。

环境修复后已通过 `--process-environment-check`；通过 LaunchServices 启动 `/Applications/PingTask.app --wxview-connection-check`，版本、账号识别和缓存检查均成功。该检查只读取连接元数据，不读取聊天正文，也不代表消息定位流程已完成验收。

## 持久化与恢复

数据位于 `~/Library/Application Support/PingTaskPrototype/Codex/`，不提交版本库：

- `submissions.sqlite`：task 唯一、operation 唯一，存储不可变 payload 和 queued / dispatching 阶段。
- `<operation>/submission.json`、`prompt.txt`：冻结目录、权限、提示词、执行器路径与图片引用；认证仍由 Codex 管理。
- `<operation>/capture-*.png`：最多 4 张独立截图副本；删除原记录不会删除已提交的证据。提示词列出各图像素尺寸及原始 Ping 坐标（0–1，左上角原点，x 向右 / y 向下），让 Codex 围绕指针位置分析；图片推断不自动写回 wxview 消息身份。
- `started.lock`：O_EXCL 创建，worker 不可重复启动。
- `progress.json`：原子写入的 session、最近输出、首次执行状态、退出码与时间。
- `events.jsonl`：最多 8 MB 的原始执行日志；界面输出最多 32000 字。
- `continue.command`：仅使用固定模板及 shell 单引号转义的已确认路径和 UUID，不拼接来源正文。

先准备文件并提交 SQLite 占用，再原子领取 queued，最后启动 tmux。重启可领取从未派发的 queued；dispatching 仅核对进度 / tmux，不重新派发。启动间隙崩溃、tmux 消失或无终态回执都标记待核对，不承诺远端 exactly-once。

子进程后台处理事件，App 最多跟踪 4 个未结束的初次执行，每 3 秒更新活跃执行状态，结束后停止定时查询；手动刷新可重新核对。进程退出码 0 且有 `turn.completed` 才标记“Codex 本轮完成”，不是“已验证”。

删除结束记录只清理原任务附件，保留提交审计材料与 Codex 会话；未确认结束的记录不能删除。初次执行完成后请在 Codex 继续，不从 PingTask 自动创建另一轮。

## 手动回归

1. 设置 → 自动查找 Codex / tmux → 使用 App 默认工作目录（也可选测试仓库）→ 只读分析 → 检查连接。
2. 微信连接选择一条测试消息，预览附近上下文，核对目标、范围和截断说明，再选为来源。也可从全局 Ping 截图开始，核对候选。
3. 确认卡核对正文、提示词、工作目录和权限；提交后查看 session、输出和终态。不要把虚构练习的模拟状态当作这一步通过。
4. 连点提交、重复 Ping 同一来源，确认没有新建第二个执行会话。
5. 执行期间退出并重开 PingTask，确认仍关联同一 session；执行期间打开 CLI 连接原 tmux。
6. 执行结束后打开 CLI，确认 `codex resume` 回到同一对话，并手动续聊。App 仅展示首次执行状态。
7. 选择一个临时仓库并明确开启 workspace-write，再测试代码修改。权限不足时转到 CLI 处理，不自动绕过权限。
8. 核对失败日志、未知状态、删除结束记录后仍可在 Codex 找回 session。
9. 任务记录查看 Codex 返回：切换预览 / 原文，复制 Markdown 后粘贴核对原文，单独复制代码块；切换任务后确认内容同步。

## 本轮验证边界

按用户要求仅进行编译、打包检查和局部传输 / 持久化检查，不运行大面积回归，不向真实 Codex 提交测试消息，不读取真实微信正文。动态界面、真实模型执行与微信完整链路由用户手动验收。

局部检查：`swift build` 后执行 `.build/debug/PingTask --codex-check`，使用临时目录、假 Codex 和独立的临时 tmux 会话，覆盖 SQLite 重复提交、领取与重开、真实 tmux 启动、session / 输出恢复、stdin 不执行来源文字及 CLI 入口转义。
