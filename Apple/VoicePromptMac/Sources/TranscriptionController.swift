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
    @Published private(set) var activeTranscriptions = 0
    @Published private(set) var lastError: String?
    @Published private var processingPhases: [UUID: ProcessingPhase] = [:]
    @Published private var refinementRequests: Set<UUID> = []

    private let recorder: QuickRecordingEngine
    private let client: APIClient
    private let synchronizer: CompletionSynchronizer
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.macos", category: "QuickTranscription")

    var isVisible: Bool {
        captureState != .idle || activeTranscriptions > 0 || lastError != nil
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
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.synchronizer = synchronizer
        self.defaults = defaults
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "VoicePrompt/QuickRecordings", directoryHint: .isDirectory)
        recorder = QuickRecordingEngine(directory: directory)
    }

    func startListening() async {
        guard captureState == .idle else { return }
        synchronizer.prepareImmediateDelivery()
        captureState = .starting
        lastError = nil
        do {
            try await recorder.start { [weak self] level in
                self?.level = level
            }
            captureState = .listening
        } catch {
            captureState = .idle
            report(error)
        }
    }

    func stopListening() async {
        guard captureState == .listening else { return }
        do {
            let recording = try await recorder.stop()
            captureState = .idle
            level = 0.04
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
            captureState = .idle
            report(error)
        }
    }

    func cancelListening() async {
        guard captureState != .idle else { return }
        await recorder.cancel()
        captureState = .idle
        level = 0.04
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
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        do {
            let transcript = try await client.transcribeImmediately(
                sessionID: recording.sessionID,
                audioURL: recording.fileURL,
                durationMilliseconds: recording.durationMilliseconds,
                refine: refine,
                customRefinementInstructions: refinementInstructions
            )
            await synchronizer.receiveImmediate(transcript)
            if refine && transcript.refined != true {
                report(RefinementConfirmationError())
            }
        } catch {
            report(error)
        }
    }

    private struct RefinementConfirmationError: LocalizedError {
        var errorDescription: String? {
            "The transcription completed, but the backend did not confirm refinement."
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

    private func report(_ error: any Error) {
        lastError = error.localizedDescription
        logger.error("Quick transcription failed: \(error.localizedDescription, privacy: .private)")
    }
}
