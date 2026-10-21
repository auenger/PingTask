import Foundation

enum AutomaticWeChat {
    static func resolve(capture: DesktopCapture, adapter: WxviewAdapter) throws -> SourceMessage {
        guard capture.target.bundleID == "com.tencent.xinWeChat" else { throw WxFailure(message: "自动上下文仅支持微信窗口") }
        guard !capture.target.isTextEntry else { throw WxFailure(message: "指针位于文本输入控件，未自动查询或提交；请指向已发送消息") }
        let text = MessageClues.normalize(capture.pointedText)
        guard text.count >= 12, capture.lines.contains(where: { $0.text == capture.pointedText && $0.confidence >= 0.85 }) else {
            throw WxFailure(message: "指针文字不足或 OCR 置信度较低，请人工核对")
        }
        let account = try adapter.identity()
        var exact: [WxContact] = []
        for title in MessageClues.titles(capture) {
            let matches = try adapter.contacts(account: account, query: title, kind: "all")
            exact += MessageClues.exactContacts(matches, title: title)
        }
        var ids = Set<String>(); exact = exact.filter { ids.insert($0.id).inserted }
        guard exact.count == 1 else { throw WxFailure(message: "会话不是唯一精确匹配，请人工核对") }
        let start = Calendar.current.date(byAdding: .day, value: -30, to: capture.created)!
        let page = try adapter.searchMessages(account: account, conversation: exact[0].username,
            query: MessageClues.keyword(capture.pointedText), start: MessageClues.day(start), end: MessageClues.day(capture.created))
        guard let message = uniqueMessage(page: page, pointedText: capture.pointedText) else {
            throw WxFailure(message: "消息不是唯一可靠匹配，请核对候选；未自动派发")
        }
        let context = try adapter.context(account: account, anchor: message)
        guard !context.page.meta.hasMore else { throw WxFailure(message: "附近上下文被截断，已停止自动处理") }
        var source = context.source(account: account)
        source.evidence = (source.evidence ?? "").replacingOccurrences(of: "手动选择消息", with: "按意图配置自动定位")
            .replacingOccurrences(of: "用户确认附带附近消息。", with: "按意图配置自动附带附近消息。")
        source.evidence = (source.evidence ?? "") + "\n自动化依据：唯一精确会话、唯一文本匹配、OCR 置信度至少 0.85；本地缓存不保证实时。"
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
