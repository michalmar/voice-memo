import AppKit
import Carbon
import Foundation
import SwiftUI

@MainActor
final class GlobalShortcutManager: ObservableObject {
    struct Shortcut: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let displayName: String

        static let defaultShortcut = Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey),
            displayName: "⇧⌘Space"
        )
    }

    @Published private(set) var shortcut: Shortcut
    @Published private(set) var isEnabled: Bool
    @Published private(set) var registrationError: String?

    private enum DefaultsKey {
        static let enabled = "quickTranscriptionShortcutEnabled"
        static let keyCode = "quickTranscriptionShortcutKeyCode"
        static let modifiers = "quickTranscriptionShortcutModifiers"
        static let displayName = "quickTranscriptionShortcutDisplayName"
    }

    private let defaults: UserDefaults
    private let action: @MainActor () -> Void
    private var registration: GlobalHotKey?

    init(
        defaults: UserDefaults = .standard,
        action: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.action = action
        let savedKeyCode = defaults.object(forKey: DefaultsKey.keyCode) as? NSNumber
        let savedModifiers = defaults.object(forKey: DefaultsKey.modifiers) as? NSNumber
        let savedDisplayName = defaults.string(forKey: DefaultsKey.displayName)
        shortcut = if let savedKeyCode, let savedModifiers, let savedDisplayName {
            Shortcut(
                keyCode: savedKeyCode.uint32Value,
                modifiers: savedModifiers.uint32Value,
                displayName: savedDisplayName
            )
        } else {
            .defaultShortcut
        }
        isEnabled = defaults.object(forKey: DefaultsKey.enabled) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.enabled)
        _ = registerIfEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.enabled)
        _ = registerIfEnabled()
    }

    func updateShortcut(_ newShortcut: Shortcut) {
        guard newShortcut != shortcut else { return }
        let previousShortcut = shortcut
        shortcut = newShortcut
        guard registerIfEnabled() else {
            shortcut = previousShortcut
            return
        }
        defaults.set(newShortcut.keyCode, forKey: DefaultsKey.keyCode)
        defaults.set(newShortcut.modifiers, forKey: DefaultsKey.modifiers)
        defaults.set(newShortcut.displayName, forKey: DefaultsKey.displayName)
    }

    private func registerIfEnabled() -> Bool {
        guard isEnabled else {
            registration = nil
            registrationError = nil
            return true
        }
        do {
            let candidate = try GlobalHotKey(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.modifiers,
                action: action
            )
            registration = candidate
            registrationError = nil
            return true
        } catch {
            registrationError = error.localizedDescription
            return false
        }
    }
}

struct ShortcutRecorder: View {
    @ObservedObject var manager: GlobalShortcutManager
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press shortcut…" : manager.shortcut.displayName)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .padding(.horizontal, 12)
                .frame(minWidth: 116, minHeight: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : .secondary.opacity(0.35))
                }
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press Escape to cancel" : "Click to record a new global shortcut")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in stopRecording() }
                return nil
            }
            guard let shortcut = Self.shortcut(from: event) else {
                NSSound.beep()
                return nil
            }
            Task { @MainActor in
                manager.updateShortcut(shortcut)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }

    private static func shortcut(from event: NSEvent) -> GlobalShortcutManager.Shortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.rawValue.nonzeroBitCount >= 2 else { return nil }

        var carbonModifiers = UInt32(0)
        var displayName = ""
        if flags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            displayName += "⌃"
        }
        if flags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            displayName += "⌥"
        }
        if flags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            displayName += "⇧"
        }
        if flags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            displayName += "⌘"
        }

        let keyName: String
        switch Int(event.keyCode) {
        case kVK_Space: keyName = "Space"
        case kVK_Return: keyName = "Return"
        case kVK_Tab: keyName = "Tab"
        case kVK_Delete: keyName = "Delete"
        case kVK_ForwardDelete: keyName = "Forward Delete"
        case kVK_LeftArrow: keyName = "←"
        case kVK_RightArrow: keyName = "→"
        case kVK_UpArrow: keyName = "↑"
        case kVK_DownArrow: keyName = "↓"
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  let character = characters.first,
                  !character.isWhitespace
            else { return nil }
            keyName = String(character).uppercased()
        }

        return GlobalShortcutManager.Shortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers,
            displayName: displayName + keyName
        )
    }
}
