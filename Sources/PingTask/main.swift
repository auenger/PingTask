import SwiftUI
import AppKit
import CryptoKit

struct PingAction: Codable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var prompt: String
    static let defaults: [PingAction] = [
        .init(id: "analyze", name: "分析一下", symbol: "sparkle.magnifyingglass",
              prompt: "分析目标消息及相关上下文。区分已知事实、推断和待确认问题。给出建议与下一步，不修改代码。"),
        .init(id: "plan", name: "拆成任务", symbol: "checklist",
              prompt: "将讨论整理成可执行任务，列出目标、依赖、验收条件和待澄清问题。不向外部平台发布任务。"),
        .init(id: "implement", name: "开始处理", symbol: "hammer",
              prompt: "在指定项目中分析并实现明确的需求，运行相关验证，报告改动和结果。遇到关键缺失信息时提出问题。"),
        .init(id: "continue", name: "继续推进", symbol: "arrow.triangle.branch",
              prompt: "将新增证据与已有任务对照，说明变化，继续尚未完成的工作，避免重复执行已经完成的步骤。")
    ]
}

struct SourceMessage: Identifiable {
    let id: String
    let app: String
    let chat: String
    let sender: String
    let text: String
    // Stable identifiers stand in for connector-returned account / conversation / message IDs.
    var anchor: String { "\(app)/demo-account/\(chat)/\(id)" }
    static let examples = [
        SourceMessage(id: "msg-001", app: "微信", chat: "产品研发群", sender: "林舟",
                      text: "导出按钮点了没反应，Safari 上可以稳定复现，帮忙看一下。"),
        SourceMessage(id: "msg-002", app: "飞书", chat: "项目协作", sender: "陈安",
                      text: "请把这次导出优化拆成任务，补一下验收条件。"),
        SourceMessage(id: "msg-003", app: "钉钉", chat: "交付项目组", sender: "周宁",
                      text: "补充一下：只有带筛选条件的导出会失败，普通导出正常。")
    ]
}

struct TaskRecord: Codable, Identifiable {
    var id = UUID()
    var source: String
    var app: String
    var chat: String
    var original: String
    var actionID: String
    var actionName: String
    var promptSnapshot: String
    var project: String
    var executor: String
    var note = ""
    var status = "待确认"
    var revision = 0
    var operationID: String?
    var events: [String] = []
    var updated = Date()
}

