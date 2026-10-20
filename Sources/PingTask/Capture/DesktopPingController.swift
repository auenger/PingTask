import SwiftUI
import AppKit
import ApplicationServices

@MainActor final class DesktopPingController: ObservableObject {
    @Published var trigger = PingTrigger(rawValue: UserDefaults.standard.string(forKey: "pingTrigger") ?? "") ?? .alt
    @Published var enabled = false
    @Published var busy = false
    @Published var status = "启用后，按住 ⌥ Option，移动指针选择动作，松手捕获；Esc 或回中心取消。"
    @Published var capture: DesktopCapture?
    @Published var taskID: UUID?
    @Published var conversationQuery = ""
    @Published var messageQuery = ""
    @Published var contacts: [WxContact] = []
    @Published var chosenContact: WxContact?
    @Published var results: WxSearchPage?
    @Published var account: WxAccount?
    @Published var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @Published var endDate = Date()
    @Published var navigation = UUID()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    let store: Store
    private let input = GlobalPingInput()
    private let wheel = DesktopWheelPanel()
    private let effect = PingEffectPanel()
    private var origin: CGPoint?
    private var selectionOrigin: CGPoint?
    private var pointerWarped = false
    private var target: DesktopTarget?
    private var frozenActions: [PingAction] = []
    private var wheelShown = false
    private var expiry: DispatchWorkItem?
    private var generation = UUID()
    private var adapterPath = ""
    private var reviewWindow: NSWindow?

