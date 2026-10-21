import SwiftUI
import AppKit

struct CodexSettingsView: View {
    @ObservedObject var store: Store
    @State private var checking = false
    @State private var status = "选择已有的 Codex CLI 和 tmux；使用 Codex 自己的登录信息。"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex CLI · tmux", systemImage: "terminal").font(.headline)
            path("Codex 可执行文件", value: $store.codexSettings.executable, directory: false)
            path("tmux 可执行文件", value: $store.codexSettings.tmux, directory: false)
            path("默认工作目录", value: $store.codexSettings.workspace, directory: true)
            HStack {
                Text("App 已提供默认工作目录，也可选择自己的项目目录。").font(.caption).foregroundStyle(.secondary)
                Button("使用默认目录") {
                    Task {
                        do {
                            try await Task.detached { try CodexSettings.ensureDefaultWorkspace() }.value
                            store.codexSettings.workspace = CodexSettings.defaultWorkspace.path
                        } catch { status = error.localizedDescription }
                    }
                }
            }
            Picker("执行权限", selection: $store.codexSettings.sandbox) {
                Text("只读分析").tag("read-only")
                Text("允许修改工作目录").tag("workspace-write")
            }.pickerStyle(.segmented)
            Text("确认提交会将来源正文和最多 4 张截图交给 Codex，按 Codex 当前账号与服务配置处理。非交互执行不能现场批准提权；遇到权限限制后，在 CLI 中继续处理。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("自动查找") {
                    let paths = CodexSettings.discover()
                    if let path = paths.0 { store.codexSettings.executable = path }
                    if let path = paths.1 { store.codexSettings.tmux = path }
                    status = "已检查常用安装目录，可以检查连接。"
                }
                Button(checking ? "正在检查…" : "检查连接") { check() }.disabled(checking)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text("交互练习中的虚构消息仍使用模拟执行。").font(.caption2).foregroundStyle(.secondary)
        }.onChange(of: store.codexSettings) { settings in settings.save() }
    }
    func path(_ title: String, value: Binding<String>, directory: Bool) -> some View {
        HStack {
            TextField(title, text: value).textFieldStyle(.roundedBorder)
            Button("选择") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }
        }
    }
    func check() {
        let settings = store.codexSettings
        checking = true
        Task {
            do {
                status = try await Task.detached {
                    try settings.checkConnection()
                }.value
            } catch { status = error.localizedDescription }
            checking = false
        }
    }
}

struct CodexTaskView: View {
    @ObservedObject var store: Store
    let task: TaskRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = task.codex {
                Text("工作目录：\(link.workspace)").font(.caption).textSelection(.enabled)
                if let session = link.progress.sessionID {
                    Text("Session：\(session)").font(.caption.monospaced()).textSelection(.enabled)
                } else { Text("尚未收到 session ID，请核对进度。").font(.caption) }
                Text("tmux：\(link.tmuxName)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button(task.executor == "WorkBuddy" ? "查看 WorkBuddy 结果" : "打开 Codex CLI") { store.openCodex(task.id) }
                    Button("刷新状态") { Task { await store.refreshCodex() } }
                    Button("查看提交与日志") { NSWorkspace.shared.open(URL(fileURLWithPath: link.directory)) }
                }
                Text("首次执行状态 · \(link.progress.status) · \(link.progress.updated.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
                Text(task.executor == "WorkBuddy" ? "实验性 CLI + IPC 接入，处理正文、OCR 与所选附件；图片理解、桌面任务列表及续聊入口尚未验证。" : "CLI 中可继续同一对话。外部续聊的最新状态以 Codex 为准；本轮完成不代表结果已验收。")
                    .font(.caption2).foregroundStyle(.secondary)
                if !link.progress.output.isEmpty {
                    CodexResponseView(markdown: link.progress.output, title: "\(task.executor) 返回").id(task.id)
                }
            } else {
                Text("提交到：\(store.codexSettings.workspace.isEmpty ? "请先到设置选择工作目录" : store.codexSettings.workspace)")
                    .font(.caption).textSelection(.enabled)
                Text(task.executor == "WorkBuddy" ? "WorkBuddy 接收正文、OCR 与所选附件；工具权限由设置决定，工作目录不是文件系统沙箱。" : "权限：\(store.codexSettings.sandbox == "workspace-write" ? "允许修改工作目录" : "只读分析") · 提供正文、所选附件及最多 4 张图片（含截图）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
