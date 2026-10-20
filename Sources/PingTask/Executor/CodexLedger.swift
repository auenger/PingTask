import Foundation
import CSQLite

// Durable outbox reservation. A dispatching row is never blindly relaunched after a crash.
final class CodexLedger {
    private var db: OpaquePointer?
    let root: URL
    init(root: URL = CodexFiles.root) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(root.appendingPathComponent("submissions.sqlite").path, &db) == SQLITE_OK else {
            throw WxFailure(message: "无法打开 Codex 提交数据库")
        }
        sqlite3_busy_timeout(db, 3000)
        try sql("PRAGMA journal_mode=WAL")
        try sql("PRAGMA synchronous=FULL")
        try sql("CREATE TABLE IF NOT EXISTS submissions (task TEXT PRIMARY KEY, operation TEXT UNIQUE NOT NULL, payload TEXT NOT NULL, phase TEXT NOT NULL)")
    }
    deinit { sqlite3_close(db) }
    private func sql(_ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw WxFailure(message: "Codex 提交数据库操作失败") }
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw WxFailure(message: "无法读取 Codex 提交记录") }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return stmt
    }
    func reserve(_ submission: CodexSubmission) throws {
        let payload = String(decoding: try JSONEncoder().encode(submission), as: UTF8.self)
        let stmt = try statement("INSERT INTO submissions(task, operation, payload, phase) VALUES(?,?,?,'queued')",
                                 [submission.taskID.uuidString, submission.operationID, payload])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WxFailure(message: "此任务已有提交；请刷新状态并找回原会话，不会重复启动") }
    }
    func claim(_ id: UUID) throws -> Bool {
        let stmt = try statement("UPDATE submissions SET phase='dispatching' WHERE task=? AND phase='queued'", [id.uuidString])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw WxFailure(message: "无法领取 Codex 提交") }
        return sqlite3_changes(db) == 1
    }
    func all() throws -> [(CodexSubmission, String)] {
        let stmt = try statement("SELECT payload, phase FROM submissions", [])
        defer { sqlite3_finalize(stmt) }
        var rows: [(CodexSubmission, String)] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let payload = String(cString: sqlite3_column_text(stmt, 0))
            let phase = String(cString: sqlite3_column_text(stmt, 1))
            rows.append((try JSONDecoder().decode(CodexSubmission.self, from: Data(payload.utf8)), phase))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw WxFailure(message: "Codex 提交记录读取未完成") }
        return rows
    }
}
