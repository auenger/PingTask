import Foundation

struct WorkBuddySettings: Codable, Equatable {
    var appPath = "/Applications/WorkBuddy.app"
    var python = "/usr/bin/python3"
    var model = "hy3"
    var allowEdits = false
    static var saved: Self {
        guard let data = UserDefaults.standard.data(forKey: "workBuddySettings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "workBuddySettings") }
    static var driver: URL { PingArtwork.resourceBundle.url(forResource: "driver", withExtension: "py")! }
    func validate() throws {
        guard appPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: appPath + "/Contents/MacOS/Electron"),
              FileManager.default.fileExists(atPath: appPath + "/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"),
              python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python), !model.isEmpty else {
            throw WxFailure(message: "请核对 WorkBuddy 安装目录、Python 3 和模型 ID")
        }
    }
    func check() throws -> String {
        try validate()
        let data = try CLIProcess.run(path: python, arguments: [Self.driver.path, "--check", appPath], timeout: 30)
        struct Result: Decodable { let ok: Bool; let message: String }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.ok else { throw WxFailure(message: result.message) }
        return "WorkBuddy CLI 与本机 IPC 可用；模型执行尚需任务验收。"
    }
}
