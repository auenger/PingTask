import SwiftUI
import AppKit

enum AppStyle {
    // MenuBarExtra bridges to an NSStatusItem image and can ignore SwiftUI frame modifiers.
    // Give it a separate NSImage with the correct intrinsic point size.
    static let menuBarIcon: NSImage = {
        let image = (PingArtwork.image("png_enemymissing_128x128")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: "PingTask")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()

    static let gold = Color(red: 0.84, green: 0.70, blue: 0.38)
    static let canvas = Color(red: 0.115, green: 0.125, blue: 0.14)
    static let sidebar = Color(red: 0.085, green: 0.095, blue: 0.11)
    static let surface = Color(red: 0.15, green: 0.165, blue: 0.18)
}
struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let image = PingArtwork.image("png_enemymissing_128x128") {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }.frame(width: size, height: size).accessibilityLabel("PingTask")
    }
}
struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 27, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct QuietEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(AppStyle.gold)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }
}
extension View {
    func appSurface() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
