import Foundation

func runWxBrowsingChecks() throws {
    let start: Int64 = 1_800_000_000, end: Int64 = 1_800_001_000
    let args = WxviewAdapter.historyArgs(username: "fixture-chat", start: Date(timeIntervalSince1970: Double(start)), end: Date(timeIntervalSince1970: Double(end)))
    precondition(args.contains("desc") && !args.contains("--after-seq"))
    var next = args + ["--cursor", "fixture_cursor"]
    // Numeric equivalence, not string equivalence, is what fixes the query range.
    next[next.firstIndex(of: "--start")! + 1] = "01800000000"
    func fixture(zone: String = "Asia/Shanghai", from: Int64 = start, to: Int64 = end, more: Bool = true) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 8 * 3600)!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var meta: [String: Any] = ["schema_version":1,"timezone":zone,"username":"fixture-chat","order":"desc",
            "start":formatter.string(from: Date(timeIntervalSince1970: Double(from))),
            "end":formatter.string(from: Date(timeIntervalSince1970: Double(to))),"has_more":more]
        if more { meta["next_cursor"] = "fixture_cursor"; meta["next_args"] = next }
        let items: [[String: Any]] = [end, start].enumerated().map { index, time in
            ["id":"m\(index)","chat_username":"fixture-chat","chat_display_name":"fixture","from_username":"fixture",
             "time":"fixture","create_time":time,"type":1,"content":"synthetic"]
        }
        return ["meta":meta,"items":items]
    }
    func decode(_ object: [String: Any]) throws -> WxPage {
        try WxviewAdapter.decode(WxPage.self, JSONSerialization.data(withJSONObject: object))
    }
    func rejects(_ object: [String: Any], request: [String]? = nil) throws {
        do { _ = try WxviewAdapter.nextHistoryArgs(decode(object), requestArgs: request ?? args) }
        catch { return }
        throw WxFailure(message: "Invalid pagination fixture accepted")
    }
    for zone in ["Asia/Shanghai", "UTC", "UTC+08:00", "America/New_York"] {
        let result = try WxviewAdapter.nextHistoryArgs(decode(fixture(zone: zone)), requestArgs: args)
        precondition(result == next)
    }
    let last = try WxviewAdapter.nextHistoryArgs(decode(fixture(more: false)), requestArgs: args)
    precondition(last == nil)
    for key in ["order", "username", "timezone", "start", "next_cursor"] {
        var object = fixture(), meta = object["meta"] as! [String: Any]
        meta[key] = "invalid"; object["meta"] = meta
        try rejects(object)
    }
    for flag in ["--refresh", "--after-seq", "--offset", "--username"] {
        var object = fixture(), meta = object["meta"] as! [String: Any]
        meta["next_args"] = next + [flag, "1"]; object["meta"] = meta
        try rejects(object)
    }
    for flag in ["--start", "--end", "--order", "--username", "--cursor", "--limit"] {
        var object = fixture(), meta = object["meta"] as! [String: Any], changed = next
        changed[changed.firstIndex(of: flag)! + 1] = "1"
        meta["next_args"] = changed; object["meta"] = meta
        try rejects(object)
    }
    try rejects(fixture(), request: args + ["--cursor", "fixture_cursor"])
    try rejects(fixture(from: start + 1))
    var old = fixture(), oldMeta = old["meta"] as! [String: Any]
    oldMeta.removeValue(forKey: "order"); old["meta"] = oldMeta
    try rejects(old)
    var reversed = fixture()
    reversed["items"] = Array((reversed["items"] as! [[String: Any]]).reversed())
    try rejects(reversed)
    var empty = fixture(more: false); empty["items"] = []
    let emptyNext = try WxviewAdapter.nextHistoryArgs(decode(empty), requestArgs: args)
    precondition(emptyNext == nil)
    let oldCLI = WxviewAdapter(path: "/fixture", execute: { _, _ in Data("legacy messages help".utf8) })
    do { try oldCLI.requireHistoryPagination(); preconditionFailure("Old CLI accepted") } catch {}
    print("PASS: descending history argv, opaque cursor allowlist, numeric time bounds/timezones, source/order/range mismatch rejection, repeated cursor, terminal/empty pages, old CLI upgrade guard")
}
