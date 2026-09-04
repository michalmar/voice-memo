import Foundation
import SwiftUI
import UIKit
import VoicePromptKit

@MainActor
final class RecordingViewModel: ObservableObject {
    enum State: String {
        case ready = "Ready"
        case recording = "Recording"
        case uploading = "Uploading"
        case processing = "Processing"
        case complete = "Complete"
        case offline = "Offline"
        case error = "Needs attention"
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var backendReady = false
    private let recorder: any AudioRecording
    private let client: APIClient
    private let queue: UploadQueue
    private var sessionID: UUID?

    init(recorder: any AudioRecording, client: APIClient, queue: UploadQueue) {
        self.recorder = recorder
        self.client = client
        self.queue = queue
    }

    func warmBackend() async {
        backendReady = await client.warm()
    }

    func start() async {
        guard state != .recording else { return }
        let id = UUID()
        sessionID = id
        do {
            try await recorder.start(sessionID: id)
            state = .recording
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                _ = try? await client.createSession(CreateSessionRequest(id: id))
            }
        } catch {
            state = .error
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func stop() async {
        guard state == .recording, let id = sessionID else { return }
        do {
            let chunks = try await recorder.stop()
            for chunk in chunks { try await queue.enqueue(chunk) }
            state = .uploading
            try await client.createSession(CreateSessionRequest(id: id))
            try await queue.drain(using: client)
            _ = try await client.complete(sessionID: id, count: chunks.count)
            state = .processing
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            state = .offline
        }
    }

    func toggle() async {
        state == .recording ? await stop() : await start()
    }
}

