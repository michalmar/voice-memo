import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: ObservableObject {
    private(set) var window: NSWindow?

    func show(synchronizer: CompletionSynchronizer) {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
        } else {
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "VoicePrompt Settings"
            settingsWindow.identifier = NSUserInterfaceItemIdentifier("voiceprompt-settings")
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentViewController = NSHostingController(
                rootView: SettingsView(synchronizer: synchronizer)
            )
            settingsWindow.center()
            window = settingsWindow
        }
        if settingsWindow.isMiniaturized {
            settingsWindow.deminiaturize(nil)
        }
        // Accessory apps need a visible window before macOS will activate them.
        settingsWindow.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }
}
