import Foundation

struct WeChatConversationReview: Error {
    let account: WxAccount
    let contacts: [WxContact]
}

struct WeChatCandidateReview: Error {
    let account: WxAccount
    let contact: WxContact
    let page: WxSearchPage?
    let reason: String
}

enum AutomaticWeChat {
    static func resolve(capture: DesktopCapture, adapter: WxviewAdapter) throws -> SourceMessage {
        guard capture.target.bundleID == "com.tencent.xinWeChat" else { throw WxFailure(message: "自动上下文仅支持微信窗口") }
        guard !capture.target.isTextEntry else { throw WxFailure(message: "指针位于文本输入控件，未自动查询或提交；请指向已发送消息") }
        let account = try adapter.identity()
        var exact: [WxContact] = []
        var candidates: [WxContact] = []
        for title in MessageClues.titles(capture) {
            let matches = try adapter.contacts(account: account, query: title, kind: "all")
            candidates += matches
            exact += MessageClues.exactContacts(matches, title: title)
        }
        var ids = Set<String>(); exact = exact.filter { ids.insert($0.id).inserted }
        guard exact.count == 1 else {
            var seen = Set<String>()
            throw WeChatConversationReview(account: account, contacts: candidates.filter { seen.insert($0.id).inserted })
        }
        guard !MessageClues.searchQueries(capture.pointedText).isEmpty else {
            throw WeChatCandidateReview(account: account, contact: exact[0], page: nil,
                reason: "已定位会话，但指针文字不足 3 字；请补充消息文字后检索。")
        }
        let start = Calendar.current.date(byAdding: .day, value: -30, to: capture.created)!
        let page = try adapter.searchMessageCandidates(account: account, conversation: exact[0].username,
            text: capture.pointedText, start: MessageClues.day(start), end: MessageClues.day(capture.created))
        guard let message = uniqueMessage(page: page, pointedText: capture.pointedText) else {
            throw WeChatCandidateReview(account: account, contact: exact[0], page: page,
                reason: page.items.isEmpty
                    ? "已定位会话，但整段及片段检索均无消息匹配；请调整文字或日期，并检查 wxview 同步状态。"
                    : "已定位会话并找到 wxview 原文候选；指针长文本尚未唯一完整匹配，请核对下方消息。未自动提交。")
        }
        let context = try adapter.context(account: account, anchor: message)
        guard !context.page.meta.hasMore else {
            throw WeChatCandidateReview(account: account, contact: exact[0], page: page,
                reason: "已定位消息，但附近上下文被截断；请核对原文后确认，未自动提交。")
        }
        var source = context.source(account: account)
        source.evidence = (source.evidence ?? "").replacingOccurrences(of: "手动选择消息", with: "按意图配置自动定位")
            .replacingOccurrences(of: "用户确认附带附近消息。", with: "按意图配置自动附带附近消息。")
        source.evidence = (source.evidence ?? "") + "\n自动化依据：唯一精确会话、唯一文本匹配、指针长文本经去除空格和标点后与 wxview 原文完整匹配；本地缓存不保证实时。"
        return source
    }
    static func uniqueMessage(page: WxSearchPage, pointedText: String) -> WxMessage? {
        let text = MessageClues.normalize(pointedText)
        guard text.count >= 12, page.meta.totalMatches == 1, page.items.count == 1,
              let item = page.items.first, item.type == 1,
              MessageClues.normalize(item.text).contains(text) else { return nil }
        return item
    }
}
