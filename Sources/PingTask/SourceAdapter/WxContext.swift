import Foundation

struct WxContext {
    let anchor: WxMessage
    let page: WxPage
    let selected: [WxMessage]
    let readAt: Date
    var summary: String {
        "\(page.meta.start) — \(page.meta.end)（\(page.meta.timezone)）内读取 \(page.items.count) 条，选取锚点前后各最多 5 条；\(page.meta.hasMore ? "查询有截断，不能保证完整前后文" : "仅覆盖此时间范围")。本地缓存可能延迟。"
    }
    func source(account: WxAccount) -> SourceMessage {
        let original = anchor.source(account: account, page: page, readAt: readAt)
        let text = selected.map { "\($0.id == anchor.id ? "【目标消息】" : "【附近消息】") \($0.fromUsername) · \($0.time)\n\(String($0.text.prefix(2000)))" }.joined(separator: "\n\n")
        return SourceMessage(id: original.id, app: original.app, chat: original.chat, sender: original.sender,
            text: text, resolvedAnchor: original.resolvedAnchor,
            evidence: (original.evidence ?? "") + "\n用户确认附带附近消息。\(summary)\n每条正文最多 2000 字，媒体未读取。")
    }
}

extension WxviewAdapter {
    func context(account: WxAccount, anchor: WxMessage) throws -> WxContext {
        guard let timestamp = anchor.createTime, timestamp > 0 else {
            throw WxFailure(message: "此消息缺少时间戳；可仅选择原消息，不猜测上下文")
        }
        let page = try Self.decode(WxPage.self, checked(account, args: [
            "messages", "--username", anchor.chatUsername,
            "--start", String(timestamp - 900), "--end", String(timestamp + 900),
            "--limit", "100", "--format", "json"
        ]))
        guard page.meta.schemaVersion == 1, page.meta.username == anchor.chatUsername,
              page.items.count <= 100, page.items.allSatisfy({ $0.chatUsername == anchor.chatUsername && !$0.id.isEmpty }),
              Set(page.items.map(\.id)).count == page.items.count,
              let index = page.items.firstIndex(where: { $0.id == anchor.id && $0.text == anchor.text }) else {
            throw WxFailure(message: "返回范围未包含原消息或来源有变化；请仅选原消息或重新定位")
        }
        let selected = Array(page.items[max(0, index - 5)...min(page.items.count - 1, index + 5)])
        return WxContext(anchor: anchor, page: page, selected: selected, readAt: Date())
    }
}
