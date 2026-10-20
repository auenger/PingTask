import Foundation

struct WxSearchPage: Decodable {
    struct Meta: Decodable {
        let schemaVersion: Int
        let timezone: String
        let username: String?
        let start: String
        let end: String
        let totalMatches: Int
        let returned: Int
    }
    let meta: Meta
    let items: [WxMessage]
    var contextPage: WxPage {
        WxPage(meta: .init(schemaVersion: meta.schemaVersion, timezone: meta.timezone,
                          username: meta.username ?? "", start: meta.start, end: meta.end,
                          hasMore: meta.totalMatches > items.count), items: items)
    }
}
extension WxviewAdapter {
    func searchMessages(account: WxAccount, conversation: String, query: String, start: String, end: String) throws -> WxSearchPage {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3, !conversation.isEmpty else {
            throw WxFailure(message: "定位关键词至少 3 个字符，并且需要明确会话")
        }
        let data = try checked(account, args: ["search", "--username", conversation, "--query", query,
                                               "--start", start, "--end", end, "--limit", "20", "--format", "json"])
        let page = try Self.decode(WxSearchPage.self, data)
        guard page.meta.schemaVersion == 1, page.meta.username == conversation,
              page.meta.returned == page.items.count, page.items.count <= 20,
              page.meta.totalMatches >= page.items.count,
              page.items.allSatisfy({ $0.chatUsername == conversation && !$0.id.isEmpty }),
              Set(page.items.map(\.id)).count == page.items.count else {
            throw WxFailure(message: "消息检索协议或会话不一致，已丢弃结果")
        }
        return page
    }
}

enum MessageClues {
    static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\s*[（(][0-9]+[）)]$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func titles(_ capture: DesktopCapture) -> [String] {
        let top = capture.lines.filter { $0.bounds.midY > 0.88 && $0.bounds.midX > 0.25 && $0.confidence >= 0.5 }
            .sorted { $0.bounds.midY > $1.bounds.midY }.map(\.text)
        var seen = Set<String>()
        return ([capture.target.title] + top).map(cleanTitle).filter {
            let key = normalize($0)
            return key.count >= 2 && !["微信", "wechat", "weixin", "搜索", "search"].contains(key) && seen.insert(key).inserted
        }.prefix(3).map { String($0.prefix(80)) }
    }
    static func exactContacts(_ contacts: [WxContact], title: String) -> [WxContact] {
        let key = normalize(cleanTitle(title))
        return contacts.filter { [ $0.remark, $0.nickName, $0.alias, $0.username ].contains { normalize(cleanTitle($0)) == key } }
    }
    static func keyword(_ text: String) -> String {
        // Use literal visible text; no command language or instructions are evaluated.
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
