import Foundation
import OSLog
import VoicePromptKit

enum QuickTranscriptionDefaults {
    static let refine = "refineQuickTranscription"
    static let refinementInstructions = "quickTranscriptionRefinementInstructions"
    static let maximumRefinementInstructionLength = 4_000

    static func shouldRefine(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: refine) == nil || defaults.bool(forKey: refine)
    }
}

@MainActor
final class TranscriptionController: ObservableObject {
    enum CaptureState: Equatable {
        case idle
        case listening
        case starting
    }

    enum ProcessingPhase: Equatable {
        case transcribing
        case refining
    }

    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var level = 0.04
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var activeTranscriptions = 0
    @Published private(set) var lastError: String?
    @Published private var processingPhases: [UUID: ProcessingPhase] = [:]
    @Published private var refinementRequests: Set<UUID> = []

    private let recorder: any QuickRecording
    private var captureID: UUID?
    private let client: APIClient
    private let synchronizer: CompletionSynchronizer
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.macos", category: "QuickTranscription")

    static var recordingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VoicePrompt/QuickRecordings", directoryHint: .isDirectory)
    }

    var isVisible: Bool {
        captureState != .idle || activeTranscriptions > 0 || lastError != nil
    }

    var recordingTime: String {
        Duration.seconds(Int(recordingDuration))
            .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    var displayedProcessingPhase: ProcessingPhase {
        refiningTranscriptions > 0 ? .refining : .transcribing
    }

    var refiningTranscriptions: Int {
        processingPhases.values.count { $0 == .refining }
    }

    var refinementRequestedTranscriptions: Int {
        refinementRequests.count
    }

    init(
        client: APIClient,
        synchronizer: CompletionSynchronizer,
        defaults: UserDefaults = .standard,
        recorder: (any QuickRecording)? = nil,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.synchronizer = synchronizer
        self.defaults = defaults
        self.fileManager = fileManager
        self.recorder = recorder ?? QuickRecordingEngine(directory: Self.recordingDirectory)
    }

    func startListening() async {
        guard captureState == .idle else { return }
        synchronizer.prepareImmediateDelivery()
        let captureID = UUID()
        self.captureID = captureID
        recordingDuration = 0
        level = 0.04
        captureState = .starting
        lastError = nil
        do {
            try await recorder.start { [weak self] reading in
                guard let self, self.captureID == captureID, self.captureState == .listening else { return }
                self.level = reading.level
                self.recordingDuration = reading.duration
            }
            guard self.captureID == captureID else { return }
            captureState = .listening
        } catch {
            guard self.captureID == captureID else { return }
            self.captureID = nil
            captureState = .idle
            report(error)
        }
    }

    func stopListening() async {
        guard captureState == .listening else { return }
        do {
            let recording = try await recorder.stop()
            captureID = nil
            captureState = .idle
            level = 0.04
            recordingDuration = 0
            let refine = QuickTranscriptionDefaults.shouldRefine(in: defaults)
            let refinementInstructions = refine
                ? defaults.string(forKey: QuickTranscriptionDefaults.refinementInstructions) ?? ""
                : ""
            activeTranscriptions += 1
            processingPhases[recording.sessionID] = .transcribing
            if refine {
                refinementRequests.insert(recording.sessionID)
            }
            Task { [weak self] in
                await self?.transcribe(
                    recording,
                    refine: refine,
                    refinementInstructions: refinementInstructions
                )
            }
        } catch {
            captureID = nil
            captureState = .idle
            level = 0.04
            recordingDuration = 0
            report(error)
        }
    }

    func cancelListening() async {
        guard captureState != .idle else { return }
        captureID = nil
        do {
            try await recorder.cancel()
        } catch {
            report(error)
        }
        captureState = .idle
        level = 0.04
        recordingDuration = 0
    }

    func dismissError() {
        lastError = nil
    }

    func show(_ error: any Error) {
        report(error)
    }

    private func transcribe(
        _ recording: QuickRecordingEngine.Result,
        refine: Bool,
        refinementInstructions: String
    ) async {
        let phaseMonitor = refine
            ? Task { [weak self] in
                await self?.monitorProcessingPhase(sessionID: recording.sessionID)
            }
            : nil
        defer {
            phaseMonitor?.cancel()
            activeTranscriptions -= 1
            processingPhases.removeValue(forKey: recording.sessionID)
            refinementRequests.remove(recording.sessionID)
        }
        do {
            let transcript = try await client.transcribeImmediately(
                sessionID: recording.sessionID,
                audioURL: recording.fileURL,
                durationMilliseconds: recording.durationMilliseconds,
                refine: refine,
                customRefinementInstructions: refinementInstructions
            )
            if refine && transcript.refined != true {
                throw RefinementConfirmationError()
            }
            await synchronizer.receiveImmediate(transcript)
            do {
                try fileManager.removeItem(at: recording.fileURL)
            } catch {
                report(QuickRecordingEngine.RecordingError.cleanupFailed(
                    fileURL: recording.fileURL, underlying: error
                ))
            }
        } catch {
            report(error, retainedAudioURL: recording.fileURL)
        }
    }

    private struct RefinementConfirmationError: LocalizedError {
        var errorDescription: String? {
            "The backend did not confirm the requested refinement."
        }
    }

    private func monitorProcessingPhase(sessionID: UUID) async {
        while !Task.isCancelled {
            do {
                let session = try await client.recordingSession(id: sessionID)
                if session.status == .refining {
                    guard processingPhases[sessionID] != nil else { return }
                    processingPhases[sessionID] = .refining
                } else if session.status == .completed || session.status == .failed {
                    return
                }
            } catch APIClient.Error.server(status: 404, detail: _) {
                // The immediate request may not have created its session yet.
            } catch is CancellationError {
                return
            } catch {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    private func report(_ error: any Error, retainedAudioURL: URL? = nil) {
        let message = error.localizedDescription
            + (retainedAudioURL.map { "\nAudio saved at: \($0.path)" } ?? "")
        lastError = message
        logger.error("Quick transcription failed: \(message, privacy: .private)")
    }
}
