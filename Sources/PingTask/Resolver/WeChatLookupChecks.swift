import Foundation

// Synthetic CLI only: exercise the same account checks and resolver path as a real Ping.
func runWeChatLookupChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-lookup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let dataDir = root.appendingPathComponent("account/db_storage")
    try FileManager.default.createDirectory(at: dataDir.appendingPathComponent("contact"), withIntermediateDirectories: true)
    try Data().write(to: dataDir.appendingPathComponent("contact/contact.db"))
    let identity = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "account": [
        "account": "account", "username": "self", "display_name": "Fixture", "data_dir_fingerprint": "fixture", "data_dir": dataDir.path]])
    let pointed = "自动识别 给测试员工记录一个 任务，并且定时"
    let original = "请自动识别给测试员工记录一个任务，并且定时更新进度。"
    var queries: [String] = [], contextCalls = 0, total = 1
    var candidateText = original, ambiguousContact = false, truncated = false, failFirstSearch = false
    let adapter = WxviewAdapter(path: "/fixture/wxview", execute: { _, args in
        func value(_ flag: String) -> String { args.firstIndex(of: flag).map { args[$0 + 1] } ?? "" }
        switch args.first {
        case "me": return identity
        case "contacts":
            var contacts = [["username": "chat", "remark": "合成联系人", "nick_name": "", "alias": ""]]
            if ambiguousContact { contacts.append(["username": "other", "remark": "合成联系人", "nick_name": "", "alias": ""]) }
            return try JSONSerialization.data(withJSONObject: contacts)
        case "search":
            let query = value("--query"); queries.append(query)
            precondition(value("--username") == "chat" && value("--limit") == "20")
            precondition(value("--start") == "2026-09-22" && value("--end") == "2026-10-22")
            precondition(!args.contains("--refresh"))
            if failFirstSearch { throw WxFailure(message: "Fixture query failed") }
            let found = original.contains(query)
            let items: [[String: Any]] = found ? [["id": "message", "chat_username": "chat", "chat_display_name": "合成联系人",
                "from_username": "sender", "time": "2026-10-22 12:00:00", "create_time": 1792641600,
                "type": 1, "content": candidateText]] : []
            return try JSONSerialization.data(withJSONObject: ["meta": ["schema_version": 1, "timezone": "Asia/Shanghai",
                "username": "chat", "start": "2026-09-22", "end": "2026-10-22", "total_matches": found ? total : 0, "returned": items.count], "items": items])
        case "messages":
            contextCalls += 1
            precondition(value("--username") == "chat" && value("--limit") == "100")
            return try JSONSerialization.data(withJSONObject: ["meta": ["schema_version": 1, "timezone": "Asia/Shanghai",
                "username": "chat", "start": "2026-10-22 11:45:00", "end": "2026-10-22 12:15:00", "has_more": truncated],
                "items": [["id": "message", "chat_username": "chat", "chat_display_name": "合成联系人", "from_username": "sender",
                           "time": "2026-10-22 12:00:00", "create_time": 1792641600, "type": 1, "content": candidateText]]])
        default: preconditionFailure("Unexpected fixture CLI command")
        }
    })
    let target = DesktopTarget(windowID: 1, processID: 1, appName: "微信", bundleID: "com.tencent.xinWeChat", title: "合成联系人",
        bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), pointer: CGPoint(x: 500, y: 400), displayID: 1, scale: 1)
    let date = ISO8601DateFormatter().date(from: "2026-10-22T04:00:00Z")!
    func capture(_ text: String) -> DesktopCapture {
        DesktopCapture(id: UUID(), created: date, target: target, pixelWidth: 1000, pixelHeight: 800,
            lines: [OCRLine(text: text, bounds: CGRect(x: 0.3, y: 0.48, width: 0.6, height: 0.04), confidence: 0.5)])
    }
    let source = try AutomaticWeChat.resolve(capture: capture(pointed), adapter: adapter)
    precondition(source.text.contains(original) && source.anchor != "capture/fixture" && contextCalls == 1)
    precondition(queries.first == pointed && queries.count > 1 && queries.count <= 4)
    precondition(source.evidence?.contains("完整匹配") == true)
    // A candidate hit alone cannot submit: only the complete normalized pointed text qualifies.
    candidateText = "只匹配给测试员工记录一个片段，其他内容不同。"
    do { _ = try AutomaticWeChat.resolve(capture: capture(pointed), adapter: adapter); preconditionFailure("Partial candidate auto-bound") }
    catch let review as WeChatCandidateReview {
        precondition(review.contact.username == "chat" && review.page?.items.count == 1 && review.account.username == "self")
    }
    precondition(contextCalls == 1)
    candidateText = original; total = 2
    do { _ = try AutomaticWeChat.resolve(capture: capture(pointed), adapter: adapter); preconditionFailure("Ambiguous message auto-bound") }
    catch is WeChatCandidateReview {}
    precondition(contextCalls == 1)
    total = 1; truncated = true
    do { _ = try AutomaticWeChat.resolve(capture: capture(pointed), adapter: adapter); preconditionFailure("Truncated context auto-bound") }
    catch let review as WeChatCandidateReview { precondition(review.reason.contains("截断")) }
    truncated = false
    do { _ = try AutomaticWeChat.resolve(capture: capture("自动识别"), adapter: adapter); preconditionFailure("Short snippet auto-bound") }
    catch is WeChatCandidateReview {}
    let before = queries.count
    ambiguousContact = true
    do { _ = try AutomaticWeChat.resolve(capture: capture(pointed), adapter: adapter); preconditionFailure("Ambiguous contact searched") }
    catch let review as WeChatConversationReview { precondition(review.contacts.count == 2) }
    precondition(queries.count == before)
    ambiguousContact = false
    queries = []
    let empty = try adapter.searchMessageCandidates(account: adapter.identity(), conversation: "chat",
        text: "没有命中片段 甲乙丙丁 戊己庚辛 壬癸子丑 寅卯辰巳", start: "2026-09-22", end: "2026-10-22")
    precondition(empty.items.isEmpty && queries.count == 4)
    failFirstSearch = true; queries = []
    do { _ = try adapter.searchMessageCandidates(account: adapter.identity(), conversation: "chat", text: pointed,
        start: "2026-09-22", end: "2026-10-22"); preconditionFailure("Error silently retried as another search") }
    catch is WxFailure {}
    precondition(queries.count == 1)
    precondition(MessageClues.searchQueries("ab").isEmpty)
    print("PASS: low-confidence OCR retrieval, bounded fragment fallback, exact full-text binding, candidate preservation, short/ambiguous/truncated rejection, no retry after CLI failure")
}
