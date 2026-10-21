import Foundation
import Darwin

struct WxFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Runs only off the main actor. No shell, no raw stderr in UI/logs, bounded output and time.
enum CLIProcess {
    static func run(path: String, arguments: [String], timeout: TimeInterval = 30, environment: [String: String]? = nil) throws -> Data {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw WxFailure(message: "请选择可执行的 wxview 绝对路径")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // On macOS, assigning nil clears the child's environment (including HOME).
        // Leave this property untouched unless the caller supplies an override.
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let buffer = OutputBuffer()
        let errorBuffer = OutputBuffer()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            defer { reader.leave() }
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if !buffer.append(chunk) { kill(process.processIdentifier, SIGKILL); break }
            }
        }
        reader.enter()
        DispatchQueue.global().async {
            defer { reader.leave() }
            while let chunk = try? errorPipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                // Drain everything but retain only a small prefix for classification.
                errorBuffer.data.append(chunk.prefix(max(0, 8192 - errorBuffer.data.count)))
            }
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        reader.wait()
        try? pipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        guard !timedOut else { throw WxFailure(message: "wxview 查询超时；未自动重试") }
        guard !buffer.overflow else { throw WxFailure(message: "wxview 输出超过 8 MB，请缩小查询范围") }
        guard process.terminationStatus == 0 else {
            throw WxFailure(message: failureMessage(stderr: errorBuffer.data, exitCode: process.terminationStatus, command: arguments.first ?? ""))
        }
        return buffer.data
    }
    static let dataAccessMessage = "macOS 拒绝读取微信数据。辅助功能和屏幕录制不包含这项权限；请在系统设置的“完整磁盘访问权限”中授权当前 PingTask，再退出并重新打开。"
    static func failureMessage(stderr: Data, exitCode: Int32, command: String) -> String {
        let detail = String(decoding: stderr, as: UTF8.self).lowercased()
        let stage = ["version": "版本检查", "me": "账号识别", "cache": "缓存检查", "contacts": "会话查询",
                     "messages": "消息读取", "search": "消息检索"][command] ?? "命令执行"
        let reason: String
        if detail.contains("$home is not defined") {
            reason = "子进程缺少 HOME 环境变量，无法定位微信目录；请重新打开最新版 PingTask。"
        } else if detail.contains("operation not permitted") || detail.contains("permission denied") {
            reason = dataAccessMessage
        } else if detail.contains("no wechat contact database") || detail.contains("detect wechat data root") {
            reason = "未找到可读取的微信数据目录；请确认这台 Mac 的微信已登录并生成本地数据。"
        } else if detail.contains("executable file not found") {
            reason = "运行依赖未找到，请检查本机命令环境。"
        } else {
            reason = "wxview 未成功完成，请检查本地缓存状态；不会自动初始化密钥。"
        }
        // Never surface raw stderr: it may contain account paths, queries or private content.
        return "\(stage)失败（退出码 \(exitCode)）：\(reason)"
    }
    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
        var overflow = false
        func append(_ chunk: Data) -> Bool {
            guard data.count + chunk.count <= 8 * 1024 * 1024 else { overflow = true; return false }
            data.append(chunk)
            return true
        }
    }
}

