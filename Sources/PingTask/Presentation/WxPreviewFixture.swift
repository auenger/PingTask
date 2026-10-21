import AppKit

@MainActor func wxPreviewFixture(root: URL) throws -> WeChatSourceModel {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: 320, height: 160))
    image.lockFocus()
    NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 160)).fill()
    ("Synthetic image" as NSString).draw(at: NSPoint(x: 30, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white])
    image.unlockFocus()
    let picture = root.appendingPathComponent("preview.png")
    try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: picture)
    let file = root.appendingPathComponent("requirements.txt")
    try Data("Synthetic fixture. No chat data.".utf8).write(to: file)
    let model = WeChatSourceModel()
    model.path = "/example/wxview"
    model.account = WxAccount(account: "fixture", username: "fixture", displayName: "演示账号 · 虚构内容", dataDirFingerprint: "fixture", dataDir: root.appendingPathComponent("db_storage").path)
    model.contacts = [WxContact(username: "team@chatroom", remark: "产品讨论群（演示）", nickName: "", alias: "", lastTimestamp: Int64(Date().timeIntervalSince1970 - 120), unreadCount: 3, summary: "看看这张图和需求说明"),
                      WxContact(username: "friend", remark: "林舟（演示）", nickName: "", alias: "", lastTimestamp: Int64(Date().timeIntervalSince1970 - 3600), unreadCount: 0, summary: "明天再一起核对")]
    model.selectedContact = model.contacts[0]
    model.page = WxPage(meta: WxPage.Meta(schemaVersion: 1, timezone: "Asia/Shanghai", username: "team@chatroom", start: "2026-10-21 00:00:00", end: "2026-10-21 23:59:59", hasMore: false, order: "desc"), items: [
        WxMessage(id: "picture", chatUsername: "team@chatroom", chatDisplayName: "演示", fromUsername: "林舟（演示）", time: "10:32", type: 3, content: "", contentDetail: ["type":"image","media_status":"resolved","path":picture.path]),
        WxMessage(id: "file", chatUsername: "team@chatroom", chatDisplayName: "演示", fromUsername: "林舟（演示）", time: "10:30", type: 49, content: "", contentDetail: ["type":"file","text":"需求说明（虚构）","media_status":"resolved","path":file.path])])
    model.status = "演示最近会话与附件 · 虚构内容，不读取微信"
    return model
}
