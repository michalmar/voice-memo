import SwiftUI
import VoicePromptKit

@main
struct VoicePromptMacApp: App {
    @StateObject private var synchronizer: CompletionSynchronizer

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
            clipboard: SystemClipboard(), notifications: SystemNotifications(),
            signIn: { try await authorization.signIn(using: credentials) },
            signOut: { await credentials.signOut() }
        )
        _synchronizer = StateObject(wrappedValue: sync)
        Task { await sync.start() }
    }

    var body: some Scene {
        MenuBarExtra("VoicePrompt", image: "MenuBarIcon") {
            Text(synchronizer.status)
            if !synchronizer.isSignedIn {
                Button("Sign in with Microsoft") { Task { await synchronizer.signIn() } }
                    .disabled(synchronizer.isSigningIn)
            }
            Button("Sync Now") { Task { await synchronizer.reconcile() } }
                .disabled(synchronizer.isSyncing || synchronizer.isSigningIn)
            SettingsLink { Text("History & Settings") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            HistoryView(synchronizer: synchronizer)
        }
    }
}
