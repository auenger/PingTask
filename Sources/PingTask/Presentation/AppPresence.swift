import AppKit

/// Apply only in the GUI app, never in workers, self-tests or isolated previews.
final class AppPresenceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.apply(menuBarOnly: UserDefaults.standard.bool(forKey: AppPresence.preferenceKey))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum AppPresence {
    static let preferenceKey = "menuBarOnly"

    static func apply(menuBarOnly: Bool) {
        let visibleWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        // Changing activation policy can move a visible settings window behind another app.
        if let visibleWindow {
            DispatchQueue.main.async {
                visibleWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
