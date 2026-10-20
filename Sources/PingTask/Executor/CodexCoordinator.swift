import Foundation
import AppKit

extension Store {
    func isSimulation(_ task: TaskRecord) -> Bool {
        isolated || task.source.contains("/demo-account/")
    }
    func submitCodex(_ id: UUID) {
        guard !codexBusy.contains(id), let task = tasks.first(where: { $0.id == id }),
              Identity.canSubmit(task), task.codex == nil else { return }
        guard task.executor == "Codex" else { notice = "WorkBuddy 尚未接入"; return }
        guard tasks.filter({ $0.codex != nil && $0.codex?.progress.exitCode == nil }).count + codexBusy.count < 4 else {
            notice = "最多同时跟踪 4 个未结束的 Codex 执行；请先完成或核对现有任务"
            return
        }
        let settings = codexSettings
        do { try settings.validate() } catch { notice = error.localizedDescription; return }
        let worker = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        codexBusy.insert(id)
        notice = "正在保存提交快照并启动 Codex…"
        Task {
            do {
                let link = try await Task.detached(priority: .userInitiated) {
                    let submission = try CodexRunner.prepare(task: task, settings: settings)
                    try CodexRunner.launch(submission, root: CodexFiles.root, worker: worker)
                    return CodexRunner.link(submission)
                }.value
                applyCodex(link, id: id)
                notice = "已交给 tmux 中的 Codex CLI；关闭 PingTask 不会中断任务"
            } catch {
                notice = "未确认启动成功：\(error.localizedDescription)。刷新状态核对原提交，不会自动重复派发。"
                await refreshCodex()
            }
            codexBusy.remove(id)
        }
    }
    func applyCodex(_ link: CodexLink, id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let old = tasks[i]
        tasks[i].codex = link
        tasks[i].operationID = link.operationID
        tasks[i].revision = max(1, tasks[i].revision)
        tasks[i].status = link.progress.status
        tasks[i].updated = link.progress.updated
        if old.codex == nil { tasks[i].events.append("已冻结初次提交；工作目录：\(link.workspace)") }
        if old.status != tasks[i].status { tasks[i].events.append(tasks[i].status) }
        if old.codex?.progress.sessionID == nil, let session = link.progress.sessionID {
            tasks[i].events.append("Codex session：\(session)")
        }
        if old.codex != link { save() }
    }
    func refreshCodex(activeOnly: Bool = false) async {
        guard !isolated, !refreshingCodex else { return }
        let ids = Set(tasks.filter {
            !isSimulation($0) && (!activeOnly || ($0.codex != nil && $0.codex?.progress.exitCode == nil && $0.status != "状态待核对"))
        }.map(\.id))
        guard !ids.isEmpty else { return }
        refreshingCodex = true
        defer { refreshingCodex = false }
        let worker = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        do {
            let links = try await Task.detached(priority: .utility) { () -> [(UUID, CodexLink)] in
                guard FileManager.default.fileExists(atPath: CodexFiles.root.appendingPathComponent("submissions.sqlite").path) else { return [] }
                let rows = try CodexLedger().all()
                var result: [(UUID, CodexLink)] = []
                for (submission, phase) in rows where ids.contains(submission.taskID) {
                    // A queued record has never been claimed; the durable claim precedes launch.
                    // Claimed records are only observed, never automatically relaunched.
                    if phase == "queued" { try CodexRunner.launch(submission, root: CodexFiles.root, worker: worker) }
                    result.append((submission.taskID, CodexRunner.link(submission)))
                }
                return result
            }.value
            for (id, link) in links { applyCodex(link, id: id) }
        } catch { notice = "无法核对 Codex 状态：\(error.localizedDescription)" }
    }
    func openCodex(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), let link = task.codex else { return }
        Task {
            do {
                let url = try await Task.detached {
                    let directory = URL(fileURLWithPath: link.directory)
                    let submission = try CodexFiles.read(CodexSubmission.self, at: directory.appendingPathComponent("submission.json"))
                    return try CodexRunner.terminalScript(submission, link: link)
                }.value
                NSWorkspace.shared.open(url)
                notice = "已打开 CLI 入口；外部继续对话后的进度以 Codex 为准"
            } catch { notice = "无法打开 Codex：\(error.localizedDescription)" }
        }
    }
}
