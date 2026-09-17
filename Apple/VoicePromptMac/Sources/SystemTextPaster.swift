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
    private var targetElement: AXUIElement?
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
        targetElement = focusedElement()
        if let targetApplication {
            let name = targetApplication.localizedName
                ?? targetApplication.bundleIdentifier
                ?? "Unknown"
            logger.info(
                "Captured paste target \(name, privacy: .public) PID \(targetApplication.processIdentifier)"
            )
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
        await restoreCapturedFocus()

        if pasteUsingMenu(into: targetApplication) {
            logger.info("Pasted through the target application's menu command")
            return .pasted
        }
        if pasteUsingAccessibility() {
            logger.info("Pasted through the focused Accessibility element")
            return .pasted
        }
        guard await pasteUsingKeyboardEvent(into: targetApplication) else {
            logger.error("Could not create a Command-V keyboard event")
            return .eventCreationFailed
        }
        logger.info(
            "Posted Command-V directly to paste target PID \(targetApplication.processIdentifier)"
        )
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

    private func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success, let focusedElement else {
            return nil
        }
        return (focusedElement as! AXUIElement)
    }

    private func restoreCapturedFocus() async {
        guard let targetElement else { return }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            targetElement,
            kAXFocusedAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            return
        }
        guard AXUIElementSetAttributeValue(
            targetElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            return
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func pasteUsingAccessibility() -> Bool {
        guard let element = targetElement ?? focusedElement() else { return false }
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

    private func pasteUsingMenu(into application: NSRunningApplication) -> Bool {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success, let menuBarValue else {
            return false
        }

        let menuBar = menuBarValue as! AXUIElement
        guard let pasteItem = findPasteMenuItem(in: menuBar, depth: 0) else {
            return false
        }
        return AXUIElementPerformAction(
            pasteItem,
            kAXPressAction as CFString
        ) == .success
    }

    private func findPasteMenuItem(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 6 else { return nil }

        var commandValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdCharAttribute as CFString,
            &commandValue
        ) == .success,
           let command = commandValue as? String,
           command.caseInsensitiveCompare("v") == .orderedSame {
            var modifiersValue: CFTypeRef?
            let modifiersResult = AXUIElementCopyAttributeValue(
                element,
                kAXMenuItemCmdModifiersAttribute as CFString,
                &modifiersValue
            )
            let modifiers = (modifiersValue as? NSNumber)?.uint32Value ?? 0
            if modifiersResult != .success || modifiers == 0 {
                return element
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let pasteItem = findPasteMenuItem(in: child, depth: depth + 1) {
                return pasteItem
            }
        }
        return nil
    }

    private func pasteUsingKeyboardEvent(into application: NSRunningApplication) async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(application.processIdentifier)
        try? await Task.sleep(for: .milliseconds(20))
        keyUp.postToPid(application.processIdentifier)
        return true
    }
}
