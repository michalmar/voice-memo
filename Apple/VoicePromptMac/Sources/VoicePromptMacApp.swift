import SwiftUI
import VoicePromptKit

@main
struct VoicePromptMacApp: App {
    @StateObject private var synchronizer: CompletionSynchronizer
    @StateObject private var transcription: TranscriptionController
    @StateObject private var shortcut: GlobalShortcutManager
    @StateObject private var settingsWindow = SettingsWindowController()
    private let overlay: TranscriptionOverlayController

    init() {
        let baseURL = URL(string: BackendConfiguration.resolve(
            bundledURL: Bundle.main.object(forInfoDictionaryKey: "BACKEND_URL") as? String
                ?? "https://voiceprompt.invalid/"
        ))!
        let configuration = EntraConfiguration(
            tenantID: Bundle.main.object(forInfoDictionaryKey: "ENTRA_TENANT_ID") as? String ?? "",
            clientID: Bundle.main.object(forInfoDictionaryKey: "ENTRA_CLIENT_ID") as? String ?? "",
            redirectURI: "msauth.com.michalmar.voiceprompt.macos://auth",
            apiScope: Bundle.main.object(forInfoDictionaryKey: "ENTRA_API_SCOPE") as? String ?? ""
        )
        let credentials = EntraCredentialProvider(
            configuration: configuration,
            store: KeychainCredentialStore(service: "com.michalmar.voiceprompt.macos")
        )
        let authorization = EntraAuthorizationCoordinator(configuration: configuration)
        let client = APIClient(baseURL: baseURL, credentials: credentials)
        let sync = CompletionSynchronizer(
            client: client, credentials: credentials,
            clipboard: SystemClipboard(), textPaster: SystemTextPaster(),
            notifications: SystemNotifications(),
            signIn: { try await authorization.signIn(using: credentials) },
            signOut: { await credentials.signOut() }
        )
        let transcription = TranscriptionController(client: client, synchronizer: sync)
        let shortcut = GlobalShortcutManager {
            Task { await transcription.startListening() }
        }
        _synchronizer = StateObject(wrappedValue: sync)
        _transcription = StateObject(wrappedValue: transcription)
        _shortcut = StateObject(wrappedValue: shortcut)
        let overlay = TranscriptionOverlayController(controller: transcription, shortcut: shortcut)
        self.overlay = overlay
        Task { await sync.start() }
    }

    var body: some Scene {
        MenuBarExtra("VoicePrompt", image: "MenuBarIcon") {
            HistoryMenuView(
                synchronizer: synchronizer,
                transcription: transcription,
                shortcutName: shortcut.isEnabled ? shortcut.shortcut.displayName : "Menu only"
            ) {
                settingsWindow.show(
                    synchronizer: synchronizer,
                    shortcut: shortcut
                )
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: transcription.captureState) {
            overlay.update()
        }
        .onChange(of: transcription.activeTranscriptions) {
            overlay.update()
        }
        .onChange(of: transcription.lastError) {
            overlay.update()
        }
    }
}
