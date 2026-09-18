import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
import VoicePromptKit
@testable import VoicePromptMac

private actor MacCredentials: CredentialProvider {
    var signedIn = true
    private var pauseNextAccess = false
    private var accessContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func setSignedIn(_ value: Bool) { signedIn = value }
    func pauseAccess() { pauseNextAccess = true }
    func waitForPausedAccess() async {
        if accessContinuation != nil { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
    func resumeAccess() {
        accessContinuation?.resume()
        accessContinuation = nil
    }

    func accessToken() async throws -> String {
        guard signedIn else { throw EntraCredentialProvider.Error.signInRequired }
        if pauseNextAccess {
            pauseNextAccess = false
            await withCheckedContinuation { continuation in
                accessContinuation = continuation
                for waiter in pauseWaiters { waiter.resume() }
                pauseWaiters = []
            }
        }
        return "test-token"
    }
}

@MainActor
private final class MemoryClipboard: ClipboardWriting {
    var values: [String] = []
    func copy(_ text: String) { values.append(text) }
}

@MainActor
private final class MemoryTextPaster: TextPasting {
    var captureCount = 0
    var pasteCount = 0
    var result = TextPasteResult.pasted
    func captureTarget() { captureCount += 1 }
    func pasteFromClipboard() async -> TextPasteResult {
        pasteCount += 1
        return result
    }
}

@MainActor
private final class MemoryNotifications: NotificationSending {
    var count = 0
    func completed() async { count += 1 }
}

private actor TestEvents: CompletionEventStreaming {
    private var onConnected: (@Sendable () async -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var disconnectCount = 0

    func connect(
        onConnected: @escaping @Sendable () async -> Void,
        onCompletion: @escaping @Sendable (UUID) async -> Void,
        onFailure: @escaping @Sendable (String) async -> Void
    ) async {
        self.onConnected = onConnected
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func waitForConnection() async {
        if onConnected != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func reconnect() async { await onConnected?() }
    func disconnect() { disconnectCount += 1; onConnected = nil }
}

private actor TestQuickRecorder: QuickRecording {
    private var callbacks: [@MainActor @Sendable (QuickRecordingEngine.MeterReading) -> Void] = []
    private let failsToStart: Bool
    private let failsToStop: Bool
    private let cancellationError: (any Error)?
    private(set) var cancelCount = 0
    private(set) var recordings: [QuickRecordingEngine.Result] = []

    init(failsToStart: Bool = false, failsToStop: Bool = true, cancellationError: (any Error)? = nil) {
        self.failsToStart = failsToStart
        self.failsToStop = failsToStop
        self.cancellationError = cancellationError
    }

    func start(
        meterChanged: @escaping @MainActor @Sendable (QuickRecordingEngine.MeterReading) -> Void
    ) async throws {
        if failsToStart { throw QuickRecordingEngine.RecordingError.microphoneDenied }
        callbacks.append(meterChanged)
    }

    func emit(duration: TimeInterval, session: Int = 0) async {
        await callbacks[session](.init(level: 0.5, duration: duration))
    }

    func stop() throws -> QuickRecordingEngine.Result {
        if failsToStop { throw QuickRecordingEngine.RecordingError.notRecording }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/QuickRecordingTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID()).m4a")
        try Data("test-audio".utf8).write(to: url)
        let recording = QuickRecordingEngine.Result(
            sessionID: UUID(), fileURL: url, durationMilliseconds: 65_000
        )
        recordings.append(recording)
        return recording
    }

    func cancel() throws {
        cancelCount += 1
        if let cancellationError { throw cancellationError }
    }
}

private final class FailingRecordingCleanup: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Suite(.serialized)
@MainActor
struct CompletionSynchronizerTests {
    private struct Harness {
        let sync: CompletionSynchronizer
        let credentials: MacCredentials
        let events: TestEvents
        let clipboard: MemoryClipboard
        let textPaster: MemoryTextPaster
        let notifications: MemoryNotifications
        let defaults: UserDefaults
        let suite: String
    }

    private func harness(signInFails: Bool = false, pollInterval: Duration = .seconds(60)) -> Harness {
        let suite = "voiceprompt-mac-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = MacCredentials()
        let events = TestEvents()
        let clipboard = MemoryClipboard()
        let textPaster = MemoryTextPaster()
        let notifications = MemoryNotifications()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let sync = CompletionSynchronizer(
            client: client, credentials: credentials, clipboard: clipboard,
            textPaster: textPaster, notifications: notifications,
            defaults: defaults, events: events, pollInterval: pollInterval,
            signIn: {
                if signInFails {
                    throw EntraCredentialProvider.Error.authorization(code: "invalid_client", description: "Check configuration.")
                }
                await credentials.setSignedIn(true)
            },
            signOut: { await credentials.setSignedIn(false) }
        )
        return Harness(sync: sync, credentials: credentials, events: events, clipboard: clipboard,
                       textPaster: textPaster,
                       notifications: notifications, defaults: defaults, suite: suite)
    }

    private func transcript(
        id: UUID = UUID(), markdown: String = "A cloud transcript", refined: Bool? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"id":"\(id)","session_id":"\(UUID())",
        "created_at":"\(formatter.string(from: Date()))",
        "expires_at":"\(formatter.string(from: Date().addingTimeInterval(48 * 60 * 60)))",
        "markdown":"\(markdown)"\(refined.map { ",\"refined\":\($0)" } ?? "")}
        """
    }

    private func decodedTranscript(markdown: String) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            Transcript.self,
            from: Data(transcript(markdown: markdown).utf8)
        )
    }

    @Test func placeholderBackendMigratesButCustomBackendIsPreserved() {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let cloud = "https://api.example.com/"
        h.defaults.set("https://voiceprompt.invalid/", forKey: "backendURL")
        #expect(BackendConfiguration.resolve(bundledURL: cloud, defaults: h.defaults) == cloud)
        #expect(h.defaults.string(forKey: "backendURL") == nil)
        h.defaults.set("http://localhost:8000/", forKey: "backendURL")
        #expect(BackendConfiguration.resolve(bundledURL: cloud, defaults: h.defaults) == "http://localhost:8000/")
    }

    @Test func missingMicrosoftLoginIsNotReportedAsGenericOffline() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        await h.credentials.setSignedIn(false)
        HTTPStub.shared.configure([])
        await h.sync.start()
        #expect(h.sync.status == "Sign in required")
        #expect(h.sync.lastError?.contains("on this Mac") == true)
        #expect(HTTPStub.shared.recordedRequests.isEmpty)
    }

    @Test func loginFailureIsVisible() async {
        let h = harness(signInFails: true)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        await h.credentials.setSignedIn(false)
        await h.sync.signIn()
        #expect(!h.sync.isSignedIn)
        #expect(!h.sync.isSigningIn)
        #expect(h.sync.lastError?.contains("invalid_client") == true)
    }

    @Test func signInFetchesHistoryAndSignOutClearsItAndStopsEvents() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        await h.credentials.setSignedIn(false)
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.signIn()
        await h.events.waitForConnection()
        #expect(h.sync.connected)
        #expect(h.sync.isSignedIn)
        #expect(h.sync.history.count == 1)
        #expect(h.clipboard.values == ["A cloud transcript"])
        await h.sync.signOut()
        #expect(h.sync.history.isEmpty)
        #expect(!h.sync.connected)
        #expect(!h.sync.isSignedIn)
        #expect(await h.events.disconnectCount > 0)
    }

    @Test func repeatedReconciliationDoesNotCopyTwice() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([
            (200, "{\"items\":[\(item)]}"), (200, item),
            (200, "{\"items\":[\(item)]}"), (200, item),
        ])
        await h.sync.reconcile()
        await h.sync.reconcile()
        #expect(h.sync.connected)
        #expect(h.clipboard.values.count == 1)
        #expect(h.notifications.count == 1)
        #expect(h.defaults.stringArray(forKey: "copiedTranscriptIDs")?.count == 1)
    }

    @Test func manuallyCopyingAnOlderRecordCopiesItsFullTextEveryTime() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let olderID = UUID()
        let newerID = UUID()
        let older = transcript(
            id: olderID,
            markdown: "# Older record\\n\\nFirst line\\nSecond line\\nThird line\\nFourth line"
        )
        let newer = transcript(id: newerID, markdown: "Newer record")
        HTTPStub.shared.configure([
            (200, "{\"items\":[\(newer),\(older)]}"), (200, newer), (200, older),
        ])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let olderRecord = try #require(h.sync.history.first { $0.id == olderID })
        let newerRecord = try #require(h.sync.history.first { $0.id == newerID })
        h.sync.copy(newerRecord)
        h.sync.copy(olderRecord)
        h.sync.copy(olderRecord)
        let fullText = "# Older record\n\nFirst line\nSecond line\nThird line\nFourth line"
        #expect(h.clipboard.values == ["Newer record", fullText, fullText])

        HTTPStub.shared.configure([
            (200, "{\"items\":[\(newer),\(older)]}"), (200, newer), (200, older),
        ])
        await h.sync.reconcile()
        #expect(h.clipboard.values == ["Newer record", fullText, fullText])
    }

    @Test func systemClipboardWritesTheCompleteMarkdownToThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("voiceprompt-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous content", forType: .html)
        let text = "# Transcript\n\n- First point\n- Second point\n\nMore than three lines."
        SystemClipboard(pasteboard: pasteboard).copy(text)
        #expect(pasteboard.string(forType: .string) == text)
        #expect(pasteboard.string(forType: .html) == nil)
    }

    @Test func immediateTranscriptPastesByDefault() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let record = try decodedTranscript(markdown: "Paste this text")

        h.sync.prepareImmediateDelivery()
        await h.sync.receiveImmediate(record)

        #expect(h.textPaster.captureCount == 1)
        #expect(h.textPaster.pasteCount == 1)
        #expect(h.clipboard.values == ["Paste this text"])
    }

    @Test func immediateTranscriptCanDisableDirectPaste() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: "pasteQuickTranscription")
        let record = try decodedTranscript(markdown: "Copy only")

        h.sync.prepareImmediateDelivery()
        await h.sync.receiveImmediate(record)

        #expect(h.textPaster.captureCount == 1)
        #expect(h.textPaster.pasteCount == 0)
        #expect(h.clipboard.values == ["Copy only"])
    }

    @Test func immediateTranscriptReportsDirectPasteFailure() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.textPaster.result = .activationFailed
        let record = try decodedTranscript(markdown: "Copied after paste failure")

        h.sync.prepareImmediateDelivery()
        await h.sync.receiveImmediate(record)

        #expect(h.clipboard.values == ["Copied after paste failure"])
        #expect(h.textPaster.pasteCount == 1)
        #expect(h.sync.pasteError == TextPasteResult.activationFailed.failureMessage)

        h.sync.dismissPasteError()
        #expect(h.sync.pasteError == nil)
    }

    @Test func cloudDeletionRemovesOnlySelectedRecordWithoutChangingClipboard() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let selectedID = UUID()
        let selected = transcript(id: selectedID)
        let other = transcript()
        HTTPStub.shared.configure([
            (200, "{\"items\":[\(selected),\(other)]}"), (200, selected), (200, other),
        ])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first { $0.id == selectedID })
        h.sync.copy(record)
        HTTPStub.shared.configure([(204, "")])
        await h.sync.delete(record)
        #expect(h.sync.history.count == 1)
        #expect(h.sync.history.first?.id != selectedID)
        #expect(h.sync.deletionError == nil)
        #expect(h.sync.deletingTranscriptIDs.isEmpty)
        #expect(h.clipboard.values == ["A cloud transcript"])
        #expect(h.defaults.stringArray(forKey: "copiedTranscriptIDs") == [])
        #expect(HTTPStub.shared.recordedRequests.first?.httpMethod == "DELETE")
        #expect(HTTPStub.shared.recordedRequests.first?.url?.lastPathComponent == selectedID.uuidString)
    }

    @Test func failedDeletionPreservesTheRecordAndCanBeRetried() async throws {
        for status in [0, 401, 403, 503] {
            let h = harness()
            defer { h.defaults.removePersistentDomain(forName: h.suite) }
            let item = transcript()
            HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
            await h.sync.reconcile(automaticallyCopyNewest: false)
            let record = try #require(h.sync.history.first)
            HTTPStub.shared.configure([(status, "{\"detail\":\"Deletion unavailable\"}")])
            await h.sync.delete(record)
            #expect(h.sync.history.count == 1)
            #expect(h.sync.deletionError?.contains("Could not delete") == true)
            #expect(h.sync.deletingTranscriptIDs.isEmpty)
            #expect(h.clipboard.values.isEmpty)
            if status == 401 { #expect(!h.sync.isSignedIn) }
            HTTPStub.shared.configure([(204, "")])
            await h.sync.delete(record)
            #expect(h.sync.history.isEmpty)
            #expect(h.sync.deletionError == nil)
        }
    }

    @Test func alreadyDeletedCloudRecordIsRemovedLocally() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first)
        HTTPStub.shared.configure([(404, "{\"detail\":\"Transcript not found\"}")])
        await h.sync.delete(record)
        #expect(h.sync.history.isEmpty)
        #expect(h.sync.deletionError == nil)
    }

    @Test func deletionWaitsForAcknowledgmentAndRejectsDuplicateRequests() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first)
        HTTPStub.shared.configure([(204, "")])
        await h.credentials.pauseAccess()
        let deleting = Task { await h.sync.delete(record) }
        await h.credentials.waitForPausedAccess()
        #expect(h.sync.history.count == 1)
        #expect(h.sync.deletingTranscriptIDs.contains(record.id))
        await h.sync.delete(record)
        #expect(HTTPStub.shared.recordedRequests.isEmpty)
        await h.credentials.resumeAccess()
        await deleting.value
        #expect(h.sync.history.isEmpty)
        #expect(HTTPStub.shared.recordedRequests.count == 1)
    }

    @Test func staleRefreshCannotRestoreADeletedRecord() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first)
        await h.credentials.pauseAccess()
        let refreshing = Task { await h.sync.reconcile() }
        await h.credentials.waitForPausedAccess()
        HTTPStub.shared.configure([(204, "")])
        await h.sync.delete(record)
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.credentials.resumeAccess()
        await refreshing.value
        #expect(h.sync.history.isEmpty)
        #expect(h.clipboard.values.isEmpty)
        #expect(h.sync.connected)
        let requests = HTTPStub.shared.recordedRequests.count
        await h.sync.receiveCompletion(id: record.id)
        #expect(HTTPStub.shared.recordedRequests.count == requests)
    }

    @Test func inFlightCompletionCannotRestoreADeletedRecord() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first)
        await h.credentials.pauseAccess()
        let completion = Task { await h.sync.receiveCompletion(id: record.id) }
        await h.credentials.waitForPausedAccess()
        HTTPStub.shared.configure([(204, "")])
        await h.sync.delete(record)
        HTTPStub.shared.configure([(200, item)])
        await h.credentials.resumeAccess()
        await completion.value
        #expect(h.sync.history.isEmpty)
        #expect(h.clipboard.values.isEmpty)
        #expect(h.notifications.count == 0)
    }

    @Test func deletionFinishingAfterSignOutDoesNotChangeNewAccountState() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.sync.reconcile(automaticallyCopyNewest: false)
        let record = try #require(h.sync.history.first)
        await h.credentials.pauseAccess()
        let deleting = Task { await h.sync.delete(record) }
        await h.credentials.waitForPausedAccess()
        await h.sync.signOut()
        HTTPStub.shared.configure([(503, "{\"detail\":\"Deletion unavailable\"}")])
        await h.credentials.resumeAccess()
        await deleting.value
        #expect(!h.sync.isSignedIn)
        #expect(h.sync.history.isEmpty)
        #expect(h.sync.deletingTranscriptIDs.isEmpty)
        #expect(h.sync.deletionError == nil)
    }

    @Test func remotelyDeletedRecordsDoNotBreakRefreshOrCompletionHandling() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([
            (200, "{\"items\":[\(item)]}"), (404, "{\"detail\":\"Transcript not found\"}"),
        ])
        await h.sync.reconcile()
        #expect(h.sync.history.isEmpty)
        #expect(h.sync.connected)
        #expect(h.sync.lastError == nil)
        HTTPStub.shared.configure([(404, "{\"detail\":\"Transcript not found\"}")])
        await h.sync.receiveCompletion(id: UUID())
        #expect(h.sync.connected)
        #expect(h.sync.lastError == nil)
        #expect(h.clipboard.values.isEmpty)
    }

    @Test func menuPreviewIsSingleLineAndBoundedWithoutChangingTheTranscript() {
        #expect(TranscriptMenuItem.preview("# Heading\n\nFirst\tsecond") == "# Heading First second")
        #expect(TranscriptMenuItem.preview(" \n\t") == "Empty transcript")
        let longText = String(repeating: "a", count: 100)
        #expect(TranscriptMenuItem.preview(longText) == String(repeating: "a", count: 80) + "...")
        #expect(TranscriptMenuItem.preview(String(repeating: "b", count: 80)).count == 80)
    }

    @Test func settingsReopensTheSameFocusableWindow() throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let controller = SettingsWindowController()
        h.defaults.set(false, forKey: "quickTranscriptionShortcutEnabled")
        let shortcut = GlobalShortcutManager(defaults: h.defaults) {}
        controller.show(synchronizer: h.sync, shortcut: shortcut)
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(window.isVisible)
        #expect(window.canBecomeKey)
        #expect(window.title == "VoicePrompt Settings")
        window.close()
        #expect(!window.isVisible)
        controller.show(synchronizer: h.sync, shortcut: shortcut)
        #expect(controller.window === window)
        #expect(window.isVisible)
        #expect(window.canBecomeKey)
    }

    @Test func disabledGlobalShortcutConfigurationPersists() {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: "quickTranscriptionShortcutEnabled")
        let manager = GlobalShortcutManager(defaults: h.defaults) {}
        let configured = GlobalShortcutManager.Shortcut(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey),
            displayName: "⌥⌘R"
        )

        manager.updateShortcut(configured)

        let restored = GlobalShortcutManager(defaults: h.defaults) {}
        #expect(!restored.isEnabled)
        #expect(restored.shortcut == configured)
    }

    @Test func quickTranscriptionRefinementDefaultsOnAndPersistsOff() throws {
        let suite = "quick-refinement-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(QuickTranscriptionDefaults.shouldRefine(in: defaults))
        defaults.set(false, forKey: QuickTranscriptionDefaults.refine)
        #expect(!QuickTranscriptionDefaults.shouldRefine(in: defaults))
    }

    private func transcriptionController(
        _ h: Harness, recorder: TestQuickRecorder, fileManager: FileManager = .default
    ) -> TranscriptionController {
        TranscriptionController(
            client: APIClient(
                baseURL: URL(string: "https://voiceprompt.test/")!,
                credentials: h.credentials, session: HTTPStub.session()
            ),
            synchronizer: h.sync, defaults: h.defaults, recorder: recorder, fileManager: fileManager
        )
    }

    private func waitForTranscription(_ controller: TranscriptionController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while controller.activeTranscriptions > 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.activeTranscriptions == 0)
        #expect(controller.refiningTranscriptions == 0)
        #expect(controller.refinementRequestedTranscriptions == 0)
    }

    @Test func quickRecordingsUseDurableApplicationSupport() {
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VoicePrompt/QuickRecordings", directoryHint: .isDirectory)
        #expect(TranscriptionController.recordingDirectory == expected)
    }

    @Test(arguments: [500, 0])
    func failedTranscriptionKeepsAudioAfterDismissalAnotherRecordingAndRestart(status: Int) async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let response = (status, "{\"detail\":\"PropertyValueTooLarge\"}")
        HTTPStub.shared.configure([response, response])
        let recorder = TestQuickRecorder(failsToStop: false)
        var controller: TranscriptionController? = transcriptionController(h, recorder: recorder)
        await controller?.startListening()
        await controller?.stopListening()
        let recording = try #require(await recorder.recordings.first)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        try await waitForTranscription(try #require(controller))

        #expect(try Data(contentsOf: recording.fileURL) == Data("test-audio".utf8))
        #expect(controller?.lastError?.contains("Audio saved at: \(recording.fileURL.path)") == true)
        if status == 500 {
            #expect(controller?.lastError?.contains("PropertyValueTooLarge") == true)
        }
        #expect(h.sync.history.isEmpty)
        #expect(h.clipboard.values.isEmpty)
        #expect(h.textPaster.pasteCount == 0)
        #expect(h.notifications.count == 0)

        controller?.dismissError()
        #expect(controller?.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
        h.defaults.set(false, forKey: QuickTranscriptionDefaults.refine)
        HTTPStub.shared.configure([(201, transcript(markdown: "The next recording"))])
        await controller?.startListening()
        #expect(controller?.captureState == .listening)
        await controller?.stopListening()
        try await waitForTranscription(try #require(controller))
        let nextRecording = try #require(await recorder.recordings.last)
        #expect(nextRecording.fileURL != recording.fileURL)
        #expect(!FileManager.default.fileExists(atPath: nextRecording.fileURL.path))
        #expect(h.clipboard.values == ["The next recording"])
        #expect(controller?.lastError == nil)

        controller = nil
        let restarted = transcriptionController(h, recorder: TestQuickRecorder())
        await restarted.startListening()
        await restarted.cancelListening()
        #expect(try Data(contentsOf: recording.fileURL) == Data("test-audio".utf8))
    }

    @Test(arguments: [false, true])
    func successfulTranscriptionDeletesOnlyItsOwnAudio(refine: Bool) async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(refine, forKey: QuickTranscriptionDefaults.refine)
        let response = (201, transcript(markdown: "Completed recording", refined: refine ? true : nil))
        HTTPStub.shared.configure([response, response])
        let recorder = TestQuickRecorder(failsToStop: false)
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await controller.stopListening()
        let recording = try #require(await recorder.recordings.first)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        try await waitForTranscription(controller)

        #expect(!FileManager.default.fileExists(atPath: recording.fileURL.path))
        #expect(controller.lastError == nil)
        #expect(controller.captureState == .idle)
        #expect(h.clipboard.values == ["Completed recording"])
        #expect(h.textPaster.pasteCount == 1)
        #expect(h.notifications.count == 1)
    }

    @Test(arguments: [Bool?.none, Bool?.some(false)])
    func missingRefinementConfirmationRetainsAudioWithoutDeliveringSuccess(refined: Bool?) async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let response = (201, transcript(refined: refined))
        HTTPStub.shared.configure([response, response])
        let recorder = TestQuickRecorder(failsToStop: false)
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await controller.stopListening()
        let recording = try #require(await recorder.recordings.first)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        try await waitForTranscription(controller)

        #expect(try Data(contentsOf: recording.fileURL) == Data("test-audio".utf8))
        #expect(controller.lastError?.contains("did not confirm the requested refinement") == true)
        #expect(controller.lastError?.contains("Audio saved at: \(recording.fileURL.path)") == true)
        #expect(h.sync.history.isEmpty)
        #expect(h.clipboard.values.isEmpty)
        #expect(h.textPaster.pasteCount == 0)
        #expect(h.notifications.count == 0)
    }

    @Test func cleanupFailureSurfacesTheSavedAudioPathAfterSuccessfulDelivery() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let response = (201, transcript(refined: true))
        HTTPStub.shared.configure([response, response])
        let recorder = TestQuickRecorder(failsToStop: false)
        let controller = transcriptionController(h, recorder: recorder, fileManager: FailingRecordingCleanup())
        await controller.startListening()
        await controller.stopListening()
        let recording = try #require(await recorder.recordings.first)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        try await waitForTranscription(controller)

        #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
        #expect(controller.lastError?.contains("could not be deleted") == true)
        #expect(controller.lastError?.contains("Audio saved at: \(recording.fileURL.path)") == true)
        #expect(h.clipboard.values == ["A cloud transcript"])
        #expect(h.notifications.count == 1)
        controller.dismissError()
        await controller.startListening()
        await controller.cancelListening()
        #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
    }

    @Test func earlierTranscriptionFailureDoesNotInterruptANewCapture() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: QuickTranscriptionDefaults.refine)
        HTTPStub.shared.configure([(500, "{\"detail\":\"PropertyValueTooLarge\"}")])
        let recorder = TestQuickRecorder(failsToStop: false)
        let controller = transcriptionController(h, recorder: recorder)
        await h.credentials.pauseAccess()
        await controller.startListening()
        await controller.stopListening()
        let recording = try #require(await recorder.recordings.first)
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        await h.credentials.waitForPausedAccess()
        await controller.startListening()
        await recorder.emit(duration: 12, session: 1)
        #expect(controller.activeTranscriptions == 1)
        #expect(controller.captureState == .listening)
        await h.credentials.resumeAccess()
        try await waitForTranscription(controller)

        #expect(controller.captureState == .listening)
        #expect(controller.recordingTime == "00:12")
        #expect(controller.lastError?.contains(recording.fileURL.path) == true)
        await controller.cancelListening()
        #expect(controller.captureState == .idle)
        #expect(controller.recordingTime == "00:00")
        #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
    }

    @Test func cancellationCleanupFailureIsVisibleAndDoesNotBlockAnotherCapture() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let fileURL = TranscriptionController.recordingDirectory.appending(path: "\(UUID()).m4a")
        let recorder = TestQuickRecorder(cancellationError: QuickRecordingEngine.RecordingError.cleanupFailed(
            fileURL: fileURL, underlying: CocoaError(.fileWriteNoPermission)
        ))
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await recorder.emit(duration: 12)
        await controller.cancelListening()

        #expect(controller.captureState == .idle)
        #expect(controller.recordingTime == "00:00")
        #expect(controller.lastError?.contains("could not be deleted") == true)
        #expect(controller.lastError?.contains("Audio saved at: \(fileURL.path)") == true)
        await controller.startListening()
        #expect(controller.captureState == .listening)
        await controller.cancelListening()
    }

    @Test func recordingTimerUsesAudioDurationAndDoesNotResetWhenResizing() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let recorder = TestQuickRecorder()
        let controller = transcriptionController(h, recorder: recorder)
        let presentation = TranscriptionOverlayPresentation()
        #expect(controller.recordingTime == "00:00")
        await controller.startListening()
        presentation.update(captureState: controller.captureState, hasError: false)
        for (duration, expected) in [
            (0.0, "00:00"), (0.99, "00:00"), (1.0, "00:01"), (59.99, "00:59"),
            (60.0, "01:00"), (65.0, "01:05"), (3599.0, "59:59"), (3600.0, "60:00"),
            (6000.0, "100:00"),
        ] {
            await recorder.emit(duration: duration)
            presentation.setMinimized(false)
            #expect(controller.recordingTime == expected)
            presentation.setMinimized(true)
            #expect(controller.recordingDuration == duration)
            #expect(controller.recordingTime == expected)
        }
        await controller.cancelListening()
        #expect(controller.recordingTime == "00:00")
        #expect(controller.captureState == .idle)
    }

    @Test func cancelledAndPreviousRecordingsCannotUpdateTheNewTimer() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let recorder = TestQuickRecorder()
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await recorder.emit(duration: 10)
        await controller.cancelListening()
        await recorder.emit(duration: 20)
        #expect(controller.recordingTime == "00:00")
        await controller.startListening()
        await recorder.emit(duration: 30, session: 0)
        #expect(controller.recordingTime == "00:00")
        await recorder.emit(duration: 2, session: 1)
        #expect(controller.recordingTime == "00:02")
        await controller.cancelListening()
        #expect(await recorder.cancelCount == 2)
    }

    @Test func recordingFailuresLeaveNoRunningTimer() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let denied = transcriptionController(h, recorder: TestQuickRecorder(failsToStart: true))
        await denied.startListening()
        #expect(denied.captureState == .idle)
        #expect(denied.recordingTime == "00:00")
        #expect(denied.lastError != nil)

        let recorder = TestQuickRecorder()
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await recorder.emit(duration: 65)
        await controller.stopListening()
        await recorder.emit(duration: 66)
        #expect(controller.captureState == .idle)
        #expect(controller.recordingTime == "00:00")
        #expect(controller.lastError != nil)
    }

    @Test func stopResetsTimerAndStillDeliversTheTranscription() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: QuickTranscriptionDefaults.refine)
        HTTPStub.shared.configure([(201, transcript(markdown: "Recorded from the HUD"))])
        let recorder = TestQuickRecorder(failsToStop: false)
        let controller = transcriptionController(h, recorder: recorder)
        await controller.startListening()
        await recorder.emit(duration: 65)
        await controller.stopListening()
        #expect(controller.recordingTime == "00:00")
        #expect(controller.captureState == .idle)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while controller.activeTranscriptions > 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.activeTranscriptions == 0)
        #expect(controller.lastError == nil)
        #expect(h.clipboard.values == ["Recorded from the HUD"])
        await recorder.emit(duration: 66)
        #expect(controller.recordingTime == "00:00")
    }

    @Test func hudRendersAtItsCompactAndOriginalExpandedSizes() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: "quickTranscriptionShortcutEnabled")
        let recorder = TestQuickRecorder()
        let controller = transcriptionController(h, recorder: recorder)
        let shortcut = GlobalShortcutManager(defaults: h.defaults) {}
        let presentation = TranscriptionOverlayPresentation()
        await controller.startListening()
        await recorder.emit(duration: 65)
        presentation.update(captureState: controller.captureState, hasError: false)
        for minimized in [true, false] {
            presentation.setMinimized(minimized)
            for colorScheme in [ColorScheme.light, .dark] {
                let view = TranscriptionOverlay(
                    controller: controller, shortcut: shortcut, presentation: presentation
                )
                .environment(\.colorScheme, colorScheme)
                let expected = minimized
                    ? TranscriptionOverlayLayout.minimizedSize : TranscriptionOverlayLayout.expandedSize
                let hostingView = NSHostingView(rootView: view)
                hostingView.appearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: expected),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.contentView = hostingView
                hostingView.layoutSubtreeIfNeeded()
                #expect(hostingView.fittingSize == expected)
                let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(
                    data,
                    named: "hud-\(minimized ? "minimized" : "expanded")-\(colorScheme == .light ? "light" : "dark").png"
                )
            }
        }
        await controller.cancelListening()
    }

    @Test func recoveryErrorHUDKeepsCaptureControlsAndRestoresItsOriginalSizeAfterDismissal() async throws {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        h.defaults.set(false, forKey: "quickTranscriptionShortcutEnabled")
        let recorder = TestQuickRecorder()
        let controller = transcriptionController(h, recorder: recorder)
        let shortcut = GlobalShortcutManager(defaults: h.defaults) {}
        let presentation = TranscriptionOverlayPresentation()
        let path = TranscriptionController.recordingDirectory.appending(path: "\(UUID()).m4a")
        let error = QuickRecordingEngine.RecordingError.cleanupFailed(
            fileURL: path, underlying: CocoaError(.fileWriteNoPermission)
        )
        for recording in [false, true] {
            if recording {
                await controller.startListening()
                await recorder.emit(duration: 65)
                presentation.update(captureState: controller.captureState, hasError: false)
                #expect(presentation.isMinimized)
            }
            controller.show(error)
            presentation.update(captureState: controller.captureState, hasError: true)
            #expect(!presentation.isMinimized)
            for colorScheme in [ColorScheme.light, .dark] {
                let view = TranscriptionOverlay(
                    controller: controller, shortcut: shortcut, presentation: presentation
                )
                .environment(\.colorScheme, colorScheme)
                let hostingView = NSHostingView(rootView: view)
                hostingView.appearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: TranscriptionOverlayLayout.errorSize),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.contentView = hostingView
                hostingView.layoutSubtreeIfNeeded()
                #expect(hostingView.fittingSize == TranscriptionOverlayLayout.errorSize)
                let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                Attachment.record(data, named: "hud-error-\(recording ? "listening" : "idle")-\(colorScheme).png")

                controller.dismissError()
                presentation.update(captureState: controller.captureState, hasError: false)
                window.setContentSize(TranscriptionOverlayLayout.expandedSize)
                hostingView.layoutSubtreeIfNeeded()
                #expect(hostingView.fittingSize == TranscriptionOverlayLayout.expandedSize)
                controller.show(error)
                presentation.update(captureState: controller.captureState, hasError: true)
            }
            if recording {
                #expect(controller.captureState == .listening)
                #expect(controller.recordingTime == "01:05")
                await controller.cancelListening()
            }
            controller.dismissError()
        }
    }

    @Test func failedTranscriptDownloadPreservesHistoryAndSurfacesFailure() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([
            (200, "{\"items\":[\(item)]}"), (200, item),
            (200, "{\"items\":[\(item)]}"), (503, "{\"detail\":\"Storage temporarily unavailable\"}"),
        ])
        await h.sync.reconcile()
        await h.sync.reconcile()
        #expect(!h.sync.connected)
        #expect(h.sync.isSignedIn)
        #expect(h.sync.history.count == 1)
        #expect(h.sync.lastError?.contains("Storage temporarily unavailable") == true)
    }

    @Test func reconnectFetchesTranscriptsMissedWhileDisconnected() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        HTTPStub.shared.configure([(200, "{\"items\":[]}")])
        await h.sync.start()
        await h.events.waitForConnection()
        let item = transcript()
        HTTPStub.shared.configure([(200, "{\"items\":[\(item)]}"), (200, item)])
        await h.events.reconnect()
        #expect(h.sync.liveConnected)
        #expect(h.sync.history.count == 1)
        #expect(h.clipboard.values.count == 1)
        await h.sync.stopMonitoring()
    }

    @Test func pollingRetrievesTranscriptsWithoutAnEvent() async throws {
        let h = harness(pollInterval: .milliseconds(10))
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let item = transcript()
        HTTPStub.shared.configure([
            (200, "{\"items\":[]}"), (200, "{\"items\":[\(item)]}"), (200, item),
        ])
        await h.sync.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while h.sync.history.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await h.sync.stopMonitoring()
        #expect(h.sync.history.count == 1)
        #expect(h.clipboard.values.count == 1)
    }

    @Test func simultaneousCompletionEventsCopyOnlyOnce() async {
        let h = harness()
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        HTTPStub.shared.configure([(200, "{\"items\":[]}")])
        await h.sync.reconcile()
        let id = UUID()
        let item = transcript(id: id)
        HTTPStub.shared.configure([(200, item), (200, item)])
        async let first: Void = h.sync.receiveCompletion(id: id)
        async let second: Void = h.sync.receiveCompletion(id: id)
        _ = await (first, second)
        #expect(h.clipboard.values.count == 1)
        #expect(h.notifications.count == 1)
    }
}
