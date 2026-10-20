import SwiftUI
import AppKit
import CryptoKit
import ApplicationServices

struct PingAction: Codable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var effectOnly: Bool? = nil
    var createsTask: Bool { effectOnly != true }
    var prompt: String
    static let defaults: [PingAction] = [
        .init(id: "analyze", name: "分析一下", symbol: "sparkle.magnifyingglass",
              prompt: "分析目标消息及相关上下文。区分已知事实、推断和待确认问题。给出建议与下一步，不修改代码。"),
        .init(id: "plan", name: "拆成任务", symbol: "checklist",
              prompt: "将讨论整理成可执行任务，列出目标、依赖、验收条件和待澄清问题。不向外部平台发布任务。"),
        .init(id: "implement", name: "开始处理", symbol: "hammer",
              prompt: "分析并实现明确的需求，运行相关验证，报告改动和结果。遇到关键缺失信息时提出问题。"),
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
    var resolvedAnchor: String? = nil
    var evidence: String? = nil
    var anchor: String { resolvedAnchor ?? "\(app)/demo-account/\(chat)/\(id)" }
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
    var executor: String
    var evidence: String? = nil
    var captures: [DesktopCapture]? = nil
    var requiresSourceConfirmation: Bool? = nil
    var note = ""
    var status = "待确认"
    var revision = 0
    var operationID: String?
    var codex: CodexLink? = nil
    var events: [String] = []
    var updated = Date()
}

enum Identity {
    static func digest(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func key(source: String, action: String, executor: String) -> String {
        digest([source, action, executor])
    }
    static func key(_ task: TaskRecord) -> String {
        key(source: task.source, action: task.actionID, executor: task.executor)
    }
    static func canSubmit(_ task: TaskRecord) -> Bool { task.status == "待确认" && task.requiresSourceConfirmation != true }
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
    @Published var notice = "就绪 · 截图与任务记录仅保存在本机"
    @Published var codexSettings = CodexSettings.saved
    @Published var codexBusy = Set<UUID>()
    var refreshingCodex = false
    let isolated: Bool
    private let file: URL

    init(fileURL: URL? = nil) {
        isolated = fileURL != nil
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

    @discardableResult func capture(_ source: SourceMessage, action: PingAction, executor: String, desktopCapture: DesktopCapture? = nil) -> Bool {
        let prior = tasks, priorSelection = selected
        guard action.createsTask else { notice = "仅播放特效，不创建任务"; return false }
        let key = Identity.key(source: source.anchor, action: action.id, executor: executor)
        if let index = tasks.firstIndex(where: { Identity.key($0) == key && $0.status != "已取消" }) {
            selected = tasks[index].id
            tasks[index].events.append("再次 Ping：打开已有记录，未提交新任务")
            tasks[index].updated = Date()
            notice = "已合并重复 Ping · \(tasks[index].actionName)"
        } else {
            var task = TaskRecord(source: source.anchor, app: source.app, chat: source.chat,
                                  original: source.text, actionID: action.id, actionName: action.name,
                                  promptSnapshot: action.prompt, executor: executor)
            task.evidence = source.evidence
            if let desktopCapture { task.captures = [desktopCapture]; task.requiresSourceConfirmation = true }
            task.events = [source.resolvedAnchor == nil ? "已捕获模拟消息，创建待确认草稿" : "已选择真实微信消息，创建待确认草稿；尚未提交执行"]
            if desktopCapture != nil { task.events = ["已保存真实窗口截图与意图；来源待核对，未派发"] }
            tasks.insert(task, at: 0)
            selected = task.id
            notice = "已生成确认卡 · 查看内容后再提交"
        }
        guard save() else { tasks = prior; selected = priorSelection; return false }
        return true
    }

    @discardableResult func resolveDesktop(_ id: UUID, source: SourceMessage) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status == "待确认",
              tasks[i].requiresSourceConfirmation == true else { return false }
        let prior = tasks
        let key = Identity.key(source: source.anchor, action: tasks[i].actionID, executor: tasks[i].executor)
        if let existing = tasks.firstIndex(where: { $0.id != id && Identity.key($0) == key && $0.status != "已取消" }) {
            tasks[existing].captures = (tasks[existing].captures ?? []) + (tasks[i].captures ?? [])
            tasks[existing].events.append("再次桌面 Ping 并确认同一消息：打开已有记录，保留编辑与提交快照")
            selected = tasks[existing].id
            tasks.remove(at: i)
        } else {
            tasks[i].source = source.anchor; tasks[i].app = source.app; tasks[i].chat = source.chat
            tasks[i].original = source.text; tasks[i].evidence = source.evidence
            tasks[i].requiresSourceConfirmation = false
            tasks[i].events.append("用户确认 wxview 消息候选，来源身份已绑定")
            selected = id
        }
        if !save() { tasks = prior; selected = id; return false }
        return true
    }

    @discardableResult func keepDesktopScreenshot(_ id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].status == "待确认",
              tasks[i].requiresSourceConfirmation == true else { return false }
        let prior = tasks[i]
        tasks[i].requiresSourceConfirmation = false
        tasks[i].events.append("用户明确保留截图来源；未定位聊天消息，不按 OCR 自动去重")
        if !save() { tasks[i] = prior; return false }
        return true
    }

