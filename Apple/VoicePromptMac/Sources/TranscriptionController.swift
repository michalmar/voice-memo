import Foundation
import OSLog
import VoicePromptKit

@MainActor
final class TranscriptionController: ObservableObject {
    enum CaptureState: Equatable {
        case idle
        case listening
        case starting
    }

    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var level = 0.04
    @Published private(set) var activeTranscriptions = 0
    @Published private(set) var lastError: String?

    private let recorder: QuickRecordingEngine
    private let client: APIClient
    private let synchronizer: CompletionSynchronizer
    private let logger = Logger(subsystem: "com.michalmar.voiceprompt.macos", category: "QuickTranscription")

    var isVisible: Bool {
        captureState != .idle || activeTranscriptions > 0 || lastError != nil
    }

    init(client: APIClient, synchronizer: CompletionSynchronizer) {
        self.client = client
        self.synchronizer = synchronizer
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
            activeTranscriptions += 1
            Task { [weak self] in
                await self?.transcribe(recording)
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

    private func transcribe(_ recording: QuickRecordingEngine.Result) async {
        defer {
            activeTranscriptions -= 1
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        do {
            let transcript = try await client.transcribeImmediately(
                sessionID: recording.sessionID,
                audioURL: recording.fileURL,
                durationMilliseconds: recording.durationMilliseconds
            )
            await synchronizer.receiveImmediate(transcript)
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        lastError = error.localizedDescription
        logger.error("Quick transcription failed: \(error.localizedDescription, privacy: .private)")
    }
}
