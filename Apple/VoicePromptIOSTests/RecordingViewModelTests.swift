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
        HTTPStub.shared.configure([
            (201, HTTPStub.recording(id: id)), (200, "{}"),
            (202, HTTPStub.recording(id: id, status: "transcribing", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "refining", accepted: [0], expected: 1)),
            (200, HTTPStub.recording(id: id, status: "completed", accepted: [0], expected: 1)),
        ])
        await h.model.stop()
        #expect(h.model.state == .processing)
        await h.model.monitorProcessing(pollInterval: .zero, maxPolls: 2)
        #expect(h.model.state == .complete)
        #expect(h.model.processingSessionID == nil)
        #expect(h.model.errorMessage == nil)
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
}
