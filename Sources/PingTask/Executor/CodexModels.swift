import Foundation

struct CodexSettings: Codable, Equatable {
    var executable = ""
    var tmux = "/usr/local/bin/tmux"
    var workspace = Self.defaultWorkspace.path
    var sandbox = "read-only"
    static var defaultWorkspace: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingTaskPrototype/Workspace")
    }
    static func ensureDefaultWorkspace() throws {
        do {
            try FileManager.default.createDirectory(at: defaultWorkspace, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw WxFailure(message: "无法创建默认工作目录：\(error.localizedDescription)") }
    }
    static var saved: Self {
        guard let data = UserDefaults.standard.data(forKey: "codexSettings"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if value.workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.workspace = defaultWorkspace.path
        }
        return value
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "codexSettings") }
    static func discover() -> (String?, String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versions = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".nvm/versions/node"),
                          includingPropertiesForKeys: nil)) ?? []
        let bins = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
            + versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin").path }
        func find(_ name: String) -> String? {
            bins.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return (find("codex"), find("tmux"))
    }
    func validateTools() throws {
        for (name, path) in [("Codex", executable), ("tmux", tmux)] {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw WxFailure(message: "\(name) 路径无效，请选择可执行文件的绝对路径")
            }
        }
    }
    func validate() throws {
        try validateTools()
        var directory: ObjCBool = false
        guard workspace.hasPrefix("/"), FileManager.default.fileExists(atPath: workspace, isDirectory: &directory),
              directory.boolValue else {
            throw WxFailure(message: "工作目录不存在，请使用 App 默认目录或选择已有目录")
        }
        guard ["read-only", "workspace-write"].contains(sandbox) else { throw WxFailure(message: "请选择有效的执行权限") }
    }
    func checkConnection() throws -> String {
        try validateTools()
        let version: Data
        do { version = try CodexRunner.command(executable, ["--version"]) }
        catch { throw WxFailure(message: "Codex 启动失败，请核对可执行文件及同目录的 Node 环境") }
        do { _ = try CodexRunner.command(tmux, ["-V"]) }
        catch { throw WxFailure(message: "tmux 启动失败，请核对 tmux 路径") }
        do { _ = try CodexRunner.command(executable, ["login", "status"]) }
        catch { throw WxFailure(message: "Codex 登录检查未通过，请在终端运行 codex login status 核对") }
        return "\(String(decoding: version.prefix(100), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) · tmux 可用 · 已登录"
    }
}

// One immutable, uniquely reserved initial submission per Ping task.
// Later conversation happens in Codex itself, not a second automatic submission.
struct CodexSubmission: Codable {
    let taskID: UUID
    let operationID: String
    let created: Date
    let settings: CodexSettings
    let prompt: String
    let imagePaths: [String]
    let payloadHash: String
    var workBuddy: WorkBuddySettings? = nil
    var executorName: String { workBuddy == nil ? "Codex" : "WorkBuddy" }
    var tmuxName: String { "ping-" + taskID.uuidString.lowercased() }
}

struct CodexProgress: Codable, Equatable {
    var sessionID: String?
    var status = "准备启动"
    var output = ""
    var updated = Date()
    var exitCode: Int32?
    var completedTurn = false
    mutating func consume(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "thread.started":
            if let id = event["thread_id"] as? String, UUID(uuidString: id) != nil { sessionID = id }
            status = "Codex 执行中"
        case "turn.started": status = "Codex 执行中"
        case "turn.completed": completedTurn = true
        case "turn.failed":
            status = "执行失败"
            append((event["error"] as? [String: Any])?["message"] as? String ?? "Codex 报告执行失败")
        case "error": append(event["message"] as? String ?? "Codex 返回错误")
        case "item.started", "item.completed", "item.updated":
            guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String else { break }
            if kind == "agent_message", type == "item.completed" { append(item["text"] as? String ?? "") }
            if kind == "command_execution", type == "item.started" { append("执行命令：\(item["command"] as? String ?? "")") }
            if kind == "file_change", type == "item.completed" { append("Codex 更新了工作区文件") }
        default: break
        }
        updated = Date()
    }
    mutating func append(_ text: String) { output = String((output + "\n" + text).suffix(32_000)) }
}

struct CodexLink: Codable, Equatable {
    let operationID: String
    let directory: String
    let workspace: String
    let tmuxName: String
    var progress: CodexProgress
}

enum CodexFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingTaskPrototype/Codex")
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
