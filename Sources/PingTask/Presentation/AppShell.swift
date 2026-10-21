import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var desktop: DesktopPingController
    var initialTab = 4
    @StateObject private var wechat = WeChatSourceModel()
    @State private var realSource: SourceMessage?
    @State private var tab = 4
    @State private var taskSearch = ""
    @State private var taskFilter = "全部"
    @State private var sourceIndex = 0
    @State private var executor = "Codex"
    @State private var hovered: String?
    @State private var capturingAttachment = false
    private let accent = AppStyle.gold

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case 4: DesktopCaptureView(model: desktop, store: store, openSettings: { tab = 6 }, openTasks: { tab = 2 })
                    case 1: IntentSettingsView(store: store, desktop: desktop)
                    case 2: history
                    case 3: WeChatSourceView(model: wechat) { source in
                        realSource = source; tab = 0
                        store.notice = "已选择微信消息，选择意图后创建草稿"
                    }
                    case 6: AppSettingsView(store: store, desktop: desktop, openPractice: { realSource = nil; tab = 0 })
                    default: workspace
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(accent)
                    Text(store.notice).lineLimit(2)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
            }.background(AppStyle.canvas)
        }
        .frame(minWidth: 1180, minHeight: 780)
        .preferredColorScheme(.dark).tint(accent)
        .onAppear { tab = initialTab }
        .task {
            if !store.isolated {
                wechat.start()
                do {
                    try await Task.detached { try CodexSettings.ensureDefaultWorkspace() }.value
                    store.codexSettings.save()
                } catch { store.notice = error.localizedDescription }
            }
            await store.refreshCodex()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                if store.tasks.contains(where: { $0.codex != nil && $0.codex?.progress.exitCode == nil && $0.status != "状态待核对" }) {
                    await store.refreshCodex(activeOnly: true)
                }
            }
        }
        .onChange(of: desktop.navigation) { _ in tab = 4 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in desktop.permissions() }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PingTask").font(.system(size: 20, weight: .semibold))
                    Text("指向 · 表达 · 推进").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 32)
            navItem(4, "桌面 Ping", "cursorarrow.rays")
            navItem(2, "任务记录", "tray.full", count: store.tasks.filter { $0.status == "待确认" }.count)
            navItem(1, "Ping 意图", "circle.grid.cross")
            Text("偏好与连接").font(.caption2.weight(.medium)).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.top, 28).padding(.bottom, 6)
            navItem(3, "微信连接", "bubble.left.and.bubble.right")
            navItem(6, "设置", "slider.horizontal.3")
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(desktop.enabled ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(desktop.enabled ? "全局 Ping 已开启" : "全局 Ping 未开启").font(.caption)
                }
                Text("触发方式  \(desktop.triggerLabel)").font(.caption2).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 16)
        }.padding(.horizontal, 12).frame(width: 188).background(AppStyle.sidebar)
    }
    func navItem(_ id: Int, _ title: String, _ symbol: String, count: Int = 0) -> some View {
        Button { tab = id } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: tab == id ? .semibold : .regular))
                Spacer()
                if count > 0 { Text("\(count)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(accent.opacity(0.15), in: Capsule()) }
            }.foregroundStyle(tab == id ? accent : Color.secondary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(tab == id ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    var workspace: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text("01  指向一条消息").font(.headline)
                if realSource == nil {
                    Label("交互练习 · 以下为虚构消息", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    Picker("消息来源", selection: $sourceIndex) {
                        ForEach(SourceMessage.examples.indices, id: \.self) { i in
                            Text(SourceMessage.examples[i].app).tag(i)
                        }
                    }.pickerStyle(.segmented)
                    Button("从微信选择真实消息") { tab = 3 }
                } else {
                    Button("更换微信消息") { tab = 3 }
                }
                let source = realSource ?? SourceMessage.examples[sourceIndex]
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(source.chat)  ·  \(source.sender)").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(source.text).font(.title3).lineSpacing(5) }.frame(maxHeight: 100)
                    if let media = source.media { Label("将附带：\(media.name)", systemImage: "paperclip").font(.caption) }
                    Text(source.resolvedAnchor == nil ? "虚构消息 · 固定消息 ID · 模拟执行" : "真实本地缓存消息 · 用户确认后交给执行器").font(.caption2).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                Text("02  选择 Ping 意图").font(.headline)
                wheel
                Text("点击动作，或从中心按住拖向动作后松手。\n重复选择同一动作，可验证草稿合并。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("执行器", selection: $executor) {
                    Text(realSource == nil ? "Codex（模拟）" : "Codex CLI").tag("Codex")
                    Text(realSource == nil ? "WorkBuddy（模拟）" : "WorkBuddy Agent").tag("WorkBuddy")
                }
            } }.frame(width: 420)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("03  确认与推进").font(.headline)
                if let id = store.selected, let i = store.tasks.firstIndex(where: { $0.id == id }) {
                    taskDetail(i)
                } else {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(accent)
                    Text("任务意图先落成草稿").font(.title2)
                    Text("在左侧选择一个动作，确认卡会出现在这里。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
    }

    var wheel: some View {
        ZStack {
            DesktopWheelView(actions: store.wheelActions, selected: store.wheelActions.firstIndex { $0.id == hovered }, trigger: desktop.trigger, centerArtwork: store.centerArtwork)
            ForEach(Array(store.wheelActions.enumerated()), id: \.element.id) { i, action in
                let angle = CaptureGeometry.angle(index: i, count: store.wheelActions.count)
                Button { capture(action) } label: {
                    Color.clear.frame(width: 80, height: 80).contentShape(Rectangle())
                }.buttonStyle(.plain).offset(x: cos(angle) * 98, y: sin(angle) * 98)
                    .accessibilityLabel(action.name)
                    .onHover { hovered = $0 ? action.id : nil }
            }
            Circle().fill(Color.clear).frame(width: 89, height: 89).contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { hovered = actionAt($0.translation)?.id }
                    .onEnded { value in
                        if let action = actionAt(value.translation) { capture(action) }
                        hovered = nil
                    })
        }.frame(width: 380, height: 410).frame(maxWidth: .infinity)
    }

    func actionAt(_ delta: CGSize) -> PingAction? {
        guard hypot(delta.width, delta.height) > 48 else { return nil }
        guard let index = CaptureGeometry.slice(delta: CGPoint(x: delta.width, y: delta.height), count: store.wheelActions.count) else { return nil }
        return store.wheelActions[index]
    }

    func capture(_ action: PingAction) {
        if !action.createsTask { desktop.playEffect(action); return }
        guard !capturingAttachment else { return }
        let source = realSource ?? SourceMessage.examples[sourceIndex], executor = executor
        let existing = store.tasks.contains { Identity.key($0) == Identity.key(source: source.anchor, action: action.id, executor: executor) && $0.status != "已取消" }
        guard let media = source.media, !existing else { store.capture(source, action: action, executor: executor); return }
        capturingAttachment = true; store.notice = "正在保存附件副本…"
        Task {
            defer { capturingAttachment = false }
            do {
                let attachment = try await MediaIO.shared.snapshot(media)
                let saved = store.capture(source, action: action, executor: executor, attachments: [attachment])
                if !saved || !store.tasks.contains(where: { ($0.attachments ?? []).contains(where: { $0.id == attachment.id }) }) {
                    try? FileManager.default.removeItem(atPath: attachment.path)
                }
            } catch { store.notice = "附件无法保存：请核对本机文件是否存在、大小及读取权限。" }
        }
    }

    func taskText(_ id: UUID, _ keyPath: WritableKeyPath<TaskRecord, String>) -> Binding<String> {
        Binding(get: { store.tasks.first { $0.id == id }?[keyPath: keyPath] ?? "" }, set: { value in
            guard let index = store.tasks.firstIndex(where: { $0.id == id }) else { return }
            store.tasks[index][keyPath: keyPath] = value; store.save()
        })
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
                if let evidence = task.evidence { Text(evidence).font(.caption).foregroundStyle(.secondary) }
                if let capture = task.captures?.last {
                    CapturePreview(capture: capture).frame(maxHeight: 230)
                    Button(task.requiresSourceConfirmation == true ? "定位并核对来源" : "查看截图与定位证据") { desktop.review(task); tab = 4 }
                    if task.requiresSourceConfirmation == true { Text("截图来源尚未确认，不能提交").foregroundStyle(.orange) }
                }
                Text(task.original).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                ForEach(task.attachments ?? []) { attachment in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(attachment.name, systemImage: "paperclip")
                        Text("已保存独立副本 · 提交时告知 Agent 分析\(attachment.isThumbnail ? " · 仅缩略图" : "")").font(.caption).foregroundStyle(.secondary)
                        Button("查看附件副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)]) }
                    }
                }
                Text("执行器 · \(task.executor)").font(.callout.bold())
                if !store.isSimulation(task), ["Codex", "WorkBuddy"].contains(task.executor) {
                    CodexTaskView(store: store, task: task)
                }
                Text("本次提示词快照").font(.headline)
                if task.status == "待确认" {
                    TextEditor(text: taskText(task.id, \.promptSnapshot)).font(.system(size: 13)).scrollContentBackground(.hidden)
                        .frame(height: 95).padding(12).background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))

                } else {
                    Text(task.promptSnapshot).font(.callout).foregroundStyle(.secondary)
                }
                Text(task.status == "待确认" ? "补充说明" : "新增信息 · 用于下一轮").font(.headline)
                TextEditor(text: taskText(task.id, \.note)).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(height: 64).padding(12).background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .disabled(task.status != "待确认" && task.status != "模拟完成")

                HStack {
                    if task.status == "待确认" {
                        Button(store.isSimulation(task) ? "确认提交（模拟）" : "确认交给 \(task.executor)") { store.submit(task.id) }
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(!Identity.canSubmit(task) || store.codexBusy.contains(task.id) || (!store.isSimulation(task) && !["Codex", "WorkBuddy"].contains(task.executor)))

                    } else if task.status == "模拟完成" {
                        Button("确认补充并继续（模拟）") { store.submit(task.id, continuing: true) }
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(!Identity.canContinue(task))
                    }
                }
                TaskRecordControls(store: store, desktop: desktop, taskID: task.id)
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
                .disabled(store.codexBusy.contains(task.id))
        }
    }

    var filteredTasks: [TaskRecord] {
        store.tasks.filter { task in
            (taskFilter == "全部" || (taskFilter == "待确认" ? task.status == "待确认" : task.status != "待确认")) &&
            (taskSearch.isEmpty || "\(task.actionName) \(task.chat) \(task.original)".localizedCaseInsensitiveContains(taskSearch))
        }
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(title: "任务记录", subtitle: "从捕获到确认，每一次推进都有迹可循。")
            HStack {
                Picker("范围", selection: $taskFilter) {
                    Text("全部").tag("全部"); Text("待确认").tag("待确认"); Text("其他记录").tag("其他记录")
                }.pickerStyle(.segmented).frame(width: 280)
                Spacer()
                TextField("搜索意图、会话或正文", text: $taskSearch).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            if store.tasks.isEmpty {
                QuietEmptyState(symbol: "tray", title: "还没有任务", message: "在桌面指向一条信息，使用任务意图 Ping 一下。草稿会出现在这里。")
            } else {
                HStack(spacing: 0) {
                    if filteredTasks.isEmpty {
                        Text("没有匹配的记录").foregroundStyle(.secondary).frame(width: 260)
                    } else {
                        List(selection: $store.selected) {
                            ForEach(filteredTasks) { task in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(task.actionName).fontWeight(.semibold); Spacer(); Text(task.status).font(.caption2).foregroundStyle(accent) }
                                    Text("\(task.app) · \(task.chat)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(task.original).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(task.updated, style: .date).font(.caption2).foregroundStyle(.tertiary)
                                }.padding(.vertical, 9).tag(task.id)
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden).frame(width: 270)
                    }
                    Divider().padding(.horizontal, 20)
                    if let id = store.selected, filteredTasks.contains(where: { $0.id == id }), let i = store.tasks.firstIndex(where: { $0.id == id }) {
                        taskDetail(i)
                    } else {
                        QuietEmptyState(symbol: "doc.text.magnifyingglass", title: "选择一条记录", message: "查看来源、编辑草稿，或回顾任务的推进过程。")
                    }
                }
            }
        }.padding(28)
    }
}
