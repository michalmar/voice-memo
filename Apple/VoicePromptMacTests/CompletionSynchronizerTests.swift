import AppKit
import Foundation
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

@Suite(.serialized)
@MainActor
struct CompletionSynchronizerTests {
    private struct Harness {
        let sync: CompletionSynchronizer
        let credentials: MacCredentials
        let events: TestEvents
        let clipboard: MemoryClipboard
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
        let notifications = MemoryNotifications()
        let client = APIClient(
            baseURL: URL(string: "https://voiceprompt.test/")!, credentials: credentials, session: HTTPStub.session()
        )
        let sync = CompletionSynchronizer(
            client: client, credentials: credentials, clipboard: clipboard, notifications: notifications,
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
                       notifications: notifications, defaults: defaults, suite: suite)
    }

    private func transcript(id: UUID = UUID(), markdown: String = "A cloud transcript") -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"id":"\(id)","session_id":"\(UUID())",
        "created_at":"\(formatter.string(from: Date()))",
        "expires_at":"\(formatter.string(from: Date().addingTimeInterval(48 * 60 * 60)))",
        "markdown":"\(markdown)"}
        """
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
        controller.show(synchronizer: h.sync)
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(window.isVisible)
        #expect(window.canBecomeKey)
        #expect(window.title == "VoicePrompt Settings")
        window.close()
        #expect(!window.isVisible)
        controller.show(synchronizer: h.sync)
        #expect(controller.window === window)
        #expect(window.isVisible)
        #expect(window.canBecomeKey)
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
