# WorkBuddy Agent 接入

## 使用

1. 打开并登录 WorkBuddy，等待桌面启动完成。
2. PingTask 设置中核对 WorkBuddy.app、Python 3 和模型 ID（默认 `hy3`），点击“检查 WorkBuddy”。检查只读取产品配置并握手 IPC，不发送模型请求。
3. 工作目录和 tmux 路径沿用 Codex 区域中的设置。默认开放 Read / Glob / Grep，可独立启用 Write / Edit；未开放 Bash、外部 MCP 或消息发送工具。工作目录不是文件系统沙箱。
4. 在 Ping 意图中选择 WorkBuddy Agent，创建并核对来源草稿，确认后提交。
5. 任务记录查看 session、状态、Markdown 输出、原文与复制，或打开本次提交和日志目录。

## 实现与边界

基于本机 WorkBuddy 5.8.3 安装包内 CLI 与 WBIPC，参考用户指定的 `weixincli/workbuddy-driver`。这是实验性内部接口，不是官方稳定 SDK，升级后需重新核验。依赖已有桌面登录和本机 Python 3，不导出账号 token。

独立 tmux worker 启动 Python 桥接，再启动 WorkBuddy CLI Agent。沿用 SQLite 提交占用、不可变快照和先 claim 再 launch；未知状态不会自动重发。关闭 PingTask 不代表停止任务。内部历史字段仍名为 `codex`，兼容旧记录，通过提交中的 `workBuddy` 配置区分执行器。

每次提交创建只监听 loopback 的临时 relay，校验随机 token，仅转发模型 completion 路径；请求体、并发、输出和运行时间有上限，退出时清理 CLI 子进程和 relay。IPC 凭据与产品配置只在进程内处理，不写入提交快照。正文与 OCR 会交给 WorkBuddy 当前服务；截图不作为视觉输入。

结果仅在 CLI 退出码为 0、最终事件为 success、无错误及权限拒绝时标记本轮完成；完成不是产物验收。记录的 session 是传给 CLI 的会话 ID，不能据此声称桌面 App 已收录任务。桌面任务列表、续聊直达、外部会话状态同步和图片视觉输入尚未验证。

## Ping 意图自动处理配置

手动核对本机图片或文件后，可选择随 Ping 意图保存附件。提交时复制到独立 `attachments/` 目录，在提示词中列出路径和 SHA-256，并通过 CLI `--add-dir` 开放该目录访问。WorkBuddy 读取工作目录外的合成文本附件测试通过；这不代表图片理解或所有二进制文件格式都支持。附件中的指令不得改变任务范围。

意图可选择 Codex 或 WorkBuddy，自动上下文及自动提交默认关闭。开启自动提交是对后续该意图 Ping 的预先授权：仅在自动定位符合条件时提交，沿用当前设置并冻结提交快照。

当前匹配先用联系人和指针 OCR 查询 wxview，不以独立 OCR 分数阻止检索；整段零命中可用最多 3 个文字片段找候选。自动绑定要求唯一精确会话、指针长文本（去除空格标点后至少 12 字）与唯一 wxview 文本消息完整匹配，以及未截断的附近上下文；片段命中或歧义保留真实候选供核对，命中已有任务不重复提交。真实匹配率和完整 GUI 流程尚待验收。微信浏览页已接入新倒序游标协议；自动定位与附近上下文继续使用原有有界检索协议。

## 验证

```sh
/usr/bin/python3 scripts/tests/test_workbuddy.py
swift build
swift run PingTask --self-test
swift run PingTask --codex-check
```

Python 测试使用模拟 CLI 和 IPC，验证 relay 认证/路径限制、转发字段、工具权限及最终失败判定，不调用真实模型。`--codex-check` 使用真实隔离 tmux 和假执行器测试提交与恢复，不是 WorkBuddy 模型实测。

本轮本机 WorkBuddy 5.8.3 的 IPC 连接检查通过。另用本 App 桥接驱动在临时目录执行合成算式任务：退出码 0、完成事件、预期结果标记和 session 记录均通过，未使用真实聊天材料。此项是驱动实测，不代表 GUI 流程、真实微信匹配或桌面会话找回已验收。