    init(store: Store) {
        self.store = store
        input.trigger = trigger
        status = "按住 \(trigger.label)，移动选择动作，松手捕获。"
        input.receive = { [weak self] signal in self?.handle(signal) }
    }
    func setTrigger(_ value: PingTrigger) {
        guard value != trigger else { return }
        cancelGesture()
        input.disarm()
        trigger = value
        input.trigger = value
        UserDefaults.standard.set(value.rawValue, forKey: "pingTrigger")
        status = "触发键已改为 \(value.label)，松开所有按键后开始。"
    }
    func forgetDeletedTask(_ id: UUID) {
        guard taskID == id else { return }
        taskID = nil; capture = nil; contacts = []; results = nil; chosenContact = nil; account = nil
        status = "本地记录已删除"
    }
    func permissions() { accessibilityGranted = AXIsProcessTrusted(); screenGranted = CGPreflightScreenCaptureAccess() }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissions()
    }
    func requestScreen() { _ = CGRequestScreenCaptureAccess(); permissions() }
    func setEnabled(_ value: Bool) {
        if value {
            permissions()
            do { try input.start(); enabled = true; status = "全局 Ping 已启用 · 按住 \(trigger.symbol) 并移动 · 松手触发意图 · Esc 取消" }
            catch { status = (error as? WxFailure)?.message ?? "全局监听启动失败" }
        } else { enabled = false; input.stop(); cancelGesture(); status = "全局 Ping 已停用" }
    }
    private func handle(_ signal: GlobalPingInput.Signal) {
        switch signal {
        case .begin(let point):
            guard enabled, !busy else { input.disarm(); return }
            cancelGesture()
            origin = point
            frozenActions = store.actions
            target = try? DesktopCaptureService.target(at: point)
            let expiry = DispatchWorkItem { [weak self] in self?.input.disarm(); self?.cancelGesture() }
            self.expiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: expiry)
        case .move(let point):
            guard let origin else { return }
            let center = selectionOrigin ?? origin
            let delta = CGPoint(x: point.x - center.x, y: point.y - center.y)
            if !wheelShown && hypot(delta.x, delta.y) > 10 {
                wheel.state.trigger = trigger
                let center = wheel.show(at: origin, actions: frozenActions)
                selectionOrigin = center; wheelShown = true
                if hypot(center.x - origin.x, center.y - origin.y) > 1 {
                    pointerWarped = true
                    CGWarpMouseCursorPosition(center)
                    wheel.state.selected = nil
                    return
                }
            }
            if wheelShown { wheel.state.selected = CaptureGeometry.slice(delta: delta) }
        case .release(let point):
            guard let origin = selectionOrigin ?? origin, wheelShown,
                  let selected = CaptureGeometry.slice(delta: CGPoint(x: point.x - origin.x, y: point.y - origin.y)),
                  frozenActions.indices.contains(selected) else { cancelGesture(); return }
            let action = frozenActions[selected]
            let anchor = self.origin ?? point
            let capturedTarget = target
            cancelGesture()
            if !action.createsTask { playEffect(action, at: anchor); return }
            guard let capturedTarget else { status = "无法获取目标窗口；未创建任务"; return }
            guard CGPreflightScreenCaptureAccess() else { status = "此意图需要屏幕录制权限；仅特效意图无需截图权限"; showReview(); return }
            take(capturedTarget, action: action)
        case .cancel: cancelGesture()
        }
    }
    private func cancelGesture() {
        expiry?.cancel(); expiry = nil
        wheel.hide()
        if pointerWarped, let origin { CGWarpMouseCursorPosition(origin) }
        origin = nil; selectionOrigin = nil; pointerWarped = false; target = nil; wheelShown = false
    }
    func showReview() {
        navigation = UUID()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "PingTask · 桌面 Ping"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(store: store, desktop: self, initialTab: 4))
            window.center(); window.makeKeyAndOrderFront(nil)
            reviewWindow = window
        }
    }
    func playEffect(_ action: PingAction, at point: CGPoint? = nil) {
        let cursor = point ?? CGEvent(source: nil)?.location ?? .zero
        effect.show(at: cursor, action: action)
        store.notice = "已播放「\(action.name)」特效 · 未截图、未创建任务"
    }
    private func take(_ target: DesktopTarget, action: PingAction) {
        guard !busy else { return }
        busy = true; status = "正在截取目标窗口并识别指针附近文字…"
        wheel.feedback(at: target.pointer)
        // The gesture effect outlives capture progress, including fast captures.
        effect.show(at: target.pointer, action: action)
        let token = UUID(); generation = token
        Task {
            do {
                let captured = try await DesktopCaptureService.capture(target)
                guard generation == token else { return }
                let source = SourceMessage(id: captured.id.uuidString, app: target.appName,
                                           chat: "桌面来源 · 尚未定位会话", sender: "OCR（非消息身份）",
                                           text: captured.pointedText.isEmpty ? "指针附近未识别到文字，请查看截图。" : captured.pointedText,
                                           resolvedAnchor: "capture/\(captured.id.uuidString)", evidence: captured.evidence)
                guard store.capture(source, action: action, executor: "Codex", desktopCapture: captured) else {
                    try? FileManager.default.removeItem(at: captured.imageURL)
                    throw WxFailure(message: "截图草稿保存失败；请检查本地存储权限")
                }
                capture = captured
                taskID = store.selected
                prepare(captured)
                wheel.hide()
                showReview()
                busy = false
                if target.bundleID == "com.tencent.xinWeChat" { locateConversation(automatic: true) }
                else { status = "已保存截图。目标不是受支持的微信应用，可核对后仅保留截图草稿。" }
            } catch {
                wheel.hide()
                busy = false
                status = (error as? WxFailure)?.message ?? "截图或 OCR 失败，请检查屏幕录制权限后重试"
                showReview()
            }
        }
    }
    private func prepare(_ captured: DesktopCapture) {
        contacts = []; chosenContact = nil; results = nil; account = nil
        conversationQuery = MessageClues.titles(captured).first ?? ""
        messageQuery = MessageClues.keyword(captured.pointedText)
        // A declared bounded range, never an inference that the visible message was sent today.
        startDate = Calendar.current.date(byAdding: .day, value: -30, to: captured.created)!
        endDate = captured.created
        adapterPath = UserDefaults.standard.string(forKey: "wxviewPath") ?? ""
    }
    func review(_ task: TaskRecord) {
        guard !busy, let captured = task.captures?.last else { return }
        generation = UUID(); capture = captured; taskID = task.id
        prepare(captured); showReview()
        status = "已打开保存的捕获；核对 OCR 线索或修改检索范围后定位。"
    }
    func locateConversation(automatic: Bool = false) {
        guard !busy, let capture else { return }
        guard capture.target.bundleID == "com.tencent.xinWeChat" else { status = "仅对微信窗口自动查询；其他应用可保留截图。"; return }
        adapterPath = UserDefaults.standard.string(forKey: "wxviewPath") ?? ""
        guard !adapterPath.isEmpty else { status = "截图已保存；请先在微信接入页配置 wxview 路径，再点击定位。"; return }
        let titles = automatic ? MessageClues.titles(capture) : [conversationQuery]
        guard !titles.isEmpty, titles.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            status = "未识别到会话标题；请补充群名或联系人后定位。"; return
        }
        let adapter = WxviewAdapter(path: adapterPath)
        let pinned = account
        busy = true; contacts = []; results = nil; chosenContact = nil
        status = "正在用窗口标题 / OCR 查找会话候选…"
        Task {
            do {
                let resolved = try await Task.detached(priority: .userInitiated) { () -> (WxAccount, [WxContact], [WxContact]) in
                    let identity = try adapter.identity()
                    guard pinned == nil || pinned == identity else { throw WxFailure(message: "微信账号已变化；请重新打开该捕获再定位") }
                    var contacts: [WxContact] = [], exact: [WxContact] = []
                    for title in titles.prefix(3) where !title.isEmpty {
                        let found = try adapter.contacts(account: identity, query: title, kind: "all")
                        contacts += found
                        exact += MessageClues.exactContacts(found, title: title)
                    }
                    var seen = Set<String>(), exactSeen = Set<String>()
                    return (identity, contacts.filter { seen.insert($0.id).inserted }, exact.filter { exactSeen.insert($0.id).inserted })
                }.value
                account = resolved.0; contacts = resolved.1; busy = false
                if resolved.2.count == 1 && messageQuery.count >= 3 {
                    search(in: resolved.2[0])
                } else {
                    status = contacts.isEmpty ? "未找到会话候选；截图已保留，请修正会话标题。" : "会话仍需核对：选择候选后检索指针附近文字。候选最多 60 个。"
                }
            } catch { busy = false; status = (error as? WxFailure)?.message ?? "会话定位失败；截图已保留" }
        }
    }
    func search(in contact: WxContact) {
        guard !busy, let account else { return }
        guard messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { status = "指针文字不足，请从截图/OCR 补充至少 3 个字符"; return }
        guard startDate <= endDate, endDate.timeIntervalSince(startDate) <= 366 * 86400 else {
            status = "请选择不超过 366 天的有效范围"; return
        }
        chosenContact = contact; results = nil; busy = true
        let query = messageQuery, start = MessageClues.day(startDate), end = MessageClues.day(endDate)
        let adapter = WxviewAdapter(path: adapterPath)
        status = "正在会话内检索 OCR 文字（\(start) — \(end)）…"
        Task {
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try adapter.searchMessages(account: account, conversation: contact.username, query: query, start: start, end: end)
                }.value
                results = page
                status = page.items.isEmpty ? "此范围内没有匹配；可修正 OCR、调整历史日期，或保留截图草稿。" : "找到 \(page.meta.totalMatches) 条匹配，显示 \(page.items.count) 条；请核对发言人、时间和正文后确认。缓存可能延迟。"
            } catch { status = (error as? WxFailure)?.message ?? "消息定位失败；截图已保留" }
            busy = false
        }
    }
    func accept(_ message: WxMessage) {
        guard !busy, let id = taskID, let account, let page = results,
              page.items.contains(where: { $0.id == message.id && $0.chatUsername == message.chatUsername }) else { return }
        var source = message.source(account: account, page: page.contextPage, readAt: Date())
        source.evidence = (source.evidence ?? "") + "\n通过桌面 OCR 检索，用户已核对候选；搜索结果不等于完整前后上下文。"
        guard store.resolveDesktop(id, source: source) else { status = "无法更新来源，请检查记录状态或本地存储"; return }
        taskID = store.selected
        status = "已确认真实消息来源；草稿等待明确提交。"
    }
    func acceptContext(_ source: SourceMessage, anchor: WxMessage) {
        guard !busy, let id = taskID, let account, let page = results,
              page.items.contains(where: { $0.id == anchor.id && $0.chatUsername == anchor.chatUsername }),
              source.resolvedAnchor == Identity.digest(["wechat", account.key, anchor.chatUsername, anchor.id]) else { return }
        guard store.resolveDesktop(id, source: source) else { status = "无法保存上下文，请核对草稿状态"; return }
        taskID = store.selected
        status = "已确认原消息及附近上下文；可到任务记录提交。"
    }
    func keepScreenshot() {
        guard !busy, let id = taskID else { return }
        guard store.keepDesktopScreenshot(id) else { status = "无法更新截图草稿，请检查记录状态或本地存储"; return }
        status = "保留为截图来源草稿；未定位微信会话，等待明确提交。"
    }
}
