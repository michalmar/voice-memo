import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    enum HotKeyError: LocalizedError {
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "The ⇧⌘Space shortcut could not be registered (error \(status))."
            }
        }
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping @MainActor () -> Void
    ) throws {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in instance.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else { throw HotKeyError.registrationFailed(status) }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registration = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registration == noErr else {
            if let handler { RemoveEventHandler(handler) }
            throw HotKeyError.registrationFailed(registration)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let signature: OSType = 0x5650_5452
}
