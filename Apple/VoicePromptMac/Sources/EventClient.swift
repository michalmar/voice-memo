import Foundation
import VoicePromptKit

protocol CompletionEventStreaming: Sendable {
    func connect(
        onConnected: @escaping @Sendable () async -> Void,
        onCompletion: @escaping @Sendable (UUID) async -> Void,
        onFailure: @escaping @Sendable (String) async -> Void
    ) async
    func disconnect() async
}

actor EventClient: CompletionEventStreaming {
    struct Event: Decodable {
        let type: String
        let transcriptID: UUID
        enum CodingKeys: String, CodingKey {
            case type
            case transcriptID = "transcript_id"
        }
    }

    private let api: APIClient
    private var task: URLSessionWebSocketTask?
    private var connectionID: UUID?

    init(api: APIClient) { self.api = api }

    func connect(
        onConnected: @escaping @Sendable () async -> Void,
        onCompletion: @escaping @Sendable (UUID) async -> Void,
        onFailure: @escaping @Sendable (String) async -> Void
    ) async {
        let id = UUID()
        connectionID = id
        while !Task.isCancelled, connectionID == id {
            do {
                let token = try await api.eventToken()
                guard !Task.isCancelled, connectionID == id else { return }
                let socket = URLSession.shared.webSocketTask(with: token.url)
                task = socket
                socket.resume()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    socket.sendPing { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                await onConnected()
                while !Task.isCancelled, connectionID == id {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    let event = try JSONDecoder().decode(Event.self, from: data)
                    if event.type == "transcript.completed" {
                        await onCompletion(event.transcriptID)
                    }
                }
            } catch {
                guard !Task.isCancelled, connectionID == id else { return }
                task?.cancel(with: .goingAway, reason: nil)
                task = nil
                await onFailure(error.localizedDescription)
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
    }

    func disconnect() {
        connectionID = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
