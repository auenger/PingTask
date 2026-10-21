import Foundation

private struct WxSessions: Decodable {
    let count: Int
    let items: [Item]
    struct Item: Decodable {
        let username: String
        let chatDisplayName: String
        let lastTimestamp: Int64
        let unreadCount: Int
        let summary: String
    }
}
extension WxviewAdapter {
    func sessionPage(account: WxAccount, query: String, kind: String, offset: Int) throws -> [WxContact] {
        guard ["friend", "chatroom", "all"].contains(kind), offset >= 0 else { throw WxFailure(message: "会话筛选无效") }
        var args = ["sessions", "--kind", kind, "--limit", "100", "--offset", String(offset), "--format", "json"]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--query", query] }
        return try Self.decodeSessions(checked(account, args: args))
    }
    static func decodeSessions(_ data: Data) throws -> [WxContact] {
        let result = try decode(WxSessions.self, data)
        guard result.count == result.items.count, result.items.count <= 100,
              Set(result.items.map(\.username)).count == result.items.count,
              result.items.allSatisfy({ !$0.username.isEmpty && $0.lastTimestamp >= 0 }),
              zip(result.items,result.items.dropFirst()).allSatisfy({ $0.0.lastTimestamp >= $0.1.lastTimestamp }) else {
            throw WxFailure(message: "最近会话排序或响应异常")
        }
        return result.items.map {
            WxContact(username: $0.username, remark: $0.chatDisplayName, nickName: "", alias: "",
                      lastTimestamp: $0.lastTimestamp, unreadCount: $0.unreadCount,
                      summary: $0.summary.contains("<") ? "[媒体或特殊消息]" : String($0.summary.prefix(120)))
        }
    }
}
