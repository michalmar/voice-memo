import AppKit
import ApplicationServices
import Foundation
import OSLog

enum TextPasteResult: Equatable {
    case pasted
    case noTarget
    case permissionRequired
    case targetUnavailable
    case activationFailed
    case eventCreationFailed

    var failureMessage: String? {
        switch self {
        case .pasted:
            nil
        case .noTarget:
            "The transcript was copied, but VoicePrompt could not determine which app should receive it. Keep the cursor in the destination app when starting a recording."
        case .permissionRequired:
            "The transcript was copied, but direct paste requires Accessibility access in VoicePrompt Settings."
        case .targetUnavailable:
            "The transcript was copied, but the destination app is no longer running."
        case .activationFailed:
            "The transcript was copied, but VoicePrompt could not return to the destination app."
        case .eventCreationFailed:
            "The transcript was copied, but VoicePrompt could not create the paste keyboard event."
        }
    }
}

@MainActor
protocol TextPasting {
    func captureTarget()
    func pasteFromClipboard() async -> TextPasteResult
}

@MainActor
final class SystemTextPaster: TextPasting {
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let logger = Logger(
        subsystem: "com.michalmar.voiceprompt.macos",
        category: "DirectPaste"
    )

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
           isExternal(frontmost) {
            targetApplication = frontmost
        } else {
            targetApplication = lastExternalApplication
        }
        if let targetApplication {
            logger.debug("Captured paste target PID \(targetApplication.processIdentifier)")
        } else {
            logger.error("Could not capture a paste target")
        }
    }

    func pasteFromClipboard() async -> TextPasteResult {
        guard let targetApplication else {
            logger.error("Paste skipped because no target was captured")
            return .noTarget
        }
        guard !targetApplication.isTerminated else {
            logger.error("Paste target terminated before delivery")
            return .targetUnavailable
        }
        guard isAccessibilityTrusted(prompt: true) else {
            logger.error("Paste skipped because Accessibility access is missing")
            return .permissionRequired
        }

        guard await activate(targetApplication) else {
            logger.error("Paste target did not become active")
            return .activationFailed
        }

        if pasteUsingAccessibility(into: targetApplication) {
            logger.debug("Pasted through the Accessibility API")
            return .pasted
        }
        guard await pasteUsingKeyboardEvent() else {
            logger.error("Could not create a Command-V keyboard event")
            return .eventCreationFailed
        }
        logger.debug("Posted Command-V to the active paste target")
        return .pasted
    }

    private func rememberIfExternal(_ application: NSRunningApplication) {
        guard isExternal(application) else { return }
        lastExternalApplication = application
    }

    private func isExternal(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier != Bundle.main.bundleIdentifier
            && !application.isTerminated
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func activate(_ application: NSRunningApplication) async -> Bool {
        let requested = application.activate(
            from: NSRunningApplication.current,
            options: []
        ) || application.activate(options: [])
        guard requested else { return false }

        for _ in 0..<20 {
            if application.isActive
                || NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == application.processIdentifier {
                try? await Task.sleep(for: .milliseconds(50))
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
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

    private func pasteUsingKeyboardEvent() async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(20))
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
