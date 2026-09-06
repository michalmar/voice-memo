import Foundation
import VoicePromptKit

actor EventClient {
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

    init(api: APIClient) { self.api = api }

    func connect(onCompletion: @escaping @Sendable (UUID) async -> Void) async {
        while !Task.isCancelled {
            do {
                let token = try await api.eventToken()
                let socket = URLSession.shared.webSocketTask(with: token.url)
                task = socket
                socket.resume()
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    if let event = try? JSONDecoder().decode(Event.self, from: data),
                       event.type == "transcript.completed" {
                        await onCompletion(event.transcriptID)
                    }
                }
            } catch {
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

