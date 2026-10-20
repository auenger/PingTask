import AppKit

@MainActor func runIntentChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PingTask-intents-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("state.json")
    // Legacy state lacks all optional artwork and wheel fields.
    try Data(#"{"actions":[{"id":"analyze","name":"旧意图","symbol":"star","prompt":"旧提示词"}],"tasks":[]}"#.utf8).write(to: file)
    let store = Store(fileURL: file)
    precondition(store.wheelActions.count == 1 && store.centerArtwork == PingArtwork.centerDefault)
    precondition(PingArtwork.name(for: store.actions[0]) == "png_enemymissing_128x128")
    store.capture(SourceMessage.examples[0], action: store.actions[0], executor: "Codex")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let snapshot = try encoder.encode(store.tasks)
    store.changeIntents { store.defaultArtwork = "lp_emotes_bee_happy"; store.centerArtwork = "lp_emotes_facepalm" }
    let first = store.addIntent()!
    precondition(store.actions.last?.artwork == "lp_emotes_bee_happy" && store.actions.last?.createsTask == false)
    store.updateIntent(first) { $0.name = "测试"; $0.prompt = "新提示词"; $0.effectOnly = false }
    store.moveIntent(first, by: -1)
    precondition(store.wheelActions.first?.id == first)
    for _ in 0..<9 { _ = store.addIntent() }
    precondition(store.actions.count == 11 && store.wheelActions.count == 8 && store.actions.last?.onWheel == false)
    let last = store.actions.last!.id
    store.setOnWheel(last, enabled: true)
    precondition(store.actions.last?.onWheel == false)
    store.setOnWheel(first, enabled: false)
    store.setOnWheel(last, enabled: true)
    precondition(store.wheelActions.count == 8 && store.wheelActions.contains { $0.id == last })
    precondition(store.deleteIntent("analyze"))
    let after = try encoder.encode(store.tasks)
    precondition(after == snapshot, "Deleting or editing intents must not change historical tasks")
    let restored = Store(fileURL: file)
    precondition(restored.centerArtwork == "lp_emotes_facepalm" && restored.defaultArtwork == "lp_emotes_bee_happy")
    precondition(restored.actions.map(\.id) == store.actions.map(\.id))
    for id in store.actions.map(\.id) { precondition(store.deleteIntent(id)) }
    precondition(Store(fileURL: file).actions.isEmpty, "An intentionally empty library must not restore deleted defaults")
    let fresh = store.addIntent()!
    precondition(fresh != first && store.wheelActions.count == 1)
    // Failed persistence rolls back a destructive change.
    let blocker = directory.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let failing = Store(fileURL: blocker.appendingPathComponent("state.json"))
    precondition(!failing.deleteIntent("analyze") && failing.actions.count == 4)
    for count in 1...8 {
        for index in 0..<count {
            let angle = CaptureGeometry.angle(index: index, count: count)
            precondition(CaptureGeometry.slice(delta: CGPoint(x: cos(angle) * 100, y: sin(angle) * 100), count: count) == index)
        }
        precondition(CaptureGeometry.slice(delta: .zero, count: count) == nil)
    }
    precondition(CaptureGeometry.slice(delta: CGPoint(x: 100, y: 0), count: 0) == nil)
    precondition(PingArtwork.catalog.count == 95)
    for item in PingArtwork.catalog {
        guard let url = PingArtwork.resourceBundle.url(forResource: item.id, withExtension: "png"), NSImage(contentsOf: url) != nil else {
            throw WxFailure(message: "Missing asset: \(item.id)")
        }
    }
    let original = PingArtwork.resourceBundle.url(forResource: "png_enemymissing_128x128", withExtension: "png")!
    let source = directory.appendingPathComponent("source.png")
    try FileManager.default.copyItem(at: original, to: source)
    let imported = try PingArtwork.importImage(at: source, directory: store.artworkDirectory)
    try FileManager.default.removeItem(at: source)
    let importedURL = PingArtwork.customURL(imported, directory: store.artworkDirectory)!
    precondition(NSImage(contentsOf: importedURL) != nil, "Imported artwork must survive removing the original")
    precondition(PingArtwork.customURL("custom:../../state.json", directory: directory) == nil)
    do {
        _ = try PingArtwork.importImage(at: blocker, directory: store.artworkDirectory)
        preconditionFailure("Non-images must be rejected")
    } catch { }
    print("PASS: legacy migration, intent CRUD/order/defaults, 8-slot limit, historical snapshot preservation, rollback, 0–8 wheel geometry, 95 bundled images, private image import and invalid input rejection")
}
