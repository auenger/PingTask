import SwiftUI
import AppKit

struct PingTriggerPicker: View {
    @ObservedObject var model: DesktopPingController
    @State private var monitor: Any?
    @State private var recording = false
    @State private var hint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("全局触发方式", selection: Binding(get: { model.trigger }, set: { model.setTrigger($0) })) {
                ForEach(PingTrigger.allCases) { key in Text(key.label).tag(key) }
            }.pickerStyle(.segmented).frame(maxWidth: 660).disabled(model.busy || recording)
            if model.trigger == .shortcut {
                HStack {
                    Text(model.shortcut.label).font(.system(.body, design: .monospaced))
                    Button(recording ? "取消录入（Esc）" : "录入快捷键") {
                        if recording { stopRecording() } else { startRecording() }
                    }
                    .disabled(model.busy)
                }
                Text(recording ? (hint.isEmpty ? "请按一个包含 ⌃ Control、⌥ Option 或 ⌘ Command 的组合键。" : hint) : "按住组合键并移动选择，先松开主键触发；Esc 或回中心取消。启用后，此快捷键由 PingTask 接管。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onDisappear { stopRecording() }
    }
    private func stopRecording() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; hint = ""
        model.recordShortcut(false)
    }
    private func startRecording() {
        recording = true; hint = ""; model.recordShortcut(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { stopRecording(); return }
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(PingKeyboardShortcut.modifierMask)
                guard !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else {
                    hint = "请同时按住 ⌃ Control、⌥ Option 或 ⌘ Command，避免接管普通文字输入。"
                    return
                }
                let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
                let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased().prefix(16).description ?? "Key \(event.keyCode)"
                let shortcut = PingKeyboardShortcut(keyCode: event.keyCode, modifiers: flags.rawValue, keyLabel: label)
                stopRecording(); model.setShortcut(shortcut)
                return
            }
            return nil
        }
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
