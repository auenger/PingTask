import AppKit
import SwiftUI
import CoreText
import Vision

@MainActor func runDesktopChecks() throws {
    for trigger in PingTrigger.allCases {
        precondition(!trigger.isOther(trigger.mask))
        precondition(trigger.isOther([trigger.mask, .maskCommand]))
        precondition(trigger.isOther([.maskAlternate, .maskControl]))
        precondition(PingTrigger(rawValue: trigger.rawValue) == trigger)
    }
    let shortcut = PingKeyboardShortcut(keyCode: 35, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, keyLabel: "P")
    precondition(shortcut.matches(key: 35, flags: [.maskControl, .maskAlternate]))
    precondition(!shortcut.matches(key: 35, flags: [.maskControl]))
    precondition(!shortcut.matches(key: 35, flags: [.maskControl, .maskAlternate, .maskCommand]))
    precondition(!shortcut.matches(key: 49, flags: [.maskControl, .maskAlternate]))
    precondition(shortcut.label == "⌃⌥ P")
    let shortcutData = try JSONEncoder().encode(shortcut)
    let decodedShortcut = try JSONDecoder().decode(PingKeyboardShortcut.self, from: shortcutData)
    precondition(decodedShortcut == shortcut)
    var chord = PingShortcutState()
    precondition(chord.down(matches: false, point: .zero) == nil && !chord.held)
    precondition(chord.down(matches: true, point: .zero) == .begin(.zero))
    precondition(chord.down(matches: true, point: .zero) == nil) // Key repeat cannot re-arm.
    chord.cancel()
    precondition(chord.held && !chord.active)
    precondition(chord.down(matches: true, point: .zero) == nil)
    precondition(chord.up(point: .zero) == nil && !chord.held)
    precondition(chord.down(matches: true, point: .zero) == .begin(.zero))
    precondition(chord.up(point: CGPoint(x: 80, y: 0)) == .release(CGPoint(x: 80, y: 0)))
    precondition(chord.up(point: .zero) == nil)
    for name in PingArtwork.names { precondition(PingArtwork.image(name) != nil, "Missing bundled artwork: \(name)") }
    var gesture = PingInputState()
    precondition(gesture.flags(option: true, other: false, point: .zero) == .begin(.zero))
    precondition(gesture.flags(option: true, other: true, point: .zero) == .cancel)
    precondition(gesture.flags(option: true, other: false, point: .zero) == nil)
    precondition(gesture.flags(option: false, other: false, point: .zero) == nil)
    precondition(gesture.flags(option: true, other: false, point: .zero) == .begin(.zero))
    precondition(gesture.flags(option: false, other: false, point: CGPoint(x: 80, y: 0)) == .release(CGPoint(x: 80, y: 0)))
    precondition(gesture.flags(option: false, other: false, point: .zero) == nil)
    _ = gesture.flags(option: true, other: false, point: .zero)
    precondition(gesture.flags(option: false, other: true, point: .zero) == .cancel)
    var right = PingRightDragState()
    let anchor = CGPoint(x: -300, y: 200)
    let near = CGPoint(x: -290, y: 200)
    let selected = CGPoint(x: -220, y: 200)
    right.down(at: anchor)
    precondition(right.move(to: near).isEmpty) // Exactly 10 points still counts as a click.
    let click = right.up(at: near)
    precondition(click.replayClick && click.signal == nil && right.origin == nil)
    right.down(at: anchor)
    precondition(right.move(to: selected) == [.begin(anchor), .move(selected)])
    precondition(right.move(to: anchor) == [.move(anchor)])
    let centered = right.up(at: anchor)
    precondition(!centered.replayClick && centered.signal == .release(anchor))
    precondition(CaptureGeometry.slice(delta: .zero) == nil) // Returning to center never becomes a context click.
    right.down(at: anchor)
    _ = right.move(to: selected)
    let released = right.up(at: selected)
    precondition(!released.replayClick && released.signal == .release(selected))
    precondition(right.up(at: selected).signal == nil) // One release per gesture.
    for crossedThreshold in [false, true] {
        right.down(at: anchor)
        if crossedThreshold { _ = right.move(to: selected) }
        right.cancel() // Esc, modifier, trigger change, busy rejection, or gesture expiry.
        precondition(right.move(to: selected).isEmpty)
        let canceled = right.up(at: selected)
        precondition(!canceled.replayClick && canceled.signal == nil && right.origin == nil)
    }
    right.down(at: anchor)
    right.cancel()
    right.down(at: anchor) // Fresh down recovers from a missing mouse-up.
    precondition(right.up(at: anchor).replayClick) // Cancellation does not poison the next click.
    precondition(CaptureGeometry.slice(delta: .zero) == nil)
    precondition(CaptureGeometry.slice(delta: CGPoint(x: 46, y: 0)) == nil)
    precondition(CaptureGeometry.slice(delta: CGPoint(x: 0, y: -80)) == 0)
    precondition(CaptureGeometry.slice(delta: CGPoint(x: 80, y: 0)) == 1)
    precondition(CaptureGeometry.slice(delta: CGPoint(x: 0, y: 80)) == 2)
    precondition(CaptureGeometry.slice(delta: CGPoint(x: -80, y: 0)) == 3)
    precondition(CaptureGeometry.appKitPoint(CGPoint(x: -800, y: -100), primaryHeight: 900) == CGPoint(x: -800, y: 1000))
    let target = DesktopTarget(windowID: 99, processID: 1, appName: "测试微信", bundleID: "com.tencent.xinWeChat", title: "测试群 (12)",
                               bounds: CGRect(x: -900, y: 200, width: 800, height: 600), pointer: CGPoint(x: -500, y: 500), displayID: 2, scale: 2)
    var inputTarget = target
    inputTarget.elementRole = "AXTextArea"
    precondition(inputTarget.isTextEntry && !target.isTextEntry)
    let restoredTarget = try JSONDecoder().decode(DesktopTarget.self, from: JSONEncoder().encode(inputTarget))
    precondition(restoredTarget.isTextEntry)
    precondition(CaptureGeometry.normalizedPointer(target) == CGPoint(x: 0.5, y: 0.5))
    let lines = [OCRLine(text: "测试消息的正文", bounds: CGRect(x: 0.4, y: 0.48, width: 0.3, height: 0.04), confidence: 0.99),
                 OCRLine(text: "不相关消息", bounds: CGRect(x: 0.4, y: 0.2, width: 0.3, height: 0.04), confidence: 0.99)]
    precondition(CaptureGeometry.pointedLine(lines, target: target)?.text == "测试消息的正文")
    precondition(CaptureGeometry.pointedLine([lines[1]], target: target) == nil)
    let capture = DesktopCapture(id: UUID(), created: Date(), target: target, pixelWidth: 1600, pixelHeight: 1200, lines: lines)
    precondition(MessageClues.titles(capture) == ["测试群"])
    let contacts = [WxContact(username: "group-a", remark: "测试群", nickName: "", alias: ""),
                    WxContact(username: "group-b", remark: "测试群二", nickName: "", alias: "")]
    precondition(MessageClues.exactContacts(contacts, title: "测试群（12）").map(\.id) == ["group-a"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-desktop-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = Store(fileURL: directory.appendingPathComponent("state.json"))
    let source = SourceMessage(id: capture.id.uuidString, app: "微信", chat: "待定位", sender: "OCR", text: capture.pointedText,
                               resolvedAnchor: "capture/\(capture.id.uuidString)", evidence: capture.evidence)
    store.capture(source, action: store.actions[0], executor: "Codex", desktopCapture: capture)
    let pendingID = store.tasks[0].id
    store.submit(pendingID)
    precondition(store.tasks[0].revision == 0 && !Identity.canSubmit(store.tasks[0]))
    let live = SourceMessage(id: "msg", app: "微信", chat: "测试群", sender: "测试发言人", text: "缓存原文",
                             resolvedAnchor: "real/account/chat/msg", evidence: "已核对")
    store.tasks[0].promptSnapshot = "我的编辑"
    store.resolveDesktop(pendingID, source: live)
    precondition(store.tasks[0].promptSnapshot == "我的编辑" && Identity.canSubmit(store.tasks[0]))
    precondition(store.tasks[0].original == "缓存原文" && store.tasks[0].captures?.count == 1)
    // Another capture of the same message must merge without losing the existing user's edits.
    store.capture(source, action: store.actions[0], executor: "Codex", desktopCapture: capture)
    let duplicate = store.selected!
    store.resolveDesktop(duplicate, source: live)
    precondition(store.tasks.count == 1 && store.selected == pendingID && store.tasks[0].promptSnapshot == "我的编辑")
    precondition(store.tasks[0].captures?.count == 2)
    let restored = Store(fileURL: directory.appendingPathComponent("state.json"))
    precondition(restored.tasks[0].captures?.last?.target.bounds == target.bounds)
    store.capture(source, action: store.actions[1], executor: "Codex", desktopCapture: capture)
    let screenshotID = store.selected!
    store.keepDesktopScreenshot(screenshotID)
    precondition(Identity.canSubmit(store.tasks.first { $0.id == screenshotID }!))
    precondition(store.tasks.first { $0.id == screenshotID }!.source.hasPrefix("capture/"))
    let blocker = directory.appendingPathComponent("not-a-directory")
    try Data().write(to: blocker)
    let failingStore = Store(fileURL: blocker.appendingPathComponent("state.json"))
    precondition(!failingStore.capture(source, action: store.actions[0], executor: "Codex", desktopCapture: capture))
    precondition(failingStore.tasks.isEmpty && failingStore.selected == nil)
    let retainedID = store.tasks.first { $0.id != screenshotID }!.id
    var trashed: [URL] = []
    precondition(store.deleteTask(screenshotID, trash: { trashed.append($0) }))
    precondition(trashed.isEmpty, "Shared screenshot must be retained")
    store.submit(retainedID)
    precondition(store.cancel(retainedID))
    precondition(store.tasks[0].status == "已取消")
    RunLoop.main.run(until: Date().addingTimeInterval(1.7))
    precondition(store.tasks[0].status == "已取消", "Delayed simulation must not complete a canceled task")
    precondition(store.deleteTask(retainedID, trash: { trashed.append($0) }))
    precondition(Set(trashed).count == 1 && trashed.count == 1)
    precondition(store.tasks.isEmpty && store.selected == nil)
    precondition(Store(fileURL: directory.appendingPathComponent("state.json")).tasks.isEmpty)
    precondition(!store.deleteTask(UUID(), trash: { _ in preconditionFailure() }))
    failingStore.tasks = restored.tasks; failingStore.selected = restored.tasks.first!.id
    let failedID = failingStore.selected!
    failingStore.tasks[0].status = "模拟执行中"
    precondition(!failingStore.cancel(failedID) && failingStore.tasks[0].status == "模拟执行中")
    precondition(!failingStore.deleteTask(failedID, trash: { _ in preconditionFailure() }))
    precondition(failingStore.selected == failedID && !failingStore.tasks.isEmpty)
    var fun = PingAction.defaults[0]; fun.effectOnly = true
    precondition(!store.capture(source, action: fun, executor: "Codex", desktopCapture: capture))
    precondition(store.tasks.isEmpty && store.selected == nil)
    store.actions[0] = fun; precondition(store.save())
    precondition(Store(fileURL: directory.appendingPathComponent("state.json")).actions[0].effectOnly == true)
    let legacyAction = Data(#"{"id":"analyze","name":"分析","symbol":"star","prompt":"旧模板"}"#.utf8)
    let decodedAction = try JSONDecoder().decode(PingAction.self, from: legacyAction)
    precondition(decodedAction.createsTask)
    print("PASS: trigger mapping, right-drag threshold/click/cancel/release, custom shortcut matching/persistence/repeat/cancellation, bundled artwork, cancel running, deletion persistence/shared captures/rollback, effect-only guard and legacy template decoding")
    let pageData = Data(#"{"meta":{"schema_version":1,"timezone":"Asia/Shanghai","username":"group-a","start":"2026-09-01","end":"2026-10-01","total_matches":22,"returned":0},"items":[]}"#.utf8)
    let page = try WxviewAdapter.decode(WxSearchPage.self, pageData)
    precondition(page.contextPage.meta.hasMore)
    try runVisionFixtureCheck()
    print("PASS: modifier cancellation/release lifecycle, wheel dead zone/directions, multi-display coordinates, pointer OCR gating, title ambiguity, unconfirmed dispatch guard, resolved source merge/edit preservation, capture persistence, explicit screenshot fallback")
}

@MainActor func renderWheelPreview(to url: URL) throws {
    _ = NSApplication.shared
    let extended = PingAction.defaults + (0..<4).map { index in
        PingAction(id: "fixture-\(index)", name: ["开心", "请求视野", "问号", "捂脸"][index], symbol: "star",
                   artwork: ["lp_emotes_bee_happy", "need_vision", "enemy_missing_flipped", "lp_emotes_facepalm"][index], effectOnly: true, prompt: "")
    }
    let view = VStack(spacing: 0) {
        HStack(spacing: 0) { DesktopWheelView(actions: PingAction.defaults, selected: nil); DesktopWheelView(actions: PingAction.defaults, selected: 0) }
        HStack(spacing: 0) { DesktopWheelView(actions: extended, selected: 5, centerArtwork: "lp_emotes_poro_snax"); DesktopWheelView(actions: [], selected: nil) }
    }.padding(20).background(Color(red: 0.12, green: 0.15, blue: 0.19))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw WxFailure(message: "轮盘渲染失败") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WxFailure(message: "轮盘 PNG 编码失败") }
    try data.write(to: url)
    print("PASS: rendered synthetic wheel preview")
}

@MainActor private func runVisionFixtureCheck() throws {
    let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    let text = NSAttributedString(string: "PingTask anchor 12345", attributes: [
        .font: CTFontCreateWithName("Helvetica" as CFString, 28, nil),
        .foregroundColor: CGColor(gray: 0, alpha: 1)
    ])
    context.textPosition = CGPoint(x: 80, y: 170)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: context.makeImage()!).perform([request])
    let lines = (request.results ?? []).compactMap { result -> OCRLine? in
        guard let top = result.topCandidates(1).first else { return nil }
        return OCRLine(text: top.string, bounds: result.boundingBox, confidence: top.confidence)
    }
    precondition(lines.contains { $0.text.contains("anchor 12345") }, "Vision must read the synthetic anchor")
    let target = DesktopTarget(windowID: 1, processID: 1, appName: "fixture", bundleID: "fixture", title: "fixture",
                               bounds: CGRect(x: 0, y: 0, width: 640, height: 360), pointer: CGPoint(x: 180, y: 180), displayID: 1, scale: 1)
    precondition(CaptureGeometry.pointedLine(lines, target: target)?.text.contains("anchor 12345") == true)
    print("PASS: real Vision OCR on a generated image and pointer-to-text mapping (no screen capture)")
}

@MainActor func renderDesktopPreview(to url: URL, tab: Int = 4) throws {
    _ = NSApplication.shared
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-preview-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = Store(fileURL: file)
    if tab == 2 {
        store.capture(SourceMessage.examples[0], action: store.actions[0], executor: "Codex")
    }
    let model = DesktopPingController(store: store)
    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-media-preview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let wxFixture = tab == 9 ? try wxPreviewFixture(root: fixtureRoot) : nil
    if tab == 10 {
        model.conversationQuery = "合成项目群"
        model.enterpriseContext = EnterpriseContext(identity: LarkIdentity(profile: "fixture", app: "app", brand: "lark", user: "user"), chatID: "oc_fixture", chatName: "合成项目群",
            messages: [EnterpriseMessage(id: "om_fixture", chat: "oc_fixture", text: "请分析这次需求变更，并整理下一步任务。此消息是界面测试数据。", sender: "测试成员", time: "2026-10-21 10:30")], hasMore: true, start: Date().addingTimeInterval(-86400), end: Date())
    }
    if tab == 11 {
        let target = DesktopTarget(windowID: 1, processID: 1, appName: "微信（合成预览）", bundleID: "com.tencent.xinWeChat", title: "合成联系人",
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), pointer: CGPoint(x: 500, y: 400), displayID: 1, scale: 1)
        let capture = DesktopCapture(id: UUID(), created: Date(), target: target, pixelWidth: 1000, pixelHeight: 800,
            lines: [OCRLine(text: "请整理一下 下周的任务，并且列出依赖", bounds: CGRect(x: 0.3, y: 0.48, width: 0.6, height: 0.04), confidence: 0.5)])
        store.capture(SourceMessage(id: "fixture", app: "微信", chat: "待核对", sender: "OCR", text: capture.pointedText,
            resolvedAnchor: "capture/fixture"), action: store.actions[0], executor: "Codex", desktopCapture: capture)
        model.capture = capture; model.taskID = store.selected
        model.conversationQuery = "合成联系人"; model.messageQuery = capture.pointedText
        model.account = WxAccount(account: "fixture", username: "self", displayName: "演示账号", dataDirFingerprint: "fixture", dataDir: "/example/fixture")
        let contact = WxContact(username: "fixture-chat", remark: "合成联系人", nickName: "", alias: "")
        model.contacts = [contact]; model.chosenContact = contact
        model.results = WxSearchPage(meta: .init(schemaVersion: 1, timezone: "Asia/Shanghai", username: contact.username,
            start: "2026-09-22", end: "2026-10-22", totalMatches: 1, returned: 1), items: [
                WxMessage(id: "fixture-message", chatUsername: contact.username, chatDisplayName: contact.name, fromUsername: "测试成员",
                    time: "2026-10-22 12:00:00", type: 1, content: "请整理一下下周的任务，并且列出依赖和验收条件。此消息为合成数据。", contentDetail: nil)])
        model.status = "合成预览：会话已定位，消息候选待核对；不读取真实聊天。"
    }
    let content = Group {
        if tab == 10 {
            ScrollView { EnterpriseCaptureView(model: model, store: store, platform: .lark).padding(28) }
                .background(AppStyle.canvas).preferredColorScheme(.dark)
        } else if let wxFixture {
            WeChatSourceView(model: wxFixture, select: { _ in }).background(AppStyle.canvas).preferredColorScheme(.dark)
        } else if tab == 8 {
            ArtworkPicker(store: store, current: "png_enemymissing_128x128", choose: { _ in })
        } else if tab == 7 {
            ScrollView {
                CodexResponseView(markdown: """
                # 执行结果预览
                已完成 **任务详情** 的展示调整，保留 `session ID` 以继续对话。

                ## 本次变更
                - 支持 Markdown 预览与原文切换
                - [x] 全文复制与代码块复制
                - [ ] 在实际任务中确认交互

                > 此处为虚构输出，只用于界面预览。

                ```swift
                let message = "Hello, PingTask"
                print(message)
                ```

                | 项目 | 状态 |
                | --- | --- |
                | 结果展示 | 已实现 |
                | 实际任务验收 | 待确认 |

                支持 **加粗**、*强调*、`行内代码` 与 [链接](https://example.com)。
                """).padding(28)
            }.frame(width: 920, height: 860).background(AppStyle.canvas).preferredColorScheme(.dark)
        } else {
            ContentView(store: store, desktop: model, initialTab: tab == 11 ? 4 : tab)
        }
    }.frame(width: 1280, height: 860)
    let hosting = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1280, height: 860),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(tab == 9 ? 1.5 : 0.4))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw WxFailure(message: "App page bitmap unavailable")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw WxFailure(message: "App page encoding failed")
    }
    try data.write(to: url)
    print("Generated app page preview using an isolated offscreen window")
}