    func submit(_ id: UUID, continuing: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if !isSimulation(tasks[index]) {
            guard !continuing else { notice = "请打开已关联的 Codex CLI 对话继续推进"; return }
            submitCodex(id)
            return
        }
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

    @discardableResult func cancel(_ id: UUID) -> Bool {
        guard !codexBusy.contains(id), let i = tasks.firstIndex(where: { $0.id == id }),
              ["待确认", "模拟执行中"].contains(tasks[i].status) else { return false }
        let prior = tasks[i]
        tasks[i].status = "已取消"
        tasks[i].updated = Date()
        tasks[i].events.append(prior.status == "待确认" ? "用户取消草稿，未创建外部任务" : "用户停止本地模拟执行")
        guard save() else { tasks[i] = prior; return false }
        notice = "任务已取消"
        return true
    }
    @discardableResult func deleteTask(_ id: UUID, trash: (URL) throws -> Void = {
        if FileManager.default.fileExists(atPath: $0.path) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }) -> Bool {
        guard !codexBusy.contains(id), let removed = tasks.first(where: { $0.id == id }) else { return false }
        guard removed.codex == nil || removed.codex?.progress.exitCode != nil else {
            notice = "请先在 Codex CLI 核对执行结束，再删除本地记录"
            return false
        }
        let prior = tasks, selection = selected
        tasks.removeAll { $0.id == id }
        if selected == id { selected = tasks.first?.id }
        guard save() else { tasks = prior; selected = selection; return false }
        let retained = Set(tasks.flatMap { $0.captures ?? [] }.map(\.id))
        var cleaned = Set<UUID>()
        var cleanupFailed = false
        for capture in removed.captures ?? [] where !retained.contains(capture.id) && cleaned.insert(capture.id).inserted {
            do { try trash(capture.imageURL) } catch { cleanupFailed = true }
        }
        notice = cleanupFailed ? "记录已删除；部分截图未能移入废纸篓，仍保留在本机。" : "本地记录已删除，独占截图已移入废纸篓"
        return true
    }
}

struct PingTaskApp: App {
    @StateObject private var store: Store
    @StateObject private var desktop: DesktopPingController
    init() {
        if let url = Bundle.main.url(forResource: "PingTask", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        } else if let icon = PingArtwork.image("png_enemymissing_128x128") {
            NSApplication.shared.applicationIconImage = icon
        }
        let store = Store()
        _store = StateObject(wrappedValue: store)
        _desktop = StateObject(wrappedValue: DesktopPingController(store: store))
    }
    var body: some Scene {
        WindowGroup("PingTask") { ContentView(store: store, desktop: desktop) }
            .defaultSize(width: 1280, height: 860)
        MenuBarExtra {
            Button("打开 PingTask") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Button(desktop.enabled ? "停用全局 Ping" : "启用全局 Ping") { desktop.setEnabled(!desktop.enabled) }
            Button("桌面 Ping") {
                desktop.showReview()
            }
            Text("Codex CLI · tmux")
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: AppStyle.menuBarIcon).accessibilityLabel("PingTask")
        }
    }
}

