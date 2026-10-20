import Foundation

// Focused transport/persistence check: fake model, real isolated tmux session, no network/chat.
func runCodexChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask codex ' \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fake codex")
    let session = UUID().uuidString.lowercased()
    let script = """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '{"type":"thread.started","thread_id":"\(session)"}'
    printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fixture complete"}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{}}'
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    guard let tmux = CodexSettings.discover().1 else { throw WxFailure(message: "局部检查需要本机 tmux") }
    let settings = CodexSettings(executable: executable.path, tmux: tmux, workspace: root.path, sandbox: "read-only")
    let task = TaskRecord(source: "fixture", app: "fixture", chat: "fixture", original: "$(touch SHOULD_NOT_EXIST)",
                          actionID: "analyze", actionName: "fixture", promptSnapshot: "only a fixture", executor: "Codex")
    let ledgerRoot = root.appendingPathComponent("ledger")
    let submission = try CodexRunner.prepare(task: task, settings: settings, root: ledgerRoot)
    var edited = task
    edited.promptSnapshot = "must not replace the frozen payload"
    do { _ = try CodexRunner.prepare(task: edited, settings: settings, root: ledgerRoot); preconditionFailure("snapshot overwritten") } catch {}
    let frozen = try CodexFiles.read(CodexSubmission.self, at: ledgerRoot.appendingPathComponent(submission.operationID + "/submission.json"))
    precondition(frozen.prompt == submission.prompt && frozen.payloadHash == submission.payloadHash)
    let ledger = try CodexLedger(root: ledgerRoot)
    do { try ledger.reserve(submission); preconditionFailure("duplicate submission accepted") } catch {}
    try CodexRunner.launch(submission, root: ledgerRoot, worker: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
    defer { _ = try? CodexRunner.command(tmux, ["-L", CodexRunner.socket, "kill-session", "-t", submission.tmuxName]) }
    let claimedAgain = try ledger.claim(task.id)
    precondition(!claimedAgain)
    var link = CodexRunner.link(submission, root: ledgerRoot)
    for _ in 0..<50 where link.progress.exitCode == nil {
        Thread.sleep(forTimeInterval: 0.1)
        link = CodexRunner.link(submission, root: ledgerRoot)
    }
    precondition(link.progress.sessionID == session && link.progress.exitCode == 0)
    precondition(link.progress.status == "Codex 本轮完成" && link.progress.output.contains("fixture complete"))
    precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    let restored = try CodexLedger(root: ledgerRoot).all()
    precondition(restored.count == 1 && restored[0].0.payloadHash == submission.payloadHash && restored[0].1 == "dispatching")
    let entry = try CodexRunner.terminalScript(submission, link: link)
    _ = try CodexRunner.command("/bin/sh", ["-n", entry.path])
    do { try CodexRunner.worker(directory: URL(fileURLWithPath: link.directory)); preconditionFailure("worker restarted") } catch {}
    var failure = CodexProgress()
    failure.consume(Data(#"{"type":"turn.failed","error":{"message":"fixture error"}}"#.utf8))
    precondition(failure.status == "执行失败" && !failure.completedTurn)
    print("PASS: SQLite duplicate/claim/reopen, real tmux + fake Codex, session/output recovery, literal stdin, quoted CLI entry, duplicate-worker guard")
    try runWxContextChecks(root: root)
}

private func runWxContextChecks(root: URL) throws {
    let dataDir = root.appendingPathComponent("accounts/a/db_storage")
    try FileManager.default.createDirectory(at: dataDir.appendingPathComponent("contact"), withIntermediateDirectories: true)
    try Data().write(to: dataDir.appendingPathComponent("contact/contact.db"))
    let account = WxAccount(account: "a", username: "self", displayName: "fixture", dataDirFingerprint: "fixture", dataDir: dataDir.path)
    let identity: [String: Any] = ["schema_version": 1, "account": [
        "account": "a", "username": "self", "display_name": "fixture", "data_dir_fingerprint": "fixture", "data_dir": dataDir.path]]
    let items: [[String: Any]] = (0..<15).map { i in [
        "id": "m\(i)", "chat_username": "chat", "chat_display_name": "fixture", "from_username": "sender",
        "time": "2026-10-20 12:00:00", "create_time": 1800000000 + i, "type": 1, "content": "fixture \(i)"
    ] }
    let page: [String: Any] = ["meta": ["schema_version": 1, "timezone": "Asia/Shanghai", "username": "chat",
        "start": "fixture-start", "end": "fixture-end", "has_more": true], "items": items]
    var queried: [String] = []
    let adapter = WxviewAdapter(path: "/fixture", execute: { _, args in
        if args.first == "me" { return try JSONSerialization.data(withJSONObject: identity) }
        queried = args
        return try JSONSerialization.data(withJSONObject: page)
    })
    let anchor = try WxviewAdapter.decode(WxMessage.self, JSONSerialization.data(withJSONObject: items[7]))
    let context = try adapter.context(account: account, anchor: anchor)
    precondition(context.selected.count == 11 && context.selected[5].id == anchor.id)
    precondition(queried == ["messages", "--username", "chat", "--start", "1799999107", "--end", "1800000907", "--limit", "100", "--format", "json"])
    precondition(context.source(account: account).anchor == anchor.source(account: account, page: context.page, readAt: Date()).anchor)
    precondition(context.summary.contains("截断"))
    var missing = items[7]; missing["id"] = "missing"
    let unknown = try WxviewAdapter.decode(WxMessage.self, JSONSerialization.data(withJSONObject: missing))
    do { _ = try adapter.context(account: account, anchor: unknown); preconditionFailure("missing anchor accepted") } catch {}
    print("PASS: bounded wxview context argv, anchor identity, surrounding selection, truncation and missing-anchor refusal")
}
