import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

public struct PendingRecording: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let expectedSegmentCount: Int
}

public actor UploadQueue {
    public enum QueueError: LocalizedError {
        case alreadyUploading, recordingNotFound, emptyRecording

        public var errorDescription: String? {
            switch self {
            case .alreadyUploading: return "This recording is already uploading."
            case .recordingNotFound: return "The saved recording could not be found."
            case .emptyRecording: return "No audio was recorded. Please try recording again."
            }
        }
    }

    private struct Index: Codable {
        var chunks: [ChunkMetadata]
        var recordings: [PendingRecording]
    }

    private let directory: URL
    private var index: Index
    private var activeUploads: Set<UUID> = []

    public init(directory: URL, recordingsDirectory: URL? = nil) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "queue.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            if let legacy = try? JSONDecoder().decode([ChunkMetadata].self, from: data) {
                // Older versions stored only chunks, losing the finalization count on relaunch.
                var recordings: [PendingRecording] = []
                for chunk in legacy where !recordings.contains(where: { $0.id == chunk.sessionID }) {
                    let count = legacy.filter { $0.sessionID == chunk.sessionID }.map(\.sequence).max()! + 1
                    recordings.append(PendingRecording(id: chunk.sessionID, expectedSegmentCount: count))
                }
                index = Index(chunks: legacy, recordings: recordings)
            } else {
                index = try JSONDecoder().decode(Index.self, from: data)
            }
        } else {
            index = Index(chunks: [], recordings: [])
        }
        if let recordingsDirectory {
            // iOS can move the sandbox when reinstalling. Never reuse a previous container's URL.
            index.chunks = index.chunks.map { chunk in
                ChunkMetadata(
                    sessionID: chunk.sessionID, sequence: chunk.sequence,
                    startedMilliseconds: chunk.startedMilliseconds,
                    durationMilliseconds: chunk.durationMilliseconds,
                    byteLength: chunk.byteLength, checksum: chunk.checksum,
                    fileURL: recordingsDirectory.appending(path: chunk.sessionID.uuidString)
                        .appending(path: String(format: "%06d.m4a", chunk.sequence)),
                    attempts: chunk.attempts
                )
            }
        }
    }

    public func enqueue(_ metadata: ChunkMetadata) throws {
        try enqueueRecording([metadata])
    }

    public func enqueueRecording(_ chunks: [ChunkMetadata]) throws {
        guard !chunks.isEmpty else { throw QueueError.emptyRecording }
        let previous = index
        for chunk in chunks where !index.chunks.contains(where: { $0.id == chunk.id }) {
            index.chunks.append(chunk)
        }
        for id in Set(chunks.map(\.sessionID)) {
            let count = index.chunks.filter { $0.sessionID == id }.map(\.sequence).max()! + 1
            index.recordings.removeAll { $0.id == id }
            index.recordings.append(PendingRecording(id: id, expectedSegmentCount: count))
        }
        do { try persist() }
        catch {
            index = previous
            throw error
        }
    }

    public func pending() -> [ChunkMetadata] { index.chunks }
    public func pendingRecordings() -> [PendingRecording] { index.recordings }

    public func submit(
        sessionID: UUID,
        using client: APIClient,
        maxAttempts: Int = 3,
        progress: @Sendable (Int, Int) async -> Void = { _, _ in }
    ) async throws -> Session {
        guard !activeUploads.contains(sessionID) else { throw QueueError.alreadyUploading }
        guard let recording = index.recordings.first(where: { $0.id == sessionID }) else {
            throw QueueError.recordingNotFound
        }
        activeUploads.insert(sessionID)
        defer { activeUploads.remove(sessionID) }
        let chunks = index.chunks.filter { $0.sessionID == sessionID }.sorted { $0.sequence < $1.sequence }
        let session = try await client.createSession(CreateSessionRequest(id: sessionID))
        var accepted = Set(session.acceptedSegments)
        await progress(accepted.count, recording.expectedSegmentCount)
        for chunk in chunks where !accepted.contains(chunk.sequence) {
            var attempts = 0
            while true {
                try Task.checkCancellation()
                do {
                    try await client.upload(chunk)
                    break
                } catch {
                    attempts += 1
                    guard attempts < maxAttempts, Self.isRetryable(error) else { throw error }
                    try await Task.sleep(for: .seconds(pow(2.0, Double(attempts - 1))))
                }
            }
            accepted.insert(chunk.sequence)
            await progress(accepted.count, recording.expectedSegmentCount)
        }
        let result: Session
        if session.expectedSegmentCount == recording.expectedSegmentCount,
           [.transcribing, .refining, .completed].contains(session.status) {
            result = session
        } else {
            result = try await client.complete(sessionID: sessionID, count: recording.expectedSegmentCount)
        }
        // Keep both audio and the expected count until the server acknowledges finalization.
        let previous = index
        index.chunks.removeAll { $0.sessionID == sessionID }
        index.recordings.removeAll { $0.id == sessionID }
        do { try persist() }
        catch {
            index = previous
            throw error
        }
        for chunk in chunks where FileManager.default.fileExists(atPath: chunk.fileURL.path) {
            do { try FileManager.default.removeItem(at: chunk.fileURL) }
            catch {
                #if canImport(OSLog)
                Logger(subsystem: "com.michalmar.voiceprompt", category: "Uploads")
                    .error("Could not remove uploaded audio: \(error.localizedDescription, privacy: .private)")
                #endif
            }
        }
        return result
    }

    public func drain(using client: APIClient, maxAttempts: Int = 3) async throws {
        for recording in index.recordings {
            _ = try await submit(sessionID: recording.id, using: client, maxAttempts: maxAttempts)
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if case APIClient.Error.server(let status, _) = error {
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
                .contains(error.code)
        }
        return false
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(index)
        #if os(iOS)
        try data.write(to: directory.appending(path: "queue.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appending(path: "queue.json"), options: .atomic)
        #endif
    }
}