@MainActor func runChecks() {
    let key = Identity.key(source: "wechat/account/chat/message", action: "analyze", executor: "Codex")
    precondition(key == Identity.key(source: "wechat/account/chat/message", action: "analyze", executor: "Codex"))
    precondition(key != Identity.key(source: "wechat/account/chat/message", action: "implement", executor: "Codex"))
    precondition(key != Identity.key(source: "wechat/account/chat/message", action: "analyze", executor: "WorkBuddy"))
    var task = TaskRecord(source: "source", app: "微信", chat: "演示", original: "示例",
                          actionID: "analyze", actionName: "分析", promptSnapshot: "original", executor: "Codex")
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
    store.capture(message, action: store.actions[0], executor: "Codex")
    let id = store.tasks[0].id
    store.tasks[0].promptSnapshot = "用户编辑的快照"
    store.tasks[0].note = "保留我的要求"
    store.capture(message, action: store.actions[0], executor: "Codex")
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
    store.capture(message, action: store.actions[0], executor: "WorkBuddy")
    precondition(store.tasks.count == 2 && store.tasks[0].promptSnapshot == "新版模板")
    store.cancel(store.tasks[0].id)
    store.capture(message, action: store.actions[0], executor: "WorkBuddy")
    precondition(store.tasks.count == 3)
    print("PASS: identity boundaries, draft merge, edit preservation, double-submit guard, crash recovery, template snapshots, cancel/recapture, continuation guards, revision IDs")
}

if let index = CommandLine.arguments.firstIndex(of: "--codex-worker"), CommandLine.arguments.count > index + 1 {
    do { try CodexRunner.worker(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
    catch { fputs("PingTask worker: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--process-environment-check") {
    do {
        let inherited = try CLIProcess.run(path: "/usr/bin/printenv", arguments: ["HOME"])
        precondition(String(decoding: inherited, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == ProcessInfo.processInfo.environment["HOME"])
        let overridden = try CLIProcess.run(path: "/usr/bin/printenv", arguments: ["HOME"], environment: ["HOME": "/fixture-home"])
        precondition(String(decoding: overridden, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "/fixture-home")
        let permission = CLIProcess.failureMessage(stderr: Data("error: /private/account: operation not permitted".utf8), exitCode: 1, command: "me")
        precondition(permission.contains("macOS 拒绝") && !permission.contains("/private/account"))
        print("PASS: inherited HOME, explicit environment override, sanitized error classification")
    } catch { fputs("Environment check failed\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--wxview-connection-check") {
    let path = UserDefaults.standard.string(forKey: "wxviewPath") ?? ""
    do {
        let adapter = WxviewAdapter(path: path)
        _ = try adapter.execute(path, ["version"])
        print("wxview version: OK")
        let account = try adapter.identity()
        print("wxview identity: OK")
        try adapter.checkSingleAccount(account)
        _ = try adapter.checked(account, args: ["cache", "status", "--format", "json"])
        print("wxview cache: OK")
    } catch {
        fputs("\((error as? WxFailure)?.message ?? "wxview 账号目录或协议检查失败")\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--codex-connection-check") {
    do {
        try CodexSettings.ensureDefaultWorkspace()
        var settings = CodexSettings.saved
        let paths = CodexSettings.discover()
        if settings.executable.isEmpty { settings.executable = paths.0 ?? "" }
        print(try settings.checkConnection())
        print("Default workspace: \(CodexSettings.defaultWorkspace.path)")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--codex-check") {
    do { try runCodexChecks() }
    catch { fputs("Codex check: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated {
        runChecks()
        do { try runWxviewChecks(); try runDesktopChecks() } catch { fatalError("wxview fixture checks failed: \(error)") }
    }
} else if CommandLine.arguments.contains("--render-wheel") {
    MainActor.assumeIsolated {
        do { try renderWheelPreview(to: URL(fileURLWithPath: CommandLine.arguments.last!)) }
        catch { fatalError("Wheel rendering failed: \(error)") }
    }
} else if CommandLine.arguments.contains("--render-desktop") {
    MainActor.assumeIsolated {
        do { try renderDesktopPreview(to: URL(fileURLWithPath: CommandLine.arguments.last!), tab: CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[2]) ?? 4 : 4) }
        catch { fatalError("Desktop page rendering failed: \(error)") }
    }
} else if CommandLine.arguments.contains("--capture-permissions") {
    print("Screen recording: \(CGPreflightScreenCaptureAccess())")
    print("Accessibility: \(AXIsProcessTrusted())")
} else {
    PingTaskApp.main()
}
