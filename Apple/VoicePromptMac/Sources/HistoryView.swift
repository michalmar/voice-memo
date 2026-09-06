import ServiceManagement
import SwiftUI
import VoicePromptKit

struct HistoryView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    @AppStorage("backendURL") private var backendURL =
        Bundle.main.object(forInfoDictionaryKey: "BACKEND_URL") as? String ?? "https://voiceprompt.invalid/"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var copyFeedback: CopyFeedback?

    private struct CopyFeedback {
        let transcriptID: UUID
        let id = UUID()
    }

    var body: some View {
        NavigationSplitView {
            List(synchronizer.history) { transcript in
                Button {
                    synchronizer.copy(transcript)
                    copyFeedback = CopyFeedback(transcriptID: transcript.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transcript.markdown).lineLimit(3)
                            Text(transcript.createdAt, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if copyFeedback?.transcriptID == transcript.id {
                            Label("Copied", systemImage: "checkmark")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the full transcript to the clipboard")
                .accessibilityLabel(transcript.markdown)
                .accessibilityHint("Copy this transcript to the clipboard")
                .accessibilityValue(copyFeedback?.transcriptID == transcript.id ? "Copied to clipboard" : "")
                .accessibilityIdentifier("history-copy-\(transcript.id)")
            }
            .navigationTitle("Last 48 Hours")
            .safeAreaInset(edge: .bottom) {
                Text("Click a record to copy its full transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            }
        } detail: {
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
                        if enabled { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
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
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await synchronizer.reconcile() }
        .task(id: copyFeedback?.id) {
            guard copyFeedback != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            copyFeedback = nil
        }
    }
}
