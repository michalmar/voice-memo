import AuthenticationServices
import Foundation
import OSLog
import SwiftUI
import UIKit
import VoicePromptKit

@MainActor
final class RecordingViewModel: ObservableObject {
    enum State: String {
        case ready = "Ready"
        case starting = "Starting microphone"
        case recording = "Recording"
        case stopping = "Saving recording"
        case uploading = "Uploading"
        case processing = "Processing"
        case complete = "Complete"
        case offline = "Saved on this device"
        case error = "Needs attention"
    }

    enum AuthenticationState: String {
        case checking = "Checking Microsoft sign-in"
        case signedOut = "Not signed in"
        case signingIn = "Signing in with Microsoft"
        case signedIn = "Signed in with Microsoft"
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var authenticationState: AuthenticationState = .checking {
        didSet { transcriptLibrary.setAuthenticated(authenticationState == .signedIn) }
    }
    @Published private(set) var authenticationMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var progressMessage: String?
    @Published private(set) var pendingRecordingCount = 0
    @Published private(set) var processingSessionID: UUID?
    @Published private(set) var backendReady = false
    @Published private(set) var checkingBackend = true
    @Published private var retryingUploads = false
    let transcriptLibrary: TranscriptLibrary
    private let recorder: any AudioRecording
    private let client: APIClient
    private let queue: UploadQueue
    private let credentials: any CredentialProvider
    private let signInAction: @MainActor () async throws -> Void
    private let signOutAction: @MainActor () async -> Void
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.ios", category: "Recording")
    private var sessionID: UUID?
    private var stopRequested = false
    private var restoringAuthentication = false
    private var signingOut = false
    private var unsavedChunks: [ChunkMetadata] = []

    var isBusy: Bool { retryingUploads || [.starting, .stopping, .uploading].contains(state) }
    var canStartRecording: Bool { !isBusy && state != .recording && unsavedChunks.isEmpty }
    var canRetryUploads: Bool { pendingRecordingCount > 0 || !unsavedChunks.isEmpty }

    init(
        recorder: any AudioRecording, client: APIClient, queue: UploadQueue,
        credentials: any CredentialProvider,
        signIn: @escaping @MainActor () async throws -> Void,
        signOut: @escaping @MainActor () async -> Void
    ) {
        self.recorder = recorder
        self.client = client
        transcriptLibrary = TranscriptLibrary(client: client)
        self.queue = queue
        self.credentials = credentials
        signInAction = signIn
        signOutAction = signOut
    }

    func prepare() async {
        pendingRecordingCount = await queue.pendingRecordings().count
        async let warming: Void = warmBackend()
        await restoreAuthentication()
        await warming
    }

    func warmBackend() async {
        checkingBackend = true
        backendReady = await client.warm()
        checkingBackend = false
    }

