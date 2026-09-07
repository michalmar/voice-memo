import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    @AppStorage("backendURL") private var backendURL =
        Bundle.main.object(forInfoDictionaryKey: "BACKEND_URL") as? String ?? "https://voiceprompt.invalid/"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            TextField("Backend URL", text: $backendURL)
            Text("Restart VoicePrompt after changing the backend URL.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Connection", value: synchronizer.status)
            LabeledContent("Microsoft account", value: synchronizer.isSignedIn ? "Signed in on this Mac" : "Not signed in on this Mac")
            if synchronizer.isSignedIn {
                LabeledContent("Live updates", value: synchronizer.liveConnected ? "Connected" : "Reconnecting; history refreshes every minute")
            }
            if let error = synchronizer.lastError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = synchronizer.liveError {
                Text("Live updates: \(error)").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            if let error = launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if synchronizer.isSignedIn {
                Button("Sign Out", role: .destructive) {
                    Task { await synchronizer.signOut() }
                }
            } else {
                Button("Sign in with Microsoft") {
                    Task { await synchronizer.signIn() }
                }
                .disabled(synchronizer.isSigningIn)
            }
            Button("Sync Now") { Task { await synchronizer.reconcile() } }
                .disabled(synchronizer.isSyncing || synchronizer.isSigningIn)
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480, minHeight: 440)
    }
}