enum Identity {
    static func digest(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func key(source: String, action: String, project: String, executor: String) -> String {
        digest([source, action, project, executor])
    }
    static func key(_ task: TaskRecord) -> String {
        key(source: task.source, action: task.actionID, project: task.project, executor: task.executor)
    }
    static func canSubmit(_ task: TaskRecord) -> Bool { task.status == "待确认" }
    static func canContinue(_ task: TaskRecord) -> Bool {
        task.status == "模拟完成" && !task.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SavedState: Codable {
    var actions: [PingAction]
    var tasks: [TaskRecord]
}

@MainActor final class Store: ObservableObject {
    @Published var actions = PingAction.defaults
    @Published var tasks: [TaskRecord] = []
    @Published var selected: UUID?
    @Published var notice = "演示模式 · 使用虚构消息，提交不会调用外部 Agent"
    private let file: URL

    init(fileURL: URL? = nil) {
        file = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingTaskPrototype/state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            actions = state.actions
            tasks = state.tasks
            // A crashed demo process must not invent completion or re-submit on restart.
            for i in tasks.indices where tasks[i].status == "模拟执行中" {
                tasks[i].status = "待核对"
                tasks[i].events.append("重启后发现未结束操作；保留操作 ID，等待核对")
            }
        } catch { notice = "无法读取记录：\(error.localizedDescription)" }
    }

    @discardableResult func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(SavedState(actions: actions, tasks: tasks)).write(to: file, options: .atomic)
            return true
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func capture(_ source: SourceMessage, action: PingAction, project: String, executor: String) {
        let key = Identity.key(source: source.anchor, action: action.id, project: project, executor: executor)
        if let index = tasks.firstIndex(where: { Identity.key($0) == key && $0.status != "已取消" }) {
            selected = tasks[index].id
            tasks[index].events.append("再次 Ping：打开已有记录，未提交新任务")
            tasks[index].updated = Date()
            notice = "已合并重复 Ping · \(tasks[index].actionName)"
        } else {
            var task = TaskRecord(source: source.anchor, app: source.app, chat: source.chat,
                                  original: source.text, actionID: action.id, actionName: action.name,
                                  promptSnapshot: action.prompt, project: project, executor: executor)
            task.events = ["已捕获模拟消息，创建待确认草稿"]
            tasks.insert(task, at: 0)
            selected = task.id
            notice = "已生成确认卡 · 查看内容后再提交"
        }
        save()
    }

    func submit(_ id: UUID, continuing: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard continuing ? Identity.canContinue(tasks[index]) : Identity.canSubmit(tasks[index]) else { return }
        let prior = tasks[index]
        tasks[index].revision += 1
        let revision = tasks[index].revision
        tasks[index].operationID = Identity.digest([id.uuidString, "\(revision)"])
        tasks[index].status = "模拟执行中"
        tasks[index].events.append(continuing
            ? "已确认续接第 \(revision) 轮：\(tasks[index].note)"
            : "已确认第 \(revision) 轮；提示词快照已锁定；补充说明：\(tasks[index].note)")
        tasks[index].note = ""
        tasks[index].updated = Date()
        guard save() else { tasks[index] = prior; return }
        notice = "已提交模拟执行器 · 重复点击不会再次派发"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let i = tasks.firstIndex(where: { $0.id == id }),
                  tasks[i].revision == revision, tasks[i].status == "模拟执行中" else { return }
            tasks[i].status = "模拟完成"
            tasks[i].events.append("模拟返回：已接收材料。真实的代码执行、测试与产物尚未接入。")
            tasks[i].updated = Date()
            save()
        }
    }

    func cancel(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status == "待确认" else { return }
        tasks[i].status = "已取消"
        tasks[i].events.append("用户取消草稿，未创建外部任务")
        save()
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var tab = 0
    @State private var sourceIndex = 0
    @State private var project = "示例 / 后台管理系统"
    @State private var executor = "Codex"
    @State private var hovered: String?
    private let accent = Color(red: 0.15, green: 0.62, blue: 0.52)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "scope").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading) {
                    Text("PingTask").font(.title2.bold())
                    Text("指一下，把事情往前推进").foregroundStyle(.secondary)
                }
                Spacer()
                Text("原生交互原型").font(.caption).padding(8).background(accent.opacity(0.12), in: Capsule())
            }.padding(24)
            Picker("页面", selection: $tab) {
                Text("捕获与确认").tag(0)
                Text("Ping 提示词").tag(1)
                Text("推进记录 · \(store.tasks.count)").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if tab == 1 { settings } else if tab == 2 { history } else { workspace }
            Divider()
            HStack {
                Image(systemName: "info.circle")
                Text(store.notice).font(.caption)
                Spacer()
            }.foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 1040, minHeight: 720)
    }

    var workspace: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Text("01  指向一条消息").font(.headline)
                Picker("消息来源", selection: $sourceIndex) {
                    ForEach(SourceMessage.examples.indices, id: \.self) { i in
                        Text(SourceMessage.examples[i].app).tag(i)
                    }
                }.pickerStyle(.segmented)
                let source = SourceMessage.examples[sourceIndex]
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(source.chat)  ·  \(source.sender)").font(.caption).foregroundStyle(.secondary)
                    Text(source.text).font(.title3).lineSpacing(5)
                    Text("虚构消息 · 固定消息 ID · 非真实截图").font(.caption2).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                Text("02  选择 Ping 意图").font(.headline)
                wheel
                Text("点击动作，或从中心按住拖向动作后松手。\n重复选择同一动作，可验证草稿合并。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("项目", selection: $project) {
                    Text("后台管理系统").tag("示例 / 后台管理系统")
                    Text("客户门户").tag("示例 / 客户门户")
                }
                Picker("执行器", selection: $executor) {
                    Text("Codex（模拟）").tag("Codex")
                    Text("WorkBuddy（模拟）").tag("WorkBuddy")
                }
            }.frame(width: 420)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("03  确认与推进").font(.headline)
                if let id = store.selected, let i = store.tasks.firstIndex(where: { $0.id == id }) {
                    taskDetail(i)
                } else {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(accent)
                    Text("每次 Ping 先落成记录").font(.title2)
                    Text("在左侧选择一个动作，确认卡会出现在这里。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
    }

    var wheel: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.18), lineWidth: 1).frame(width: 230, height: 230)
            ForEach(Array(store.actions.enumerated()), id: \.element.id) { i, action in
                let angle = Double(i) * .pi / 2 - .pi / 2
                Button {
                    capture(action)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: action.symbol).font(.title2)
                        Text(action.name).font(.caption)
                    }
                    .frame(width: 96, height: 64)
                    .background(hovered == action.id ? accent.opacity(0.3) : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).offset(x: cos(angle) * 107, y: sin(angle) * 107)
            }
            Image(systemName: "scope").font(.system(size: 34)).foregroundStyle(accent)
                .frame(width: 62, height: 62).background(accent.opacity(0.1), in: Circle())
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { hovered = actionAt($0.translation)?.id }
                    .onEnded { value in
                        if let action = actionAt(value.translation) { capture(action) }
                        hovered = nil
                    })
        }.frame(width: 340, height: 290).frame(maxWidth: .infinity)
    }

    func actionAt(_ delta: CGSize) -> PingAction? {
        guard hypot(delta.width, delta.height) > 48 else { return nil }
        let angle = atan2(delta.height, delta.width) + .pi / 2
        let index = (Int((angle / (.pi / 2)).rounded()) + 4) % 4
        return store.actions.indices.contains(index) ? store.actions[index] : nil
    }

    func capture(_ action: PingAction) {
        store.capture(SourceMessage.examples[sourceIndex], action: action, project: project, executor: executor)
    }

    func taskDetail(_ i: Int) -> some View {
        let task = store.tasks[i]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(task.actionName).font(.title2.bold())
                    Spacer()
                    Text(task.status).font(.caption).padding(7).background(accent.opacity(0.12), in: Capsule())
                }
                Text("\(task.app) / \(task.chat)").foregroundStyle(.secondary)
                Text(task.original).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                Text("\(task.project)  →  \(task.executor)").font(.callout.bold())
                Text("本次提示词快照").font(.headline)
                if task.status == "待确认" {
                    TextEditor(text: $store.tasks[i].promptSnapshot).frame(height: 95)
                        .onChange(of: store.tasks[i].promptSnapshot) { _ in store.save() }
                } else {
                    Text(task.promptSnapshot).font(.callout).foregroundStyle(.secondary)
                }
                Text(task.status == "待确认" ? "补充说明" : "新增信息 · 用于下一轮").font(.headline)
                TextEditor(text: $store.tasks[i].note).frame(height: 64)
                    .disabled(task.status == "模拟执行中" || task.status == "已取消" || task.status == "待核对")
                    .onChange(of: store.tasks[i].note) { _ in store.save() }
                HStack {
                    if task.status == "待确认" {
                        Button("确认提交（模拟）") { store.submit(task.id) }.buttonStyle(.borderedProminent).tint(accent)
                        Button("取消草稿") { store.cancel(task.id) }
                    } else if task.status == "模拟完成" {
                        Button("确认补充并继续（模拟）") { store.submit(task.id, continuing: true) }
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(!Identity.canContinue(task))
                    }
                }
                Text("重复 Ping 只打开此记录；续接必须添加信息并明确确认。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("推进细节").font(.headline)
                ForEach(Array(task.events.enumerated()), id: \.offset) { _, event in
                    Label(event, systemImage: "circle.fill").font(.caption).textSelection(.enabled)
                }
                if let operation = task.operationID {
                    Text("操作 ID · \(operation.prefix(16))… / 第 \(task.revision) 轮")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("每个 Ping 都有一份可编辑的内置提示词").font(.title2.bold())
                Text("修改仅影响以后新建的草稿；已有记录保留捕获时的快照。")
                    .foregroundStyle(.secondary)
                ForEach(store.actions.indices, id: \.self) { i in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: store.actions[i].symbol).foregroundStyle(accent)
                                TextField("动作名称", text: $store.actions[i].name)
                                    .onChange(of: store.actions[i].name) { _ in store.save() }
                                Text("ID: \(store.actions[i].id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            TextEditor(text: $store.actions[i].prompt).frame(height: 65)
                                .onChange(of: store.actions[i].prompt) { _ in store.save() }
                        }.padding(8)
                    }
                }
                Text("原型固定四个动作；自定义槽位、图标和快捷键属于下一阶段。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    var history: some View {
        HStack(spacing: 0) {
            List(selection: $store.selected) {
                ForEach(store.tasks) { task in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.actionName).bold()
                        Text("\(task.app) · \(task.chat)").font(.caption)
                        Text(task.status).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(task.id)
                }
            }.frame(width: 280)
            if let id = store.selected, let i = store.tasks.firstIndex(where: { $0.id == id }) {
                taskDetail(i).padding(24)
            } else {
                Text("选择一条记录查看原始材料和推进细节")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct PingTaskApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("PingTask · 原生原型") { ContentView(store: store) }
        MenuBarExtra("PingTask", systemImage: "scope") {
            Button("打开 PingTask") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Text("模拟模式 · 未连接外部 Agent")
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}

@MainActor func runChecks() {
    let key = Identity.key(source: "wechat/account/chat/message", action: "analyze", project: "repo", executor: "Codex")
    precondition(key == Identity.key(source: "wechat/account/chat/message", action: "analyze", project: "repo", executor: "Codex"))
    precondition(key != Identity.key(source: "wechat/account/chat/message", action: "implement", project: "repo", executor: "Codex"))
    precondition(key != Identity.key(source: "wechat/account/chat/message", action: "analyze", project: "repo2", executor: "Codex"))
    precondition(key != Identity.key(source: "wechat/account/chat/message", action: "analyze", project: "repo", executor: "WorkBuddy"))
    var task = TaskRecord(source: "source", app: "微信", chat: "演示", original: "示例",
                          actionID: "analyze", actionName: "分析", promptSnapshot: "original", project: "repo", executor: "Codex")
    precondition(Identity.canSubmit(task))
    task.status = "模拟执行中"
    precondition(!Identity.canSubmit(task) && !Identity.canContinue(task))
    task.status = "模拟完成"
    precondition(!Identity.canContinue(task))
    task.note = "新增复现步骤"
    precondition(Identity.canContinue(task))
    let snapshot = try! JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(task))
    precondition(snapshot.promptSnapshot == "original" && snapshot.note == task.note)
    precondition(Identity.digest([task.id.uuidString, "1"]) != Identity.digest([task.id.uuidString, "2"]))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("state.json")
    let store = Store(fileURL: file)
    let message = SourceMessage.examples[0]
    store.capture(message, action: store.actions[0], project: "repo", executor: "Codex")
    let id = store.tasks[0].id
    store.tasks[0].promptSnapshot = "用户编辑的快照"
    store.tasks[0].note = "保留我的要求"
    store.capture(message, action: store.actions[0], project: "repo", executor: "Codex")
    precondition(store.tasks.count == 1 && store.tasks[0].id == id)
    precondition(store.tasks[0].promptSnapshot == "用户编辑的快照")
    store.submit(id)
    let operation = store.tasks[0].operationID
    store.submit(id)
    precondition(store.tasks[0].revision == 1 && store.tasks[0].operationID == operation)
    precondition(store.tasks[0].events.contains(where: { $0.contains("保留我的要求") }))
    let restored = Store(fileURL: file)
    precondition(restored.tasks.count == 1 && restored.tasks[0].status == "待核对")
    precondition(restored.tasks[0].operationID == operation)
    store.actions[0].prompt = "新版模板"
    precondition(store.tasks[0].promptSnapshot == "用户编辑的快照")
    store.capture(message, action: store.actions[0], project: "other-repo", executor: "Codex")
    precondition(store.tasks.count == 2 && store.tasks[0].promptSnapshot == "新版模板")
    store.cancel(store.tasks[0].id)
    store.capture(message, action: store.actions[0], project: "other-repo", executor: "Codex")
    precondition(store.tasks.count == 3)
    print("PASS: identity boundaries, draft merge, edit preservation, double-submit guard, crash recovery, template snapshots, cancel/recapture, continuation guards, revision IDs")
}

if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated { runChecks() }
} else {
    PingTaskApp.main()
}
