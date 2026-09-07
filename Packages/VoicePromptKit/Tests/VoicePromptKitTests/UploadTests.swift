import Foundation
import Testing
import VoicePromptKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct TestCredentials: CredentialProvider {
    func accessToken() async throws -> String { "test-token" }
}

@Suite(.serialized)
struct UploadTests {
    private func client() -> APIClient {
        APIClient(baseURL: URL(string: "https://voiceprompt.test/")!, credentials: TestCredentials(), session: HTTPStub.session())
    }

    @Test func deleteTranscriptAcceptsEmpty204AndUsesAuthenticatedDelete() async throws {
        let id = UUID()
        HTTPStub.shared.configure([(204, "")])
        try await client().deleteTranscript(id: id)
        let request = try #require(HTTPStub.shared.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/transcripts/\(id)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 30)
    }

    @Test func deleteTranscriptPropagatesServerAndNetworkFailures() async throws {
        for status in [401, 403, 404, 500] {
            HTTPStub.shared.configure([(status, "{\"detail\":\"Cannot delete\"}")])
            do {
                try await client().deleteTranscript(id: UUID())
                Issue.record("Expected deletion failure for HTTP \(status)")
            } catch APIClient.Error.server(let actualStatus, let detail) {
                #expect(actualStatus == status)
                #expect(detail == "Cannot delete")
            }
        }
        HTTPStub.shared.configure([(0, "")])
        await #expect(throws: URLError.self) {
            try await client().deleteTranscript(id: UUID())
        }
    }

    private func chunk(directory: URL, id: UUID = UUID(), sequence: Int = 0) throws -> ChunkMetadata {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: String(format: "%06d.m4a", sequence))
        try Data("audio".utf8).write(to: file)
        return ChunkMetadata(
            sessionID: id, sequence: sequence, startedMilliseconds: sequence * 30_000,
            durationMilliseconds: 1_000, byteLength: 5, checksum: String(repeating: "a", count: 64),
            fileURL: file, attempts: 5
        )
    }

    @Test func legacyQueueRebasesFilesAfterSimulatorReinstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploads = directory.appending(path: "Uploads")
        let recordings = directory.appending(path: "Recordings")
        let id = UUID()
        let old = try chunk(directory: directory.appending(path: "old-container"), id: id)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try JSONEncoder().encode([old]).write(to: uploads.appending(path: "queue.json"))
        let relocated = try chunk(directory: recordings.appending(path: id.uuidString), id: id)
        try FileManager.default.removeItem(at: old.fileURL)
        let queue = try UploadQueue(directory: uploads, recordingsDirectory: recordings)
        #expect(await queue.pending().first?.fileURL == relocated.fileURL)
        #expect(await queue.pendingRecordings().first?.expectedSegmentCount == 1)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
        ])
        let result = try await queue.submit(sessionID: id, using: client())
        #expect(result.status == .transcribing)
        #expect(await queue.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: relocated.fileURL.path))
        #expect(HTTPStub.shared.recordedRequests.map(\.httpMethod) == ["POST", "PUT", "POST"])
        let restored = try UploadQueue(directory: uploads, recordingsDirectory: recordings)
        #expect(await restored.pendingRecordings().isEmpty)
    }

    @Test func failedFinalizationKeepsAudioAndCountAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try chunk(directory: directory)
        let queue = try UploadQueue(directory: directory)
        try await queue.enqueueRecording([metadata])
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: metadata.sessionID)), (200, "{}"), (503, "{\"detail\":\"Try later\"}"),
        ])
        await #expect(throws: APIClient.Error.self) {
            try await queue.submit(sessionID: metadata.sessionID, using: client())
        }
        #expect(FileManager.default.fileExists(atPath: metadata.fileURL.path))
        let restored = try UploadQueue(directory: directory)
        #expect(await restored.pendingRecordings().first?.expectedSegmentCount == 1)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: metadata.sessionID, status: "uploading", accepted: [0])),
            (202, HTTPStub.recording(id: metadata.sessionID, status: "transcribing", accepted: [0], expected: 1)),
        ])
        _ = try await restored.submit(sessionID: metadata.sessionID, using: client())
        #expect(HTTPStub.shared.recordedRequests.map(\.httpMethod) == ["POST", "POST"])
        #expect(await restored.pendingRecordings().isEmpty)
    }

    @Test func authorizationFailureIsNotRetriedOrHidden() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try chunk(directory: directory)
        let queue = try UploadQueue(directory: directory)
        try await queue.enqueue(metadata)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: metadata.sessionID)), (401, "{\"detail\":\"Invalid token\"}"),
        ])
        do {
            _ = try await queue.submit(sessionID: metadata.sessionID, using: client())
            Issue.record("Expected authentication error")
        } catch APIClient.Error.server(let status, _) {
            #expect(status == 401)
        }
        #expect(HTTPStub.shared.recordedRequests.count == 2)
        #expect(await queue.pending().count == 1)
    }

    @Test func newerRecordingDoesNotDrainBrokenOlderRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try chunk(directory: directory.appending(path: "old"))
        let recent = try chunk(directory: directory.appending(path: "recent"))
        let queue = try UploadQueue(directory: directory)
        try await queue.enqueue(old)
        try FileManager.default.removeItem(at: old.fileURL)
        try await queue.enqueue(recent)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: recent.sessionID)), (200, "{}"),
            (202, HTTPStub.recording(id: recent.sessionID, status: "transcribing", accepted: [0], expected: 1)),
        ])
        _ = try await queue.submit(sessionID: recent.sessionID, using: client())
        #expect(await queue.pending() == [old])
    }

    @Test func serverAcceptedFinalizationDoesNotResubmitIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try chunk(directory: directory)
        let queue = try UploadQueue(directory: directory)
        try await queue.enqueue(metadata)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: metadata.sessionID, status: "refining", accepted: [0], expected: 1)),
        ])
        let result = try await queue.submit(sessionID: metadata.sessionID, using: client())
        #expect(result.status == .refining)
        #expect(HTTPStub.shared.recordedRequests.count == 1)
    }

    @Test func corruptQueueIsNotSilentlyDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "queue.json"))
        #expect(throws: DecodingError.self) { try UploadQueue(directory: directory) }
    }

    @Test func transientUploadFailureCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = try chunk(directory: directory)
        let queue = try UploadQueue(directory: directory)
        try await queue.enqueue(metadata)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: metadata.sessionID)), (503, "{\"detail\":\"Try later\"}"), (200, "{}"),
            (202, HTTPStub.recording(id: metadata.sessionID, status: "transcribing", accepted: [0], expected: 1)),
        ])
        _ = try await queue.submit(sessionID: metadata.sessionID, using: client())
        #expect(HTTPStub.shared.recordedRequests.count == 4)
        #expect(await queue.pending().isEmpty)
    }

    #if canImport(AuthenticationServices)
    @Test func microsoftTokenExchangeSurfacesOAuthError() async throws {
        let configuration = EntraConfiguration(
            tenantID: "test-tenant", clientID: "test-client",
            redirectURI: "voiceprompt-test://auth", apiScope: "api://test/access"
        )
        let credentials = EntraCredentialProvider(
            configuration: configuration,
            store: KeychainCredentialStore(service: "voiceprompt-tests-\(UUID())"),
            session: HTTPStub.session()
        )
        HTTPStub.shared.configure([
            (400, "{\"error\":\"invalid_client\",\"error_description\":\"Check the public client registration.\"}"),
        ])
        do {
            try await credentials.exchangeAuthorizationCode("test-code", verifier: "test-verifier")
            Issue.record("Expected OAuth error")
        } catch EntraCredentialProvider.Error.authorization(let code, let description) {
            #expect(code == "invalid_client")
            #expect(description == "Check the public client registration.")
        }
        #expect(HTTPStub.shared.recordedRequests.first?.timeoutInterval == 30)
    }
    #endif
}
