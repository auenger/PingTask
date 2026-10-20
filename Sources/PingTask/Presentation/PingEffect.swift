import SwiftUI
import AppKit

// Native, transient, click-through effect; no capture, lookup or task creation.
struct PingEffectView: View {
    let action: PingAction
    @State private var appeared = false
    @State private var expanded = false
    @State private var fading = false
    private var color: Color { action.id == "continue" ? .blue : action.id == "plan" ? .green : .yellow }
    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                Circle().stroke(color.opacity(expanded ? 0 : 0.75), lineWidth: 2)
                    .frame(width: 130, height: 130)
                    .scaleEffect(expanded ? 1.35 : 0.25)
                    .animation(.easeOut(duration: 0.65).delay(Double(index) * 0.16), value: expanded)
            }
            if let image = PingArtwork.image(PingArtwork.name(for: action)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
                    .shadow(color: color.opacity(0.7), radius: 14)
                    .scaleEffect(appeared ? 1 : 0.25)
                    .animation(.spring(response: 0.28, dampingFraction: 0.58), value: appeared)
            }
        }.frame(width: 220, height: 220)
            .opacity(fading ? 0 : 1)
            .animation(.easeOut(duration: 0.5), value: fading)
            .task {
                appeared = true; expanded = true
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                fading = true
            }
    }
}

@MainActor final class PingEffectPanel {
    private var panels: [UUID: NSPanel] = [:]
    func show(at point: CGPoint, action: PingAction) {
        // Bound retained effects even when repeatedly triggered.
        if panels.count >= 8, let id = panels.keys.first { panels.removeValue(forKey: id)?.orderOut(nil) }
        let center = CaptureGeometry.appKitPoint(point, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let panel = NSPanel(contentRect: CGRect(x: center.x - 110, y: center.y - 110, width: 220, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: PingEffectView(action: action))
        let id = UUID(); panels[id] = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.panels.removeValue(forKey: id)?.orderOut(nil) }
    }
}