struct WxAccount: Decodable, Equatable {
    let account: String
    let username: String
    let displayName: String
    let dataDirFingerprint: String
    let dataDir: String
    var key: String { Identity.digest([account, username, dataDirFingerprint]) }
}
struct WxIdentity: Decodable { let schemaVersion: Int; let account: WxAccount }
struct WxContact: Decodable, Identifiable {
    let username: String
    let remark: String
    let nickName: String
    let alias: String
    var lastTimestamp: Int64? = nil
    var unreadCount: Int? = nil
    var summary: String? = nil
    var id: String { username }
    var name: String { [remark, nickName, alias, username].first { !$0.isEmpty } ?? username }
}
struct WxPage: Decodable {
    struct Meta: Decodable {
        let schemaVersion: Int
        let timezone: String
        let username: String
        let start: String
        let end: String
        let hasMore: Bool
        var nextArgs: [String]? = nil
        var order: String? = nil
        var nextCursor: String? = nil
    }
    let meta: Meta
    let items: [WxMessage]
}
struct WxMessage: Decodable, Identifiable {
    let id: String
    let chatUsername: String
    let chatDisplayName: String
    let fromUsername: String
    let time: String
    let type: Int
    let content: String
    let contentDetail: [String: String]?
    var createTime: Int? = nil
    var text: String {
        // Never persist raw XML, URLs, local media paths, or CDN secrets.
        if let text = contentDetail?["text"], !text.isEmpty, !text.contains("<") { return String(text.prefix(12000)) }
        if let title = contentDetail?["title"], !title.isEmpty, !title.contains("<") { return "[分享] " + String(title.prefix(1000)) }
        if type == 1 && !content.contains("<") { return String(content.prefix(12000)) }
        return "[非文本消息，未读取媒体内容]"
    }
    func source(account: WxAccount, page: WxPage, readAt: Date) -> SourceMessage {
        let evidence = "wxview 本地已同步记录 · 手动选择消息\n账号：\(account.username) · 消息时间：\(time)\n会话 ID：\(chatUsername) · 本地消息 ID：\(id) · 发言人：\(fromUsername)\n查询：\(page.meta.start) — \(page.meta.end)（\(page.meta.timezone)）\n读取：\(readAt.formatted()) · 本页 \(page.items.count) 条\(page.meta.hasMore ? "，有更多消息，已截断" : "，此查询范围已读完")\n仅保存选中消息；文本最多 12000 字，媒体未读取。缓存可能延迟，不保证手机端完整性。"
        return SourceMessage(id: id, app: "微信", chat: chatDisplayName.isEmpty ? chatUsername : chatDisplayName, sender: fromUsername, text: text,
                             resolvedAnchor: Identity.digest(["wechat", account.key, chatUsername, id]), evidence: evidence)
    }
}

struct WxviewAdapter {
    let path: String
    var execute: (String, [String]) throws -> Data = { try CLIProcess.run(path: $0, arguments: $1) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
    func identity() throws -> WxAccount {
        let result = try Self.decode(WxIdentity.self, execute(path, ["me", "--format", "json", "--detail", "paths"]))
        guard result.schemaVersion == 1, !result.account.username.isEmpty, !result.account.dataDirFingerprint.isEmpty else {
            throw WxFailure(message: "不支持的 wxview 账号协议")
        }
        return result.account
    }
    // This CLI has no macOS account selector. Fail closed for multiple local accounts.
    func checkSingleAccount(_ account: WxAccount) throws {
        let root = URL(fileURLWithPath: account.dataDir).deletingLastPathComponent().deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let candidates = entries.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("db_storage/contact/contact.db").path) }
        guard candidates.count == 1, candidates[0].lastPathComponent == account.account else {
            throw WxFailure(message: "发现多账号或账号目录变化；当前 wxview 不支持固定 macOS 账号，已停止查询")
        }
    }
    func checked(_ account: WxAccount, args: [String]) throws -> Data {
        try checkSingleAccount(account)
        guard try identity() == account else { throw WxFailure(message: "微信账号已变化，请重新连接") }
        let data = try execute(path, args)
        try checkSingleAccount(account)
        guard try identity() == account else { throw WxFailure(message: "查询期间账号变化，结果已丢弃，请重新连接") }
        return data
    }
    func contacts(account: WxAccount, query: String, kind: String) throws -> [WxContact] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ["friend", "chatroom", "all"].contains(kind) else {
            throw WxFailure(message: "请输入联系人或群名")
        }
        return try Self.decode([WxContact].self, checked(account, args: ["contacts", "--kind", kind, "--query", query, "--limit", "20", "--format", "json"]))
    }
    func messages(account: WxAccount, contact: WxContact, date: String) throws -> WxPage {
        let page = try Self.decode(WxPage.self, checked(account, args: ["messages", "--username", contact.username, "--date", date, "--limit", "100", "--format", "json"]))
        guard page.meta.schemaVersion == 1, page.meta.username == contact.username,
              page.items.count <= 100, page.items.allSatisfy({ $0.chatUsername == contact.username && !$0.id.isEmpty }),
              Set(page.items.map(\.id)).count == page.items.count else {
            throw WxFailure(message: "wxview 返回的会话或消息协议不一致，结果已丢弃")
        }
        return page
    }
}
