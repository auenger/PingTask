import Foundation

@MainActor func runWxviewChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-wx-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let dataDir = directory.appendingPathComponent("account-a/db_storage")
    try FileManager.default.createDirectory(at: dataDir.appendingPathComponent("contact"), withIntermediateDirectories: true)
    try Data().write(to: dataDir.appendingPathComponent("contact/contact.db"))
    let identity: [String: Any] = ["schema_version": 1, "account": ["account": "account-a", "username": "self-a", "display_name": "测试账号", "data_dir_fingerprint": "test-fingerprint", "data_dir": dataDir.path]]
    let identityData = try JSONSerialization.data(withJSONObject: identity)
    let pageData = Data(#"{"meta":{"schema_version":1,"timezone":"Asia/Shanghai","username":"chat-a","start":"2026-10-01","end":"2026-10-01","has_more":true},"items":[{"id":"local-1","chat_username":"chat-a","chat_display_name":"测试群","from_username":"sender","time":"2026-10-01 12:00:00","type":49,"content":"<xml>secret-token</xml>","content_detail":{"title":"测试标题"}}]}"#.utf8)
    var calls: [[String]] = []
    var changed = false
    var changeDuringSearch = false
    var wrongConversation = false
    let adapter = WxviewAdapter(path: "/fixture/wxview", execute: { _, args in
        calls.append(args)
        if args.first == "me" {
            if changed {
                var other = identity
                var account = other["account"] as! [String: String]
                account["username"] = "self-b"; other["account"] = account
                return try JSONSerialization.data(withJSONObject: other)
            }
            return identityData
        }
        if args.first == "search" {
            var envelope = try JSONSerialization.jsonObject(with: pageData) as! [String: Any]
            var meta = envelope["meta"] as! [String: Any]
            meta["total_matches"] = 1; meta["returned"] = 1
            if wrongConversation { meta["username"] = "another-chat" }
            envelope["meta"] = meta
            if changeDuringSearch { changed = true }
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        if args.first == "contacts" {
            return Data(#"[{"username":"chat-a","remark":"测试群","nick_name":"","alias":""}]"#.utf8)
        }
        return pageData
    })
    let account = try adapter.identity()
    let hostileQuery = "群名 $(touch SHOULD_NOT_EXIST); '"
    let contacts = try adapter.contacts(account: account, query: hostileQuery, kind: "chatroom")
    precondition(calls.contains(["contacts", "--kind", "chatroom", "--query", hostileQuery, "--limit", "20", "--format", "json"]))
    let page = try adapter.messages(account: account, contact: contacts[0], date: "2026-10-01")
    let source = page.items[0].source(account: account, page: page, readAt: Date())
    precondition(source.text == "[分享] 测试标题" && !source.text.contains("secret-token"))
    precondition(source.evidence!.contains("截断"))
    let otherAccount = WxAccount(account: "account-b", username: "self-b", displayName: "B", dataDirFingerprint: "b", dataDir: "/fixture")
    precondition(source.anchor != page.items[0].source(account: otherAccount, page: page, readAt: Date()).anchor)
    let store = Store(fileURL: directory.appendingPathComponent("state.json"))
    store.capture(source, action: store.actions[0], executor: "Codex")
    store.tasks[0].promptSnapshot = "用户编辑"
    store.capture(source, action: store.actions[0], executor: "Codex")
    precondition(store.tasks.count == 1 && store.tasks[0].promptSnapshot == "用户编辑")
    let restored = Store(fileURL: directory.appendingPathComponent("state.json"))
    precondition(restored.tasks[0].evidence == source.evidence)
    let serialized = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
    precondition(!serialized.contains("secret-token"))
    let search = try adapter.searchMessages(account: account, conversation: "chat-a", query: hostileQuery,
                                            start: "2026-09-01", end: "2026-10-01")
    precondition(search.items.count == 1)
    precondition(calls.contains(["search", "--username", "chat-a", "--query", hostileQuery, "--start", "2026-09-01", "--end", "2026-10-01", "--limit", "20", "--format", "json"]))
    wrongConversation = true
    do { _ = try adapter.searchMessages(account: account, conversation: "chat-a", query: "abc", start: "2026-09-01", end: "2026-10-01"); preconditionFailure("wrong conversation must fail") } catch {}
    wrongConversation = false; changeDuringSearch = true
    do { _ = try adapter.searchMessages(account: account, conversation: "chat-a", query: "abc", start: "2026-09-01", end: "2026-10-01"); preconditionFailure("account changed during lookup must fail") } catch {}
    changeDuringSearch = false
    changed = true
    let count = calls.count
    do { _ = try adapter.contacts(account: account, query: "测试", kind: "chatroom"); preconditionFailure("account change must fail") }
    catch { precondition(calls.count == count + 1) }
    changed = false
    let otherDir = directory.appendingPathComponent("account-b/db_storage/contact")
    try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    try Data().write(to: otherDir.appendingPathComponent("contact.db"))
    do { try adapter.checkSingleAccount(account); preconditionFailure("multiple accounts must fail") } catch {}
    let literal = try CLIProcess.run(path: "/usr/bin/printf", arguments: ["%s", hostileQuery])
    precondition(String(decoding: literal, as: UTF8.self) == hostileQuery)
    do { _ = try CLIProcess.run(path: "/bin/sleep", arguments: ["5"], timeout: 0.05); preconditionFailure("timeout must fail") } catch {}
    print("PASS: wxview schema, bounded argv, XML exclusion, account isolation, truncation evidence, real-source draft merge/persistence, subprocess timeout")
}
