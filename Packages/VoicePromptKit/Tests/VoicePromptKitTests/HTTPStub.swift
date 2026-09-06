import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPStub: @unchecked Sendable {
    static let shared = HTTPStub()
    private let lock = NSLock()
    private var responses: [(Int, String)] = []
    private var requests: [URLRequest] = []

    func configure(_ responses: [(Int, String)]) {
        lock.withLock {
            self.responses = responses
            requests = []
        }
    }

    var recordedRequests: [URLRequest] { lock.withLock { requests } }

    func next(for request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
            let (status, body) = responses.removeFirst()
            if status == 0 { throw URLError(.notConnectedToInternet) }
            return (status, Data(body.utf8))
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func recording(
        id: UUID, status: String = "created", accepted: [Int] = [],
        expected: Int? = nil, error: String? = nil
    ) -> String {
        """
        {"id":"\(id)","status":"\(status)","accepted_segments":\(accepted),
        "expected_segment_count":\(expected.map(String.init) ?? "null"),
        "error_code":\(error.map { "\"\($0)\"" } ?? "null"),
        "created_at":"2026-09-06T18:30:00.123456Z","updated_at":"2026-09-06T18:30:01Z"}
        """
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try HTTPStub.shared.next(for: request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
