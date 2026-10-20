import SwiftUI
import AppKit

struct WheelSector: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.32
        let start = Angle.degrees(Double(index) * 90 - 133)
        let end = Angle.degrees(Double(index) * 90 - 47)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

enum PingArtwork {
    static let names = ["png_enemymissing_128x128", "png_assist_me_128x128", "png_all_in", "omw", "pingwheel_basicpingrender"]
    static func name(for action: PingAction) -> String {
        switch action.id {
        case "analyze": return names[0]
        case "plan": return names[1]
        case "implement": return names[2]
        case "continue": return names[3]
        default: return names[4]
        }
    }
    static var resourceBundle: Bundle {
        if let root = Bundle.main.resourceURL,
           let packaged = Bundle(url: root.appendingPathComponent("PingTask_PingTask.bundle")) { return packaged }
        return .module
    }
    static func image(_ name: String) -> NSImage? {
        guard let url = resourceBundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct DesktopWheelView: View {
    let actions: [PingAction]
    let selected: Int?
    var revealed = true
    var trigger: PingTrigger = .alt
    private let gold = Color(red: 0.78, green: 0.67, blue: 0.43)
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.35)).blur(radius: 15).frame(width: 290, height: 290)
            ForEach(Array(actions.prefix(4).enumerated()), id: \.element.id) { index, action in
                let active = selected == index
                WheelSector(index: index)
                    .fill(RadialGradient(colors: active ? [Color(white: 0.54), Color(white: 0.62).opacity(0.05)] : [.clear, .clear], center: .center, startRadius: 100, endRadius: 182))
                    .frame(width: 366, height: 366)
                WheelSector(index: index)
                    .fill(RadialGradient(colors: active ? [Color(red: 0.54, green: 0.56, blue: 0.59), Color(red: 0.60, green: 0.63, blue: 0.66)] : [Color(red: 0.16, green: 0.18, blue: 0.19), Color(red: 0.29, green: 0.31, blue: 0.33)], center: .center, startRadius: 44, endRadius: 150))
                    .opacity(active ? 0.95 : 0.92)
                    .overlay(WheelSector(index: index).stroke(gold.opacity(active ? 0.8 : 0.45), lineWidth: 1))
                    .frame(width: 288, height: 288)
                let angle = Double(index) * .pi / 2 - .pi / 2
                VStack(spacing: 4) {
                    if let image = PingArtwork.image(PingArtwork.name(for: action)) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 38)
                            .saturation(active ? 1 : 0.15).opacity(active ? 1 : 0.75)
                            .shadow(color: active ? gold.opacity(0.45) : .clear, radius: 6)
                    }
                    Text(action.name + (action.createsTask ? "" : " ✦")).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(active ? Color.white : gold.opacity(0.8))
                .scaleEffect(active ? 1.18 : 1)
                .offset(x: cos(angle) * 98, y: sin(angle) * 98)
            }
            Circle().fill(RadialGradient(colors: [Color(red: 0.17, green: 0.36, blue: 0.38), Color(red: 0.07, green: 0.16, blue: 0.17)], center: .top, startRadius: 0, endRadius: 90))
                .overlay(Circle().stroke(gold, lineWidth: 2.3))
                .overlay(Circle().inset(by: 5).stroke(gold.opacity(0.45), lineWidth: 0.7))
                .frame(width: 89, height: 89)
            VStack(spacing: 2) {
                if let image = PingArtwork.image("pingwheel_basicpingrender") {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 24, height: 24)
                }
                Text("取消").font(.system(size: 10, weight: .medium)).foregroundStyle(gold)
                Text("ESC").font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            Text("按住 \(trigger.symbol) 移向动作 · \(selected.flatMap { actions.indices.contains($0) ? actions[$0] : nil }?.createsTask == false ? "松手播放特效" : "松手触发")")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(gold)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(red: 0.04, green: 0.08, blue: 0.1).opacity(0.92), in: Capsule())
                .offset(y: 185)
        }
        .frame(width: 380, height: 410)
        .scaleEffect(revealed ? 1 : 0.85).opacity(revealed ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: selected)
        .animation(.easeOut(duration: 0.12), value: revealed)
        .accessibilityLabel("Ping 轮盘，四方向选择，中心取消")
    }
}

@MainActor final class WheelPresentation: ObservableObject {
    @Published var selected: Int?
    @Published var revealed = false
    var actions = PingAction.defaults
    var trigger: PingTrigger = .alt
}
private struct LiveWheel: View {
    @ObservedObject var state: WheelPresentation
    var body: some View { DesktopWheelView(actions: state.actions, selected: state.selected, revealed: state.revealed, trigger: state.trigger) }
}
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class DesktopWheelPanel {
    let state = WheelPresentation()
    private var panel: NSPanel?
    func show(at quartzPoint: CGPoint, actions: [PingAction]) -> CGPoint {
        hide()
        state.actions = actions
        state.selected = nil
        state.revealed = false
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let point = CaptureGeometry.appKitPoint(quartzPoint, primaryHeight: primaryHeight)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // At display edges the controller moves the selection cursor to this center; the capture anchor remains frozen.
        let center = CGPoint(x: max(visible.minX + 190, min(point.x, visible.maxX - 190)),
                             y: max(visible.minY + 205, min(point.y, visible.maxY - 205)))
        let panel = OverlayPanel(contentRect: CGRect(x: center.x - 190, y: center.y - 205, width: 380, height: 410),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: LiveWheel(state: state))
        self.panel = panel
        panel.orderFrontRegardless()
        state.revealed = true
        return CGPoint(x: center.x, y: primaryHeight - center.y)
    }
    func feedback(at point: CGPoint) {
        hide()
        let position = CaptureGeometry.appKitPoint(point, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let screen = NSScreen.screens.first { $0.frame.contains(position) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: position.x - 500, y: position.y - 500, width: 1000, height: 1000)
        // Leave room for the icon and rings; flip above near the bottom edge.
        let preferredY = position.y - 162 >= bounds.minY + 8 ? position.y - 162 : position.y + 110
        let frame = CGRect(x: max(bounds.minX + 8, min(position.x - 90, bounds.maxX - 188)),
                           y: max(bounds.minY + 8, min(preferredY, bounds.maxY - 60)),
                           width: 180, height: 52)
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.sharingType = .none
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在捕获…").font(.system(size: 13, weight: .medium))
            }.padding(14).foregroundStyle(.white)
                .background(Color(red: 0.04, green: 0.12, blue: 0.13), in: Capsule())
                .preferredColorScheme(.dark))
        self.panel = panel
        panel.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); panel = nil; state.revealed = false }
}
