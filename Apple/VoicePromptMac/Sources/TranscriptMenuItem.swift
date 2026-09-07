import SwiftUI
import VoicePromptKit

struct TranscriptMenuItem: View {
    let transcript: Transcript
    let isDeleting: Bool
    let copy: () -> Void
    let delete: () -> Void
    @State private var copied = false

    static func preview(_ markdown: String) -> String {
        let text = markdown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "Empty transcript" }
        return text.count > 80 ? String(text.prefix(80)) + "..." : text
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copy()
                copied = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: Self.preview(transcript.markdown))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .help("Copy the full transcript to the clipboard")
            .accessibilityLabel(transcript.markdown)
            .accessibilityHint("Copy this transcript to the clipboard")
            .accessibilityIdentifier("history-copy-\(transcript.id)")

            if isDeleting {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Deleting cloud transcript")
                    .frame(width: 28)
            } else {
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete cloud transcript")
                .accessibilityIdentifier("history-delete-\(transcript.id)")
                .help("Delete this transcript from cloud history")
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            copied = false
        }
    }
}
