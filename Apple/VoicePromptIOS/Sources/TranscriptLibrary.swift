import Foundation
import OSLog
import SwiftUI
import VoicePromptKit

@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var history: [TranscriptSummary] = []
    @Published private(set) var transcripts: [UUID: Transcript] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var deleting: Set<UUID> = []
    @Published private(set) var deleted: Set<UUID> = []
    @Published private(set) var deletionErrors: [UUID: String] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var historyError: String?
    @Published private(set) var completedSessionID: UUID?
    @Published private(set) var completedTranscriptID: UUID?
    @Published private(set) var completionError: String?
    @Published private(set) var loadingCompletion = false
    private let client: APIClient
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.ios", category: "Transcripts")
    private var authenticated = false
    private var generation = UUID()
    private var refreshID = UUID()
    private var completionID = UUID()
    private var historyRevision = UUID()

    init(client: APIClient) { self.client = client }

    func setAuthenticated(_ value: Bool) {
        authenticated = value
        guard !value else { return }
        generation = UUID()
        refreshID = UUID()
        history = []
        transcripts = [:]
        loading = []
        errors = [:]
        deleting = []
        deleted = []
        deletionErrors = [:]
        refreshing = false
        historyError = nil
        clearCompleted()
    }

    func clearCompleted() {
        completionID = UUID()
        completedSessionID = nil
        completedTranscriptID = nil
        completionError = nil
        loadingCompletion = false
    }

    func refresh() async {
        guard authenticated else { return }
        let account = generation
        let request = UUID()
        refreshID = request
        refreshing = true
        historyError = nil
        defer { if refreshID == request { refreshing = false } }
        do {
            let items = try await client.transcripts()
            try Task.checkCancellation()
            guard generation == account, refreshID == request else { return }
            updateHistory(items)
        } catch is CancellationError {
            return
        } catch {
            guard generation == account, refreshID == request else { return }
            historyError = error.localizedDescription
            logger.error("History refresh failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func load(_ id: UUID) async {
        guard authenticated, !loading.contains(id), !deleting.contains(id), !deleted.contains(id) else { return }
        let account = generation
        let revision = historyRevision
        loading.insert(id)
        errors[id] = nil
        defer { if generation == account { loading.remove(id) } }
        do {
            let transcript = try await client.transcript(id: id)
            try Task.checkCancellation()
            guard generation == account, !deleted.contains(id) else { return }
            guard historyRevision == revision || history.contains(where: { $0.id == id }) else {
                removeUnavailable(id)
                return
            }
            guard transcript.expiresAt > Date() else {
                removeUnavailable(id)
                return
            }
            transcripts[id] = transcript
        } catch is CancellationError {
            return
        } catch {
            guard generation == account, !deleted.contains(id) else { return }
            if case APIClient.Error.server(status: 404, detail: _) = error {
                removeUnavailable(id)
            } else {
                transcripts[id] = nil
                errors[id] = error.localizedDescription
                logger.error("Transcript download failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func delete(_ id: UUID) async {
        guard authenticated, !deleting.contains(id), !deleted.contains(id) else { return }
        let account = generation
        deleting.insert(id)
        deletionErrors[id] = nil
        defer { if generation == account { deleting.remove(id) } }
        do {
            try await client.deleteTranscript(id: id)
        } catch {
            guard generation == account else { return }
            // Another device may have already deleted the same cloud record.
            if case APIClient.Error.server(status: 404, detail: _) = error {
                finishDeletion(id)
            } else {
                deletionErrors[id] = error.localizedDescription
                logger.error("Transcript deletion failed: \(error.localizedDescription, privacy: .private)")
            }
            return
        }
        guard generation == account else { return }
        finishDeletion(id)
    }

    private func finishDeletion(_ id: UUID) {
        // Keep a tombstone so in-flight downloads and list responses cannot restore it.
        deleted.insert(id)
        transcripts[id] = nil
        history.removeAll { $0.id == id }
        errors[id] = nil
        deletionErrors[id] = nil
        if completedTranscriptID == id { clearCompleted() }
    }

    func loadCompleted(sessionID: UUID) async {
        guard authenticated else { return }
        let account = generation
        let request = UUID()
        let revision = historyRevision
        completionID = request
        refreshID = request
        refreshing = false
        historyError = nil
        completedSessionID = sessionID
        completedTranscriptID = nil
        completionError = nil
        loadingCompletion = true
        defer { if completionID == request { loadingCompletion = false } }
        do {
            let items = try await client.transcripts()
            try Task.checkCancellation()
            guard generation == account, completionID == request else { return }
            if refreshID == request { updateHistory(items) }
            // Prefer a newer refresh if one finished while this lookup was in flight.
            let candidates = historyRevision == revision ? items : history
            guard let summary = candidates.first(where: {
                $0.sessionID == sessionID && $0.expiresAt > Date() && !deleted.contains($0.id)
            }) else {
                completionError = "This transcript is no longer available. It may have expired or been deleted."
                return
            }
            completedTranscriptID = summary.id
            await load(summary.id)
        } catch is CancellationError {
            return
        } catch {
            guard generation == account, completionID == request else { return }
            completionError = error.localizedDescription
            logger.error("Completed transcript lookup failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func updateHistory(_ items: [TranscriptSummary]) {
        historyRevision = UUID()
        history = items.filter { $0.expiresAt > Date() && !deleted.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        let available = Set(history.map(\.id))
        for id in Array(transcripts.keys) where !available.contains(id) {
            removeUnavailable(id)
        }
    }

    private func removeUnavailable(_ id: UUID) {
        transcripts[id] = nil
        history.removeAll { $0.id == id }
        errors[id] = "This transcript is no longer available. It may have expired or been deleted."
    }
}
