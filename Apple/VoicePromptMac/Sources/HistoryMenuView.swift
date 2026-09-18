import SwiftUI

struct HistoryMenuView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    @ObservedObject var transcription: TranscriptionController
    let shortcutName: String
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
            Button {
                dismiss()
                Task { await transcription.startListening() }
            } label: {
                HStack {
                    Label("Start Quick Transcription", systemImage: "waveform")
                    Spacer()
                    Text(shortcutName)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(transcription.captureState != .idle)
            .padding(.vertical, 4)
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
            if let error = synchronizer.pasteError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Dismiss") { synchronizer.dismissPasteError() }
                }
                .accessibilityIdentifier("direct-paste-error")
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
            Text(AppBuildInfo.current.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("app-build-info")
        }
        .padding(16)
        .frame(width: 480)
    }
}
