import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol TextPasting {
    func captureTarget()
    func pasteFromClipboard() async -> Bool
}

@MainActor
final class SystemTextPaster: TextPasting {
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor in
                self?.rememberIfExternal(application)
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            rememberIfExternal(frontmost)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func captureTarget() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else {
            targetApplication = lastExternalApplication
        }
    }

    func pasteFromClipboard() async -> Bool {
        guard let targetApplication else { return false }
        guard isAccessibilityTrusted(prompt: true) else { return false }

        targetApplication.activate(options: [])
        try? await Task.sleep(for: .milliseconds(120))

        if pasteUsingAccessibility(into: targetApplication) {
            return true
        }
        return pasteUsingKeyboardEvent()
    }

    private func rememberIfExternal(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = application
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func pasteUsingAccessibility(into application: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success, let focusedElement else {
            return false
        }

        let element = focusedElement as! AXUIElement
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            return false
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func pasteUsingKeyboardEvent() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
