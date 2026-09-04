import AppKit
import Foundation
import UserNotifications
import VoicePromptKit

protocol ClipboardWriting { func copy(_ text: String) }
protocol NotificationSending { func completed() async }

struct SystemClipboard: ClipboardWriting {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SystemNotifications: NotificationSending {
    func completed() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "VoicePrompt"
        content.body = "A transcription is ready and has been copied."
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor
final class CompletionSynchronizer: ObservableObject {
    @Published private(set) var history: [Transcript] = []
    @Published private(set) var connected = false
    private let client: APIClient
    private let clipboard: any ClipboardWriting
    private let notifications: any NotificationSending
    private var copied: Set<UUID>

    init(client: APIClient, clipboard: any ClipboardWriting, notifications: any NotificationSending) {
        self.client = client
        self.clipboard = clipboard
        self.notifications = notifications
        copied = Set(UserDefaults.standard.stringArray(forKey: "copiedTranscriptIDs")?.compactMap(UUID.init) ?? [])
    }

    func reconcile(automaticallyCopyNewest: Bool = true) async {
        do {
            let summaries = try await client.transcripts()
            let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
            let fetched = await withTaskGroup(of: Transcript?.self) { group in
                for item in summaries where item.createdAt >= cutoff {
                    group.addTask { try? await self.client.transcript(id: item.id) }
                }
                return await group.reduce(into: []) { if let value = $1 { $0.append(value) } }
            }
            history = fetched.sorted { $0.createdAt > $1.createdAt }
            copied = copied.intersection(Set(history.map(\.id)))
            connected = true
            if automaticallyCopyNewest, let newest = history.first, !copied.contains(newest.id) {
                copy(newest)
                await notifications.completed()
            }
        } catch {
            connected = false
        }
    }

    func copy(_ transcript: Transcript) {
        clipboard.copy(transcript.markdown)
        copied.insert(transcript.id)
        UserDefaults.standard.set(copied.map(\.uuidString), forKey: "copiedTranscriptIDs")
    }

    func receiveCompletion(id: UUID) async {
        guard !copied.contains(id), let transcript = try? await client.transcript(id: id) else { return }
        history.removeAll { $0.id == id }
        history.insert(transcript, at: 0)
        copy(transcript)
        await notifications.completed()
    }
}

