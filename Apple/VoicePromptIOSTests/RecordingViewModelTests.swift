import Foundation
import Testing
import VoicePromptKit
@testable import VoicePromptIOS

private actor StubCredentials: CredentialProvider {
    var signedIn = false
    func setSignedIn(_ value: Bool) { signedIn = value }
    func accessToken() async throws -> String {
        guard signedIn else { throw EntraCredentialProvider.Error.signInRequired }
        return "test-token"
    }
}

private actor StubRecorder: AudioRecording {
    let directory: URL
    var sessionID: UUID?
    var stopCount = 0
    var suspendStart = false
    private var startRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(directory: URL) { self.directory = directory }
    func pauseStart() { suspendStart = true }
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func waitForStart() async {
        if startRequested { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func start(sessionID: UUID) async throws {
        startRequested = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        if suspendStart { await withCheckedContinuation { startContinuation = $0 } }
        self.sessionID = sessionID
        let folder = directory.appending(path: sessionID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appending(path: "000000.m4a"))
    }

    func stop() async throws -> [ChunkMetadata] {
        stopCount += 1
        try await Task.sleep(for: .milliseconds(20))
        let id = try #require(sessionID)
        return [ChunkMetadata(
            sessionID: id, sequence: 0, startedMilliseconds: 0,
            durationMilliseconds: 1_000, byteLength: 5, checksum: String(repeating: "a", count: 64),
            fileURL: directory.appending(path: id.uuidString).appending(path: "000000.m4a"), attempts: 0
        )]
    }
}

@Suite(.serialized)
@MainActor
struct RecordingViewModelTests {
    private struct Harness {
        let directory: URL
        let credentials: StubCredentials
        let recorder: StubRecorder
        let queue: UploadQueue
        let model: RecordingViewModel
    }

    private func makeHarness(signInFails: Bool = false) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let credentials = StubCredentials()
        let recordings = directory.appending(path: "Recordings")
        let recorder = StubRecorder(directory: recordings)
        let queue = try UploadQueue(directory: directory.appending(path: "Uploads"), recordingsDirectory: recordings)
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let model = RecordingViewModel(
            recorder: recorder, client: client, queue: queue, credentials: credentials,
            signIn: {
                if signInFails {
                    throw EntraCredentialProvider.Error.authorization(code: "invalid_client", description: "Check registration.")
                }
                await credentials.setSignedIn(true)
            },
            signOut: { await credentials.setSignedIn(false) }
        )
        return Harness(directory: directory, credentials: credentials, recorder: recorder, queue: queue, model: model)
    }

    @Test func signInSuccessAndRestorationUpdateVisibleState() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.restoreAuthentication()
        #expect(h.model.authenticationState == .signedOut)
        await h.model.signIn()
        #expect(h.model.authenticationState == .signedIn)
        #expect(h.model.authenticationMessage == nil)
        await h.model.restoreAuthentication()
        #expect(h.model.authenticationState == .signedIn)
        await h.model.signOut()
        #expect(h.model.authenticationState == .signedOut)
    }

    @Test func simulatorKeychainCanSaveReadAndUpdateCredentials() async throws {
        let store = KeychainCredentialStore(service: "voiceprompt-tests-\(UUID())")
        do {
            try await store.save(Data("first".utf8), account: "test")
            #expect(try await store.read(account: "test") == Data("first".utf8))
            try await store.save(Data("updated".utf8), account: "test")
            #expect(try await store.read(account: "test") == Data("updated".utf8))
        } catch {
            await store.clear(account: "test")
            throw error
        }
        await store.clear(account: "test")
        #expect(try await store.read(account: "test") == nil)
    }

    @Test func failedSignInDisplaysReason() async throws {
        let h = try makeHarness(signInFails: true)
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        #expect(h.model.authenticationState == .signedOut)
        #expect(h.model.authenticationMessage?.contains("invalid_client") == true)
    }

    @Test func signedOutRecordingIsSavedAndCanBeRetriedAfterSignIn() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        HTTPStub.shared.configure([])
        await h.model.start()
        let id = try #require(await h.recorder.sessionID)
        await h.model.stop()
        #expect(h.model.state == .error)
        #expect(h.model.authenticationState == .signedOut)
        #expect(h.model.errorMessage?.contains("Sign in with Microsoft") == true)
        #expect(h.model.pendingRecordingCount == 1)
        #expect(HTTPStub.shared.recordedRequests.isEmpty)
        await h.model.signIn()
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
        ])
        await h.model.retryUploads()
        #expect(h.model.state == .processing)
        #expect(h.model.pendingRecordingCount == 0)
        #expect(h.model.errorMessage == nil)
    }

    @Test func uploadReachesCompletedInsteadOfStayingInProcessing() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        await h.model.start()
        let id = try #require(await h.recorder.sessionID)
        let transcriptID = UUID()
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "refining", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "completed", accepted: [0], expected: 1)),
            (200, transcriptList([transcriptJSON(id: transcriptID, sessionID: id)])),
            (200, transcriptJSON(id: transcriptID, sessionID: id)),
        ])
        await h.model.stop()
        #expect(h.model.state == .processing)
        await h.model.monitorProcessing(pollInterval: .zero, maxPolls: 2)
        #expect(h.model.state == .complete)
        #expect(h.model.processingSessionID == nil)
        #expect(h.model.errorMessage == nil)
        #expect(h.model.transcriptLibrary.completedTranscriptID == transcriptID)
        #expect(h.model.transcriptLibrary.transcripts[transcriptID]?.markdown == "# Prompt\n\nKeep all lines.\nSecond line.")
    }

    @Test func overlappingStopsOnlySaveAndUploadOnce() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        await h.model.start()
        let id = try #require(await h.recorder.sessionID)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
        ])
        async let first: Void = h.model.stop()
        async let second: Void = h.model.stop()
        _ = await (first, second)
        #expect(await h.recorder.stopCount == 1)
        #expect(HTTPStub.shared.recordedRequests.count == 3)
    }

    @Test func holdReleaseWhilePermissionIsPendingStopsAfterStartup() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.recorder.pauseStart()
        let start = Task { await h.model.start() }
        await h.recorder.waitForStart()
        #expect(h.model.state == .starting)
        #expect(!h.model.canStartRecording)
        await h.model.stop()
        await h.recorder.resumeStart()
        await start.value
        #expect(await h.recorder.stopCount == 1)
        #expect(h.model.pendingRecordingCount == 1)
        #expect(h.model.state != .recording)
    }

    @Test func networkFailurePreservesRecordingAndShowsError() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        await h.model.start()
        HTTPStub.shared.configure([(0, "")])
        await h.model.stop()
        #expect(h.model.state == .offline)
        #expect(h.model.errorMessage != nil)
        #expect(h.model.pendingRecordingCount == 1)
        #expect(await h.queue.pending().count == 1)
        #expect(h.model.canStartRecording)
    }

    @Test func processingFailureAndTimeoutAreVisible() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        await h.model.start()
        let id = try #require(await h.recorder.sessionID)
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "failed", accepted: [0], expected: 1, error: "speech_failed")),
        ])
        await h.model.stop()
        await h.model.monitorProcessing(pollInterval: .zero, maxPolls: 1)
        #expect(h.model.state == .error)
        #expect(h.model.errorMessage?.contains("longer than expected") == true)
        await h.model.monitorProcessing(pollInterval: .zero, maxPolls: 1)
        #expect(h.model.state == .error)
        #expect(h.model.errorMessage?.contains("speech_failed") == true)
    }

    @Test func alreadyCompletedUploadLoadsPhoneTranscript() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        await h.model.start()
        let id = try #require(await h.recorder.sessionID)
        let transcriptID = UUID()
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "completed", accepted: [0], expected: 1)),
            (200, transcriptList([transcriptJSON(id: transcriptID, sessionID: id)])),
            (200, transcriptJSON(id: transcriptID, sessionID: id)),
        ])
        await h.model.stop()
        #expect(h.model.state == .complete)
        #expect(h.model.transcriptLibrary.completedTranscriptID == transcriptID)
        #expect(h.model.transcriptLibrary.transcripts[transcriptID] != nil)
    }

    @Test func historySortsFiltersExpiredAndClearsDeletedText() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        let library = h.model.transcriptLibrary
        let older = UUID(), newer = UUID(), expired = UUID(), sessionID = UUID()
        HTTPStub.shared.configure([
            (200, transcriptList([
                transcriptJSON(id: older, sessionID: sessionID, created: "2099-01-01T00:00:00Z"),
                transcriptJSON(id: expired, sessionID: sessionID, expires: "2000-01-01T00:00:00Z"),
                transcriptJSON(id: newer, sessionID: sessionID, created: "2099-01-02T00:00:00Z"),
            ])),
            (200, transcriptJSON(id: newer, sessionID: sessionID)),
            (200, transcriptList([])),
        ])
        await library.refresh()
        #expect(library.history.map(\.id) == [newer, older])
        await library.load(newer)
        #expect(library.transcripts[newer] != nil)
        await library.refresh()
        #expect(library.history.isEmpty)
        #expect(library.transcripts.isEmpty)
        #expect(library.errors[newer]?.contains("no longer available") == true)
    }

    @Test func historyAndTranscriptErrorsCanBeRetried() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        let library = h.model.transcriptLibrary
        let id = UUID(), sessionID = UUID()
        HTTPStub.shared.configure([
            (0, ""), (200, transcriptList([transcriptJSON(id: id, sessionID: sessionID)])),
            (500, "{\"detail\":\"Temporary failure\"}"),
            (200, transcriptJSON(id: id, sessionID: sessionID)),
            (404, "{\"detail\":\"Transcript not found\"}"),
        ])
        await library.refresh()
        #expect(library.historyError != nil)
        #expect(!library.refreshing)
        await library.refresh()
        #expect(library.historyError == nil)
        await library.load(id)
        #expect(library.errors[id] != nil)
        #expect(library.loading.isEmpty)
        await library.load(id)
        #expect(library.errors[id] == nil)
        #expect(library.transcripts[id] != nil)
        await library.load(id)
        #expect(library.transcripts[id] == nil)
        #expect(library.history.isEmpty)
        #expect(library.errors[id]?.contains("no longer available") == true)
    }

    @Test func completedLookupUsesSessionAndRetriesWithoutRepeatingProcessing() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        let library = h.model.transcriptLibrary
        let id = UUID(), sessionID = UUID()
        HTTPStub.shared.configure([
            (0, ""),
            (200, transcriptList([
                transcriptJSON(id: UUID(), sessionID: UUID()),
                transcriptJSON(id: id, sessionID: sessionID),
            ])),
            (200, transcriptJSON(id: id, sessionID: sessionID)),
        ])
        await library.loadCompleted(sessionID: sessionID)
        #expect(library.completionError != nil)
        #expect(!library.loadingCompletion)
        await library.loadCompleted(sessionID: sessionID)
        #expect(library.completionError == nil)
        #expect(library.completedTranscriptID == id)
        #expect(library.transcripts[id] != nil)
        await h.model.signOut()
        #expect(library.history.isEmpty)
        #expect(library.transcripts.isEmpty)
        #expect(library.completedSessionID == nil)
        #expect(library.completedTranscriptID == nil)
        #expect(library.errors.isEmpty)
        HTTPStub.shared.configure([])
        await library.refresh()
        await library.load(id)
        #expect(HTTPStub.shared.recordedRequests.isEmpty)
    }

    @Test func unavailableCompletedTranscriptShowsExplicitMessage() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        HTTPStub.shared.configure([(200, transcriptList([]))])
        await h.model.transcriptLibrary.loadCompleted(sessionID: UUID())
        #expect(h.model.transcriptLibrary.completionError?.contains("no longer available") == true)
        #expect(h.model.transcriptLibrary.completedTranscriptID == nil)
    }

    @Test(arguments: ["history", "detail", "completion"])
    func previousAccountResponseCannotRepopulateTranscripts(operation: String) async throws {
        let credentials = PausedTranscriptCredentials()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let library = TranscriptLibrary(client: client)
        library.setAuthenticated(true)
        let id = UUID(), sessionID = UUID()
        let item = transcriptJSON(id: id, sessionID: sessionID)
        HTTPStub.shared.configure([(200, operation == "detail" ? item : transcriptList([item]))])
        let refresh = Task {
            switch operation {
            case "detail": await library.load(id)
            case "completion": await library.loadCompleted(sessionID: sessionID)
            default: await library.refresh()
            }
        }
        await credentials.waitForRequest()
        library.setAuthenticated(false)
        library.setAuthenticated(true)
        await credentials.resume()
        await refresh.value
        #expect(library.history.isEmpty)
        #expect(library.historyError == nil)
        #expect(!library.refreshing)
        #expect(library.transcripts.isEmpty)
        #expect(library.completedTranscriptID == nil)
        #expect(library.completedSessionID == nil)
        #expect(library.loading.isEmpty)
        #expect(!library.loadingCompletion)
    }

    @Test func refreshRemovingRecordPreventsInFlightDownloadRestoringIt() async throws {
        let credentials = PausedTranscriptCredentials()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let library = TranscriptLibrary(client: client)
        library.setAuthenticated(true)
        let id = UUID()
        let download = Task { await library.load(id) }
        await credentials.waitForRequest()
        HTTPStub.shared.configure([(200, transcriptList([]))])
        await library.refresh()
        HTTPStub.shared.configure([(200, transcriptJSON(id: id, sessionID: UUID()))])
        await credentials.resume()
        await download.value
        #expect(library.transcripts.isEmpty)
        #expect(library.errors[id]?.contains("no longer available") == true)
    }

    @Test(arguments: [204, 404])
    func deletingTranscriptRemovesCloudRecordAndCompletedResult(status: Int) async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        let library = h.model.transcriptLibrary
        let id = UUID(), sessionID = UUID()
        let item = transcriptJSON(id: id, sessionID: sessionID)
        HTTPStub.shared.configure([
            (200, transcriptList([item])), (200, item),
            (status, status == 204 ? "" : "{\"detail\":\"Transcript not found\"}"),
            (200, transcriptList([item])),
        ])
        await library.loadCompleted(sessionID: sessionID)
        await library.delete(id)
        let request = try #require(HTTPStub.shared.recordedRequests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v1/transcripts/\(id)")
        #expect(library.history.isEmpty)
        #expect(library.transcripts[id] == nil)
        #expect(library.completedTranscriptID == nil)
        #expect(library.completedSessionID == nil)
        #expect(library.deleted.contains(id))
        #expect(library.deleting.isEmpty)
        #expect(library.deletionErrors[id] == nil)
        await library.refresh()
        #expect(library.history.isEmpty)
    }

    @Test func failedDeletionKeepsTextAndCanBeRetried() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        await h.model.signIn()
        let library = h.model.transcriptLibrary
        let id = UUID(), sessionID = UUID()
        let item = transcriptJSON(id: id, sessionID: sessionID)
        HTTPStub.shared.configure([
            (200, transcriptList([item])), (200, item),
            (500, "{\"detail\":\"Temporary failure\"}"), (204, ""),
        ])
        await library.loadCompleted(sessionID: sessionID)
        await library.delete(id)
        #expect(library.deletionErrors[id]?.contains("Temporary failure") == true)
        #expect(library.transcripts[id] != nil)
        #expect(library.history.map(\.id) == [id])
        #expect(library.completedTranscriptID == id)
        #expect(!library.deleted.contains(id))
        #expect(library.deleting.isEmpty)
        await library.delete(id)
        #expect(library.deletionErrors[id] == nil)
        #expect(library.deleted.contains(id))
        #expect(library.transcripts.isEmpty)
    }

    @Test func duplicateDeletionAndPreviousAccountCompletionAreIgnored() async throws {
        let credentials = PausedTranscriptCredentials()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let library = TranscriptLibrary(client: client)
        library.setAuthenticated(true)
        let id = UUID()
        HTTPStub.shared.configure([(204, "")])
        let deletion = Task { await library.delete(id) }
        await credentials.waitForRequest()
        #expect(library.deleting.contains(id))
        await library.delete(id)
        #expect(HTTPStub.shared.recordedRequests.isEmpty)
        library.setAuthenticated(false)
        library.setAuthenticated(true)
        await credentials.resume()
        await deletion.value
        #expect(HTTPStub.shared.recordedRequests.count == 1)
        #expect(library.deleting.isEmpty)
        #expect(library.deleted.isEmpty)
        #expect(library.deletionErrors.isEmpty)
    }

    @Test(arguments: ["history", "detail", "completion"])
    func deletionPreventsInFlightResponsesRestoringTranscript(operation: String) async throws {
        let credentials = PausedTranscriptCredentials()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let library = TranscriptLibrary(client: client)
        library.setAuthenticated(true)
        let id = UUID(), sessionID = UUID()
        let lookup = Task {
            switch operation {
            case "detail": await library.load(id)
            case "completion": await library.loadCompleted(sessionID: sessionID)
            default: await library.refresh()
            }
        }
        await credentials.waitForRequest()
        HTTPStub.shared.configure([(204, "")])
        await library.delete(id)
        let item = transcriptJSON(id: id, sessionID: sessionID)
        HTTPStub.shared.configure([(200, operation == "detail" ? item : transcriptList([item]))])
        await credentials.resume()
        await lookup.value
        #expect(library.history.isEmpty)
        #expect(library.transcripts.isEmpty)
        #expect(library.completedTranscriptID == nil)
        #expect(library.deleted.contains(id))
    }

    private func transcriptList(_ items: [String]) -> String {
        "{\"items\":[\(items.joined(separator: ","))]}"
    }

    private func transcriptJSON(
        id: UUID, sessionID: UUID, created: String = "2099-01-01T00:00:00Z",
        expires: String = "2099-01-03T00:00:00Z"
    ) -> String {
        """
        {"id":"\(id)","session_id":"\(sessionID)","created_at":"\(created)","expires_at":"\(expires)",
        "markdown":"# Prompt\\n\\nKeep all lines.\\nSecond line."}
        """
    }
}

private actor PausedTranscriptCredentials: CredentialProvider {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var pauseNext = true

    func accessToken() async throws -> String {
        guard pauseNext else { return "test-token" }
        pauseNext = false
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
        return "previous-account-token"
    }

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
