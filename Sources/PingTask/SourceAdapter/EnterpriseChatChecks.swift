import Foundation

func runEnterpriseChatChecks() throws {
    precondition(ChatPlatform.detect("com.electron.lark") == .lark)
    precondition(ChatPlatform.detect("com.larksuite.larkApp") == .lark)
    precondition(ChatPlatform.detect("com.alibaba.DingTalkMac") == .dingtalk)
    precondition(ChatPlatform.detect("evil.com.electron.lark") == nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-enterprise-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fixture")
    try Data("""
    #!/usr/bin/python3
    import json,sys
    a=sys.argv[1:]
    if a==['profile','list']:
        print(json.dumps([{'name':'fixture','active':True}]))
    else:
        assert a[a.index('--profile')+1]=='fixture'
        if a[:2]==['auth','status']:
            print(json.dumps({'appId':'app-fixture','brand':'lark','identities':{'user':{'available':True,'tokenStatus':'valid','openId':'ou_fixture'}}}))
        else:
            assert a[a.index('--as')+1]=='user'
            assert '--page-all' not in a and '--download-resources' not in a
            assert a[:2]==['im','+chat-messages-list']
            assert a[a.index('--page-size')+1]=='50'
            assert a[a.index('--chat-id')+1]=='oc_fixture'
            print(json.dumps({'data':{'has_more':True,'messages':[{'message_id':'om_fixture','chat_id':'oc_fixture','content':'合成消息，测试上下文边界','sender':{'name':'测试发送者'},'create_time':'2026-10-20T12:00:00+08:00'}]}}))
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let adapter = LarkContextAdapter(path: script.path, profile: "")
    let context = try adapter.context(title: "oc_fixture", start: Date().addingTimeInterval(-86400), end: Date())
    precondition(context.messages.count == 1 && context.hasMore)
    precondition(context.identity.profile == "fixture")
    let source = context.source(context.messages[0])
    precondition(source.resolvedAnchor == Identity.digest(["lark", context.identity.key, "oc_fixture", "om_fixture"]))
    precondition(source.evidence!.contains("已截断"))
    func rejects(_ root: [String: Any]) {
        do { _ = try LarkContextAdapter.parse(root, chatID: "oc_fixture"); preconditionFailure("Must reject malformed/cross-chat messages") } catch {}
    }
    let row: [String: Any] = ["message_id": "om_fixture", "chat_id": "oc_other", "content": "text", "create_time": "time"]
    rejects(["messages": [row], "has_more": false])
    rejects(["messages": [], "has_more": "false"])
    rejects(["messages": []])
    let good: [String: Any] = ["message_id": "om_fixture", "content": "text", "create_time": "time"]
    rejects(["messages": [good, good], "has_more": false])
    rejects(["messages": Array(repeating: good, count: 51), "has_more": true])
    let other = LarkIdentity(profile: "other", app: context.identity.app, brand: "lark", user: context.identity.user)
    precondition(other.key != context.identity.key)
    do {
        _ = try adapter.pinned().checked(["im", "+chat-messages-list"], identity: other)
        preconditionFailure("Must reject account changes before reading")
    } catch {}
    print("Enterprise chat fixtures passed (no live messages queried)")
}
