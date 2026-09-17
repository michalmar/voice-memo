import AVFoundation
import Foundation

actor QuickRecordingEngine {
    enum RecordingError: LocalizedError {
        case microphoneDenied
        case couldNotRecord
        case notRecording

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is denied. Enable it for VoicePrompt in System Settings."
            case .couldNotRecord:
                return "VoicePrompt could not start the microphone."
            case .notRecording:
                return "There is no active recording."
            }
        }
    }

    struct Result: Sendable {
        let sessionID: UUID
        let fileURL: URL
        let durationMilliseconds: Int
    }

    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var meterTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    func start(levelChanged: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecordingError.microphoneDenied
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let url = directory.appending(path: "\(id.uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecordingError.couldNotRecord }
        self.recorder = recorder
        sessionID = id
        startedAt = Date()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let level = await self?.meterLevel() else { return }
                await levelChanged(level)
            }
        }
    }

    func stop() throws -> Result {
        meterTask?.cancel()
        meterTask = nil
        guard let recorder, let sessionID, let startedAt else {
            throw RecordingError.notRecording
        }
        recorder.stop()
        self.recorder = nil
        self.sessionID = nil
        self.startedAt = nil
        return Result(
            sessionID: sessionID,
            fileURL: recorder.url,
            durationMilliseconds: max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
        )
    }

    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        sessionID = nil
        startedAt = nil
    }

    private func meterLevel() -> Double? {
        guard let recorder else { return nil }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return min(1, max(0.04, Double(pow(10, decibels / 24))))
    }
}
