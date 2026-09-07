import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol CredentialProvider: Sendable {
    func accessToken() async throws -> String
}

public actor APIClient {
    public enum Error: LocalizedError {
        case invalidResponse
        case server(status: Int, detail: String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The server returned an unreadable response."
            case .server(let status, let detail):
                if status == 401 { return "Your sign-in has expired. Sign in with Microsoft again." }
                if status == 403 { return "Your Microsoft account does not have access to this backend." }
                return "Server error (\(status)): \(detail)"
            }
        }
    }

    private let baseURL: URL
    private let credentials: any CredentialProvider
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, credentials: any CredentialProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func warm() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health/ready"))
        request.timeoutInterval = 10
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func createSession(_ body: CreateSessionRequest) async throws -> Session {
        try await send(path: "v1/sessions", method: "POST", body: encoder.encode(body))
    }

    public func recordingSession(id: UUID) async throws -> Session {
        try await send(path: "v1/sessions/\(id)")
    }

    public func upload(_ chunk: ChunkMetadata) async throws {
        let bytes = try Data(contentsOf: chunk.fileURL, options: .mappedIfSafe)
        var headers = [
            "Content-Type": "audio/mp4",
            "X-Content-SHA256": chunk.checksum,
            "X-Started-Ms": String(chunk.startedMilliseconds),
            "X-Duration-Ms": String(chunk.durationMilliseconds),
        ]
        headers["Content-Length"] = String(chunk.byteLength)
        let _: ChunkReceipt = try await send(
            path: "v1/sessions/\(chunk.sessionID)/chunks/\(chunk.sequence)",
            method: "PUT",
            body: bytes,
            headers: headers
        )
    }

    public func complete(sessionID: UUID, count: Int) async throws -> Session {
        try await send(
            path: "v1/sessions/\(sessionID)/complete",
            method: "POST",
            body: encoder.encode(CompleteSessionRequest(expectedSegmentCount: count))
        )
    }

    public func transcripts() async throws -> [TranscriptSummary] {
        let list: TranscriptList = try await send(path: "v1/transcripts")
        return list.items
    }

    public func transcript(id: UUID) async throws -> Transcript {
        try await send(path: "v1/transcripts/\(id)")
    }

    public func deleteTranscript(id: UUID) async throws {
        _ = try await request(path: "v1/transcripts/\(id)", method: "DELETE")
    }

    public func eventToken() async throws -> EventToken {
        try await send(path: "v1/events/token", method: "POST", body: Data())
    }

    private func send<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let data = try await request(path: path, method: method, body: body, headers: headers)
        return try decoder.decode(T.self, from: data)
    }

    private func request(
        path: String,
        method: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let token = try await credentials.accessToken()
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Correlation-ID")
        if body != nil && headers["Content-Type"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? decoder.decode(ServerError.self, from: data))?.detail
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw Error.server(status: http.statusCode, detail: detail)
        }
        return data
    }
}

private struct ChunkReceipt: Decodable {}
private struct ServerError: Decodable { let detail: String }
