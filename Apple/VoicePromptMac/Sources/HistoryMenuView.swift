import SwiftUI

struct HistoryMenuView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VoicePrompt").font(.headline)
                Spacer()
                Text(synchronizer.status).foregroundStyle(.secondary)
            }
            Divider()
            Text("Last 48 Hours").font(.subheadline).foregroundStyle(.secondary)
            if synchronizer.history.isEmpty {
                Text(synchronizer.isSignedIn ? "No transcripts yet" : "Sign in to see your transcripts")
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(synchronizer.history) { transcript in
                            TranscriptMenuItem(
                                transcript: transcript,
                                isDeleting: synchronizer.deletingTranscriptIDs.contains(transcript.id),
                                copy: { synchronizer.copy(transcript) },
                                delete: {
                                    Task { await synchronizer.delete(transcript) }
                                }
                            )
                            Divider()
                        }
                    }
                }
                .frame(height: min(CGFloat(synchronizer.history.count) * 80, 400))
            }
            if let error = synchronizer.deletionError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { synchronizer.dismissDeletionError() }
                }
                .accessibilityIdentifier("history-delete-error")
            }
            Divider()
            if !synchronizer.isSignedIn {
                Button("Sign in with Microsoft") { Task { await synchronizer.signIn() } }
                    .disabled(synchronizer.isSigningIn)
            }
            HStack {
                Button("Sync Now") { Task { await synchronizer.reconcile() } }
                    .disabled(synchronizer.isSyncing || synchronizer.isSigningIn)
                Button("Settings...") {
                    dismiss()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
