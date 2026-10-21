import SwiftUI

struct WorkBuddySettingsView: View {
    @ObservedObject var store: Store
    @State private var status = "先打开并登录 WorkBuddy。实验性接口，升级后需重新检查。"
    @State private var checking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("WorkBuddy Agent · CLI + IPC", systemImage: "terminal").font(.headline)
            TextField("WorkBuddy.app 路径", text: $store.workBuddySettings.appPath)
            TextField("Python 3 可执行文件", text: $store.workBuddySettings.python)
            TextField("模型 ID", text: $store.workBuddySettings.model)
            Toggle("允许 Write / Edit 修改文件", isOn: $store.workBuddySettings.allowEdits)
            Text("默认只启用 Read / Glob / Grep。沿用上方默认工作目录；工作目录不是文件系统沙箱。处理来源文字、OCR 与用户选择的附件；图片理解尚未验证，不支持 Bash 和自动发消息。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(checking ? "正在检查…" : "检查 WorkBuddy") {
                    let settings = store.workBuddySettings
                    checking = true
                    Task {
                        do { status = try await Task.detached { try settings.check() }.value }
                        catch { status = (error as? WxFailure)?.message ?? "连接失败，请核对 WorkBuddy 桌面登录、Python 和安装路径。" }
                        checking = false
                    }
                }.disabled(checking)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder).onChange(of: store.workBuddySettings) { $0.save() }
    }
}
