import SwiftUI

struct PingTriggerPicker: View {
    @ObservedObject var model: DesktopPingController
    var body: some View {
        Picker("全局触发键", selection: Binding(get: { model.trigger }, set: { model.setTrigger($0) })) {
            ForEach(PingTrigger.allCases) { key in Text(key.label).tag(key) }
        }.pickerStyle(.segmented).frame(maxWidth: 390).disabled(model.busy)
    }
}

struct TaskRecordControls: View {
    @ObservedObject var store: Store
    @ObservedObject var desktop: DesktopPingController
    let taskID: UUID
    @State private var confirmingDelete = false
    var body: some View {
        HStack {
            if let task = store.tasks.first(where: { $0.id == taskID }) {
                if ["待确认", "模拟执行中"].contains(task.status) {
                    Button(task.status == "待确认" ? "取消任务" : "停止模拟任务") { store.cancel(taskID) }
                }
                Button("删除记录", role: .destructive) { confirmingDelete = true }
                if task.status == "已取消" { Text("已取消").foregroundStyle(.secondary) }
            }
        }
        .disabled(desktop.busy || store.codexBusy.contains(taskID))
        .alert("删除这条 Ping 记录？", isPresented: $confirmingDelete) {
            Button("保留", role: .cancel) {}
            Button("删除", role: .destructive) {
                if store.deleteTask(taskID) { desktop.forgetDeletedTask(taskID) }
            }
        } message: {
            Text("本地记录将移除，独占截图移到废纸篓。Codex 的提交快照、日志和会话保留，删除记录不会取消 Codex 执行。")
        }
    }
}
