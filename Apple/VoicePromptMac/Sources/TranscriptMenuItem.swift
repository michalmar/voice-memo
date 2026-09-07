import SwiftUI
import VoicePromptKit

struct TranscriptMenuItem: View {
    let transcript: Transcript
    let copy: () -> Void

    static func preview(_ markdown: String) -> String {
        let text = markdown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "Empty transcript" }
        return text.count > 80 ? String(text.prefix(80)) + "..." : text
    }

    var body: some View {
        Button(action: copy) {
            Text(verbatim: "\(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))  \(Self.preview(transcript.markdown))")
        }
        .help("Copy the full transcript to the clipboard")
        .accessibilityLabel(transcript.markdown)
        .accessibilityHint("Copy this transcript to the clipboard")
        .accessibilityIdentifier("history-copy-\(transcript.id)")
    }
}
