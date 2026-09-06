import AppKit
import AuthenticationServices
import Foundation
import OSLog
import UserNotifications
import VoicePromptKit

@MainActor protocol ClipboardWriting { func copy(_ text: String) }
@MainActor protocol NotificationSending { func completed() async }

struct SystemClipboard: ClipboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct SystemNotifications: NotificationSending {
    func completed() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "VoicePrompt"
        content.body = "A transcription is ready and has been copied."
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor
final class CompletionSynchronizer: ObservableObject {
    @Published private(set) var history: [Transcript] = []
    @Published private(set) var connected = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var liveConnected = false
    @Published private(set) var liveError: String?
    private let client: APIClient
    private let credentials: any CredentialProvider
    private let events: any CompletionEventStreaming
    private let clipboard: any ClipboardWriting
    private let notifications: any NotificationSending
    private let defaults: UserDefaults
    private let signInAction: @MainActor () async throws -> Void
    private let signOutAction: @MainActor () async -> Void
    private let pollInterval: Duration
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.macos", category: "Sync")
    private var copied: Set<UUID>
    private var generation = 0
    private var starting = false
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    var status: String {
        if isSigningIn { return "Signing in with Microsoft" }
        if isSyncing { return "Syncing" }
        if connected { return "Connected" }
        return isSignedIn ? "Offline" : "Sign in required"
    }

    init(
        client: APIClient, credentials: any CredentialProvider,
        clipboard: any ClipboardWriting, notifications: any NotificationSending,
        defaults: UserDefaults = .standard, events: (any CompletionEventStreaming)? = nil,
        pollInterval: Duration = .seconds(60),
        signIn: @escaping @MainActor () async throws -> Void,
        signOut: @escaping @MainActor () async -> Void
    ) {
        self.client = client
        self.credentials = credentials
        self.events = events ?? EventClient(api: client)
        self.clipboard = clipboard
        self.notifications = notifications
        self.defaults = defaults
        self.pollInterval = pollInterval
        signInAction = signIn
        signOutAction = signOut
        copied = Set(defaults.stringArray(forKey: "copiedTranscriptIDs")?.compactMap(UUID.init) ?? [])
    }

    deinit {
        pollTask?.cancel()
        eventTask?.cancel()
    }

    func start() async {
        guard !starting, pollTask == nil else { return }
        starting = true
        defer { starting = false }
        let current = generation
        await reconcile()
        guard generation == current, isSignedIn else { return }
        let pollInterval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) }
                catch { return }
                guard let self, self.isSignedIn else { return }
                await self.reconcile()
            }
        }
        let events = events
        eventTask = Task { [weak self] in
            await events.connect(
                onConnected: { [weak self] in
                    await self?.eventConnected(generation: current)
                },
                onCompletion: { [weak self] id in
                    await self?.eventCompleted(id: id, generation: current)
                },
                onFailure: { [weak self] message in
                    await self?.eventFailed(message, generation: current)
                }
            )
        }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        do {
            try await signInAction()
            await stopMonitoring()
            isSigningIn = false
            await start()
        } catch {
            isSigningIn = false
            if let failure = error as? ASWebAuthenticationSessionError, failure.code == .canceledLogin {
                lastError = "Microsoft sign-in was canceled."
            } else {
                report(error)
            }
        }
    }

    func signOut() async {
        generation += 1
        await stopMonitoring()
        await signOutAction()
        history = []
        connected = false
        isSignedIn = false
        lastError = nil
    }

    func stopMonitoring() async {
        pollTask?.cancel()
        eventTask?.cancel()
        pollTask = nil
        eventTask = nil
        await events.disconnect()
        liveConnected = false
        liveError = nil
    }

    func reconcile(automaticallyCopyNewest: Bool = true) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let current = generation
        do {
            _ = try await credentials.accessToken()
            guard generation == current else { return }
            isSignedIn = true
            let summaries = try await client.transcripts()
            let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
            let fetched: [Transcript] = try await withThrowingTaskGroup(of: Transcript.self) { group in
                for item in summaries where item.createdAt >= cutoff {
                    group.addTask { try await self.client.transcript(id: item.id) }
                }
                return try await group.reduce(into: [Transcript]()) { $0.append($1) }
            }
            guard generation == current, !Task.isCancelled else { return }
            history = fetched.sorted { $0.createdAt > $1.createdAt }
            copied = copied.intersection(Set(history.map(\.id)))
            connected = true
            lastError = nil
            if automaticallyCopyNewest, let newest = history.first, !copied.contains(newest.id) {
                copy(newest)
                await notifications.completed()
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            report(error)
        }
    }

    func copy(_ transcript: Transcript) {
        clipboard.copy(transcript.markdown)
        copied.insert(transcript.id)
        defaults.set(copied.map(\.uuidString), forKey: "copiedTranscriptIDs")
    }

    func receiveCompletion(id: UUID) async {
        guard isSignedIn, !copied.contains(id) else { return }
        let current = generation
        do {
            let transcript = try await client.transcript(id: id)
            guard generation == current, !copied.contains(id), !Task.isCancelled else { return }
            history.removeAll { $0.id == id }
            history.append(transcript)
            history.sort { $0.createdAt > $1.createdAt }
            connected = true
            lastError = nil
            copy(transcript)
            await notifications.completed()
        } catch is CancellationError {
            return
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            report(error)
        }
    }

    private func eventConnected(generation: Int) async {
        guard self.generation == generation else { return }
        liveConnected = true
        liveError = nil
        // A reconnect cannot recover messages missed by a plain WebSocket.
        await reconcile()
    }

    private func eventCompleted(id: UUID, generation: Int) async {
        guard self.generation == generation else { return }
        await receiveCompletion(id: id)
    }

    private func eventFailed(_ message: String, generation: Int) {
        guard self.generation == generation else { return }
        liveConnected = false
        liveError = message
        logger.error("Live updates unavailable: \(message, privacy: .private)")
    }

    private func report(_ error: any Error) {
        connected = false
        if case EntraCredentialProvider.Error.signInRequired = error {
            isSignedIn = false
            lastError = "Sign in with Microsoft on this Mac to retrieve your cloud transcripts."
        } else if case APIClient.Error.server(status: 401, detail: _) = error {
            isSignedIn = false
            lastError = error.localizedDescription
        } else {
            lastError = error.localizedDescription
        }
        logger.error("Transcript sync failed: \(error.localizedDescription, privacy: .private)")
    }
}
