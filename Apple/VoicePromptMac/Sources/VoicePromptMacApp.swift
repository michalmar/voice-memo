import SwiftUI
import VoicePromptKit

private struct MacCredentials: CredentialProvider {
    func identityToken() async throws -> (token: String, nonce: String) {
        throw CocoaError(.userAuthenticationRequired)
    }
}

@main
struct VoicePromptMacApp: App {
    @StateObject private var synchronizer: CompletionSynchronizer
    private let events: EventClient

    init() {
        let baseURL = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? "https://voiceprompt.invalid/")!
        let client = APIClient(baseURL: baseURL, credentials: MacCredentials())
        let sync = CompletionSynchronizer(client: client, clipboard: SystemClipboard(), notifications: SystemNotifications())
        _synchronizer = StateObject(wrappedValue: sync)
        events = EventClient(api: client)
        Task {
            await sync.reconcile()
            await events.connect { id in await sync.receiveCompletion(id: id) }
        }
    }

    var body: some Scene {
        MenuBarExtra("VoicePrompt", systemImage: "mic.fill") {
            Text(synchronizer.connected ? "Connected" : "Offline")
            Button("Sync Now") { Task { await synchronizer.reconcile() } }
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
