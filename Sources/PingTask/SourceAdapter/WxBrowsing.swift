import Foundation

extension WxviewAdapter {
    func contactPage(account: WxAccount, query: String, kind: String, offset: Int) throws -> [WxContact] {
        guard ["friend", "chatroom", "all"].contains(kind), offset >= 0 else { throw WxFailure(message: "联系人筛选无效") }
        var args = ["contacts", "--kind", kind, "--limit", "100", "--offset", String(offset), "--sort", "username", "--format", "json"]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--query", query] }
        let items = try Self.decode([WxContact].self, checked(account, args: args))
        guard items.count <= 100, Set(items.map(\.id)).count == items.count else { throw WxFailure(message: "联系人分页协议不一致") }
        return items
    }
    func requireHistoryPagination() throws {
        let help = String(decoding: try execute(path, ["messages", "--help"]), as: UTF8.self)
        guard help.contains("--order"), help.contains("--cursor") else {
            throw WxFailure(message: "当前 wxview 不支持最新消息分页，请选择支持 --order / --cursor 的新版 CLI")
        }
    }
    static func historyArgs(username: String, start: Date, end: Date) -> [String] {
        ["messages", "--username", username, "--order", "desc", "--start", String(Int64(start.timeIntervalSince1970)),
         "--end", String(Int64(end.timeIntervalSince1970)), "--limit", "100", "--format", "json"]
    }
    func history(account: WxAccount, username: String, args: [String]) throws -> WxPage {
        let request = try Self.historyValues(args)
        guard request["--username"] == username else { throw WxFailure(message: "消息会话不一致") }
        let page = try Self.decode(WxPage.self, checked(account, args: args))
        _ = try Self.nextHistoryArgs(page, requestArgs: args)
        return page
    }
    private static func historyValues(_ args: [String]) throws -> [String: String] {
        guard args.first == "messages", args.count % 2 == 1 else { throw WxFailure(message: "缺少有效分页参数") }
        var values: [String: String] = [:]
        for i in stride(from: 1, to: args.count, by: 2) {
            guard ["--username", "--start", "--end", "--order", "--cursor", "--limit", "--format"].contains(args[i]),
                  values[args[i]] == nil else { throw WxFailure(message: "分页参数异常，已停止") }
            values[args[i]] = args[i+1]
        }
        guard let username = values["--username"], !username.isEmpty,
              values["--order"] == "desc", values["--limit"] == "100", values["--format"] == "json",
              let start = values["--start"].flatMap(Int64.init), let end = values["--end"].flatMap(Int64.init),
              start > 0, end >= start, end - start <= 366 * 86400 else { throw WxFailure(message: "分页范围或排序无效，已停止") }
        if let cursor = values["--cursor"] {
            guard !cursor.isEmpty, cursor.utf8.count <= 4096,
                  cursor.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw WxFailure(message: "分页游标无效，已停止")
            }
        }
        return values
    }
    static func nextHistoryArgs(_ page: WxPage, requestArgs: [String]) throws -> [String]? {
        let request = try historyValues(requestArgs)
        guard page.meta.order == "desc" else { throw WxFailure(message: "wxview 未返回倒序分页，请升级 CLI 后重试") }
        let start = Int64(request["--start"]!)!, end = Int64(request["--end"]!)!
        guard page.meta.schemaVersion == 1, page.meta.username == request["--username"], page.items.count <= 100,
              Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ $0.chatUsername == page.meta.username && !$0.id.isEmpty && $0.createTime.map { Int64($0) >= start && Int64($0) <= end } == true }) else {
            throw WxFailure(message: "消息分页来源或时间范围不一致")
        }
        guard let timezone = historyTimezone(page.meta.timezone) else { throw WxFailure(message: "wxview 返回未知时区，已停止分页") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // Compare metadata to the requested instants in the CLI timezone. Formatting known
        // instants also avoids ambiguities when a DST fall-back repeats a local clock time.
        guard page.meta.start == formatter.string(from: Date(timeIntervalSince1970: TimeInterval(start))),
              page.meta.end == formatter.string(from: Date(timeIntervalSince1970: TimeInterval(end))),
              zip(page.items, page.items.dropFirst()).allSatisfy({ $0.0.createTime! >= $0.1.createTime! }) else {
            throw WxFailure(message: "消息分页时间边界或顺序发生变化，已停止")
        }
        guard page.meta.hasMore else {
            guard page.meta.nextCursor == nil, page.meta.nextArgs == nil else { throw WxFailure(message: "末页包含异常游标") }
            return nil
        }
        guard !page.items.isEmpty, let args = page.meta.nextArgs, let cursor = page.meta.nextCursor, !cursor.isEmpty else {
            throw WxFailure(message: "缺少有效分页游标，请刷新查询")
        }
        let next = try historyValues(args)
        guard next["--username"] == request["--username"], next["--order"] == request["--order"],
              next["--start"].flatMap(Int64.init) == start, next["--end"].flatMap(Int64.init) == end,
              next["--cursor"] == cursor, next["--cursor"] != request["--cursor"] else {
            throw WxFailure(message: "分页范围或游标发生变化，已停止")
        }
        return args
    }
    private static func historyTimezone(_ name: String) -> TimeZone? {
        if let zone = TimeZone(identifier: name) { return zone }
        // wxview falls back to UTC+08:00-style fixed offsets on some machines.
        let chars = Array(name)
        guard chars.count == 9, String(chars.prefix(3)) == "UTC", chars[6] == ":",
              chars[3] == "+" || chars[3] == "-", let hours = Int(String(chars[4...5])),
              let minutes = Int(String(chars[7...8])), hours <= 23, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (chars[3] == "-" ? -1 : 1))
    }
}
