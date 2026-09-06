import SwiftUI
import VoicePromptKit

@main
struct VoicePromptMacApp: App {
    @StateObject private var synchronizer: CompletionSynchronizer
    private let events: EventClient
    private let credentials: EntraCredentialProvider
    private let authorization: EntraAuthorizationCoordinator

    init() {
        let baseURL = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? "https://voiceprompt.invalid/")!
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
        self.credentials = credentials
        authorization = EntraAuthorizationCoordinator(configuration: configuration)
        let client = APIClient(baseURL: baseURL, credentials: credentials)
        let sync = CompletionSynchronizer(client: client, clipboard: SystemClipboard(), notifications: SystemNotifications())
        _synchronizer = StateObject(wrappedValue: sync)
        let events = EventClient(api: client)
        self.events = events
        Task {
            await sync.reconcile()
            await events.connect { id in await sync.receiveCompletion(id: id) }
        }
    }

    var body: some Scene {
        MenuBarExtra("VoicePrompt", image: "MenuBarIcon") {
            Text(synchronizer.connected ? "Connected" : "Offline")
            Button("Sync Now") { Task { await synchronizer.reconcile() } }
            SettingsLink { Text("History & Settings") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            HistoryView(
                synchronizer: synchronizer,
                credentials: credentials,
                authorization: authorization
            )
        }
    }
}
