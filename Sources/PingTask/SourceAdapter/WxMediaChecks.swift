import Foundation
import AppKit

@MainActor func runWxMediaChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-media-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let allowed = root.appendingPathComponent("account")
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    let file = allowed.appendingPathComponent("synthetic.txt")
    try Data("synthetic attachment".utf8).write(to: file)
    let media = LocalMedia(path: file.path, roots: [allowed], isImage: false, isThumbnail: false)
    let attachment = try MediaIO.makeSnapshot(media, root: root.appendingPathComponent("copies"))
    precondition(attachment.sha256 == MediaIO.digest(Data("synthetic attachment".utf8)))
    try FileManager.default.removeItem(at: file)
    let copied = try MediaIO.bytes(URL(fileURLWithPath: attachment.path))
    precondition(copied == Data("synthetic attachment".utf8))
    let outside = root.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outside)
    let symlink = allowed.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    do { _ = try LocalMedia(path: symlink.path, roots: [allowed], isImage: false, isThumbnail: false).validatedURL(); preconditionFailure("symlink escaped account") } catch {}
    let huge = allowed.appendingPathComponent("huge")
    FileManager.default.createFile(atPath: huge.path, contents: nil)
    let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: UInt64(MediaIO.limit + 1)); try handle.close()
    do { _ = try LocalMedia(path: huge.path, roots: [allowed], isImage: false, isThumbnail: false).validatedURL(); preconditionFailure("oversized media") } catch {}
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let imagePath = allowed.appendingPathComponent("image.png")
    try png.write(to: imagePath)
    let image = try MediaIO.makeSnapshot(LocalMedia(path: imagePath.path, roots: [allowed], isImage: true, isThumbnail: true), root: root.appendingPathComponent("copies"))
    let store = Store(fileURL: root.appendingPathComponent("state.json"))
    let source = SourceMessage(id: "m", app: "wechat", chat: "fixture", sender: "fixture", text: "fixture", resolvedAnchor: "wechat/fixture/m")
    precondition(store.capture(source, action: store.actions[0], executor: "Codex", attachments: [attachment,image]))
    let task = store.tasks[0]
    precondition(store.capture(source, action: store.actions[0], executor: "Codex", attachments: []))
    precondition(store.tasks[0].attachments?.count == 2)
    let settings = CodexSettings(executable: "/usr/bin/true", tmux: "/usr/bin/true", workspace: root.path, sandbox: "read-only")
    let submission = try CodexRunner.prepare(task: task, settings: settings, root: root.appendingPathComponent("ledger"))
    precondition(submission.imagePaths.count == 1 && submission.prompt.contains(attachment.sha256) && submission.prompt.contains("synthetic.txt"))
    precondition(submission.prompt.contains("attachment-0.txt"))
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger/\(submission.operationID)/attachments/attachment-0.txt").path))
    let restored = Store(fileURL: store.file)
    precondition(restored.tasks.first?.attachments?.first?.sha256 == attachment.sha256)
    var changed = task; changed.id = UUID()
    try Data("changed".utf8).write(to: URL(fileURLWithPath: attachment.path))
    do { _ = try CodexRunner.prepare(task: changed, settings: settings, root: root.appendingPathComponent("ledger")); preconditionFailure("changed attachment accepted") } catch {}
    var trashed = Set<String>()
    let other = SourceMessage(id: "other", app: "wechat", chat: "fixture", sender: "fixture", text: "fixture", resolvedAnchor: "wechat/fixture/other")
    precondition(store.capture(other, action: store.actions[0], executor: "Codex", attachments: [attachment]))
    let otherID = store.selected!
    precondition(store.deleteTask(task.id, trash: { trashed.insert($0.path) }))
    precondition(trashed == Set([image.path]))
    try FileManager.default.removeItem(at: store.file)
    try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: true)
    precondition(!store.deleteTask(otherID, trash: { trashed.insert($0.path) }))
    precondition(store.tasks.count == 1 && trashed == Set([image.path]))
    try FileManager.default.removeItem(at: store.file)
    precondition(store.deleteTask(otherID, trash: { trashed.insert($0.path) }))
    precondition(trashed == Set([attachment.path,image.path]))
    let sessions: [String: Any] = ["count":2,"items":[
        ["username":"new","chat_display_name":"New","last_timestamp":200,"unread_count":2,"summary":"<xml>private</xml>"],
        ["username":"old","chat_display_name":"Old","last_timestamp":100,"unread_count":0,"summary":"fixture"]]]
    let contacts = try WxviewAdapter.decodeSessions(JSONSerialization.data(withJSONObject: sessions))
    precondition(contacts.map(\.id) == ["new","old"] && contacts[0].summary?.contains("private") == false)
    var invalid = sessions; invalid["items"] = Array((sessions["items"] as! [[String: Any]]).reversed())
    do { _ = try WxviewAdapter.decodeSessions(JSONSerialization.data(withJSONObject: invalid)); preconditionFailure("unordered sessions accepted") } catch {}
    print("PASS: recent-session order, sanitized summary, account path/symlink/size limits, attachment copy/hash/persistence/dedup/deletion, frozen manifest, PNG handoff and tamper refusal")
}