    func restoreAuthentication() async {
        guard authenticationState != .signingIn, !restoringAuthentication, !signingOut else { return }
        restoringAuthentication = true
        defer { restoringAuthentication = false }
        do {
            _ = try await credentials.accessToken()
            authenticationState = .signedIn
            authenticationMessage = nil
        } catch EntraCredentialProvider.Error.signInRequired {
            authenticationState = .signedOut
        } catch {
            authenticationState = .signedOut
            authenticationMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard authenticationState != .signingIn, !restoringAuthentication, !signingOut else { return }
        authenticationState = .signingIn
        authenticationMessage = nil
        do {
            try await signInAction()
            _ = try await credentials.accessToken()
            authenticationState = .signedIn
        } catch {
            authenticationState = .signedOut
            if let failure = error as? ASWebAuthenticationSessionError, failure.code == .canceledLogin {
                authenticationMessage = "Sign-in was canceled. Your recordings remain on this device."
            } else {
                authenticationMessage = error.localizedDescription
                logger.error("Sign-in failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func signOut() async {
        guard !isBusy, state != .recording, !restoringAuthentication, !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        authenticationState = .signedOut
        authenticationMessage = nil
        processingSessionID = nil
        progressMessage = nil
        state = .ready
        await signOutAction()
    }

    func start() async {
        guard canStartRecording else { return }
        let id = UUID()
        sessionID = id
        processingSessionID = nil
        transcriptLibrary.clearCompleted()
        stopRequested = false
        state = .starting
        errorMessage = nil
        progressMessage = nil
        do {
            try await recorder.start(sessionID: id)
            state = .recording
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if stopRequested { await stop() }
        } catch {
            report(error)
        }
    }

    func stop() async {
        if state == .starting {
            stopRequested = true
            return
        }
        guard state == .recording, let id = sessionID else { return }
        state = .stopping
        do {
            unsavedChunks = try await recorder.stop()
            try await saveRecording()
            await upload(sessionID: id)
        } catch {
            report(error)
        }
    }

    func retryUploads() async {
        guard !isBusy, state != .recording, canRetryUploads else { return }
        retryingUploads = true
        defer { retryingUploads = false }
        state = .uploading
        processingSessionID = nil
        do {
            if !unsavedChunks.isEmpty { try await saveRecording() }
            let recordings = await queue.pendingRecordings()
            for recording in recordings {
                await upload(sessionID: recording.id)
                if errorMessage != nil { return }
            }
        } catch {
            report(error)
        }
    }

    func monitorProcessing(
        pollInterval: Duration = .seconds(2), maxPolls: Int = 90, timeout: Duration = .seconds(180)
    ) async {
        guard let id = processingSessionID else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        state = .processing
        errorMessage = nil
        do {
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                if clock.now >= deadline { break }
                let session = try await client.recordingSession(id: id)
                guard processingSessionID == id else { return }
                if session.status == .completed {
                    await transcriptLibrary.loadCompleted(sessionID: id)
                    guard processingSessionID == id else { return }
                    state = .complete
                    progressMessage = "Transcription complete."
                    errorMessage = nil
                    processingSessionID = nil
                    return
                }
                if session.status == .failed {
                    state = .error
                    errorMessage = "Cloud processing failed (\(session.errorCode ?? "unknown error"))."
                    return
                }
                state = .processing
                progressMessage = session.status == .refining ? "Polishing transcript..." : "Transcribing audio..."
                try await Task.sleep(for: pollInterval)
            }
            state = .error
            errorMessage = "The recording was uploaded, but cloud processing is taking longer than expected. Check its status again."
        } catch is CancellationError {
            return
        } catch {
            guard processingSessionID == id else { return }
            report(error)
        }
    }

    func toggle() async {
        state == .recording ? await stop() : await start()
    }

    private func saveRecording() async throws {
        try await queue.enqueueRecording(unsavedChunks)
        unsavedChunks = []
        pendingRecordingCount = await queue.pendingRecordings().count
    }

    private func upload(sessionID: UUID) async {
        processingSessionID = nil
        state = .uploading
        errorMessage = nil
        progressMessage = "Connecting to the cloud..."
        do {
            let session = try await queue.submit(sessionID: sessionID, using: client) { [weak self] uploaded, total in
                await self?.showUploadProgress(uploaded: uploaded, total: total)
            }
            backendReady = true
            authenticationState = .signedIn
            pendingRecordingCount = await queue.pendingRecordings().count
            state = session.status == .completed ? .complete : .processing
            progressMessage = session.status == .completed ? "Transcription complete." : "Uploaded. Waiting for transcription..."
            processingSessionID = session.status == .completed ? nil : sessionID
            if session.status == .completed {
                await transcriptLibrary.loadCompleted(sessionID: sessionID)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            report(error)
        }
    }

    private func showUploadProgress(uploaded: Int, total: Int) {
        progressMessage = uploaded == total ? "Finishing upload..." : "Uploading segment \(uploaded + 1) of \(total)..."
    }

    private func report(_ error: any Error) {
        progressMessage = nil
        errorMessage = error.localizedDescription
        if case EntraCredentialProvider.Error.signInRequired = error {
            authenticationState = .signedOut
        } else if case APIClient.Error.server(status: 401, detail: _) = error {
            authenticationState = .signedOut
        }
        if error is URLError {
            state = .offline
            backendReady = false
        } else {
            state = .error
        }
        logger.error("Recording operation failed: \(error.localizedDescription, privacy: .private)")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
