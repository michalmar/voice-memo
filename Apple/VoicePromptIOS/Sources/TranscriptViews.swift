import SwiftUI
import UIKit
import VoicePromptKit

struct TranscriptHistoryView: View {
    @ObservedObject var library: TranscriptLibrary
    let signedIn: Bool

    var body: some View {
        NavigationStack {
            List {
                if !signedIn {
                    Text("Sign in with Microsoft on the Record tab to see your history.")
                } else {
                    if library.refreshing {
                        ProgressView("Loading history...")
                    }
                    if let error = library.historyError {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { Task { await library.refresh() } }
                    } else if library.history.isEmpty && !library.refreshing {
                        Text("No transcripts yet. Completed recordings will appear here.")
                    }
                    ForEach(library.history) { item in
                        NavigationLink {
                            ScrollView {
                                TranscriptContentView(library: library, id: item.id)
                                    .padding()
                            }
                            .navigationTitle("Transcript")
                            .navigationBarTitleDisplayMode(.inline)
                            .task { await library.load(item.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text("Expires \(item.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Cloud history is kept for 48 hours. Copy or share text to keep it longer. Use the same Microsoft account on your Mac to see the same records.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("History")
            .refreshable { await library.refresh() }
            .toolbar {
                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Refresh history", systemImage: "arrow.clockwise")
                }
                .disabled(!signedIn || library.refreshing)
            }
        }
    }
}

struct CompletedTranscriptView: View {
    @ObservedObject var library: TranscriptLibrary

    var body: some View {
        if library.completedSessionID != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your transcript").font(.title2.bold())
                if library.loadingCompletion && library.completedTranscriptID == nil {
                    ProgressView("Loading transcript...")
                }
                if let error = library.completionError {
                    Text(error).foregroundStyle(.red)
                    Button("Retry loading transcript") {
                        guard let id = library.completedSessionID else { return }
                        Task { await library.loadCompleted(sessionID: id) }
                    }
                }
                if let id = library.completedTranscriptID {
                    TranscriptContentView(library: library, id: id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptContentView: View {
    @ObservedObject var library: TranscriptLibrary
    let id: UUID
    @State private var copied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if library.deleted.contains(id) {
                Label("Transcript deleted.", systemImage: "trash")
                    .foregroundStyle(.secondary)
            } else if library.loading.contains(id) {
                ProgressView("Loading transcript...")
            } else if let transcript = library.transcripts[id] {
                Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button {
                        UIPasteboard.general.string = transcript.markdown
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: transcript.markdown) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        Task { await library.delete(id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(library.deleting.contains(id))
                    .accessibilityHint("Immediately deletes this transcript from cloud history on all devices")
                }
                if library.deleting.contains(id) {
                    ProgressView("Deleting transcript...")
                }
                if let error = library.deletionErrors[id] {
                    Text("Could not delete: \(error) Tap Delete to retry.")
                        .foregroundStyle(.red)
                }
                Text(verbatim: transcript.markdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = library.errors[id] {
                Text(error).foregroundStyle(.red)
                Button("Retry loading transcript") { Task { await library.load(id) } }
            }
        }
        .onChange(of: id) { _, _ in copied = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                copied = false
                Task { await library.load(id) }
            }
        }
    }
}
