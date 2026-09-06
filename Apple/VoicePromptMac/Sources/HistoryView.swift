import ServiceManagement
import SwiftUI
import VoicePromptKit

struct HistoryView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    let credentials: EntraCredentialProvider
    let authorization: EntraAuthorizationCoordinator
    @AppStorage("backendURL") private var backendURL = "https://voiceprompt.invalid/"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        NavigationSplitView {
            List(synchronizer.history) { transcript in
                Button {
                    synchronizer.copy(transcript)
                } label: {
                    VStack(alignment: .leading) {
                        Text(transcript.markdown).lineLimit(3)
                        Text(transcript.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Last 48 Hours")
        } detail: {
            Form {
                TextField("Backend URL", text: $backendURL)
                LabeledContent("Connection", value: synchronizer.connected ? "Connected" : "Offline")
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                    }
                Button("Sign in with Microsoft") {
                    Task {
                        try? await authorization.signIn(using: credentials)
                        await synchronizer.reconcile()
                    }
                }
                Button("Sign Out", role: .destructive) {
                    Task { await credentials.signOut() }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await synchronizer.reconcile() }
    }
}
