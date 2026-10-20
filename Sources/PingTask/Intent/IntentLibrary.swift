import Foundation

@MainActor extension Store {
    var wheelActions: [PingAction] { Array(actions.filter { $0.onWheel != false }.prefix(8)) }
    var artworkDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("Artwork") }

    @discardableResult func changeIntents(_ change: () -> Void) -> Bool {
        let previous = (actions, centerArtwork, defaultArtwork)
        change()
        guard save() else {
            (actions, centerArtwork, defaultArtwork) = previous
            return false
        }
        return true
    }
    func addIntent() -> String? {
        let action = PingAction(id: UUID().uuidString, name: "新意图", symbol: "sparkles",
                                artwork: defaultArtwork, onWheel: wheelActions.count < 8,
                                effectOnly: true, prompt: "")
        return changeIntents { actions.append(action) } ? action.id : nil
    }
    func updateIntent(_ id: String, change: (inout PingAction) -> Void) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        changeIntents { change(&actions[index]) }
    }
    func setOnWheel(_ id: String, enabled: Bool) {
        guard !enabled || wheelActions.count < 8 || wheelActions.contains(where: { $0.id == id }) else {
            notice = "轮盘最多显示 8 个意图，请先移出一个。"; return
        }
        updateIntent(id) { $0.onWheel = enabled }
    }
    func deleteIntent(_ id: String) -> Bool {
        changeIntents { actions.removeAll { $0.id == id } }
    }
    func moveIntent(_ id: String, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }), actions.indices.contains(index + offset) else { return }
        changeIntents { actions.swapAt(index, index + offset) }
    }
}
