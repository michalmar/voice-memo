import AVFoundation
import Foundation

protocol QuickRecording: Sendable {
    func start(
        meterChanged: @escaping @MainActor @Sendable (QuickRecordingEngine.MeterReading) -> Void
    ) async throws
    func stop() async throws -> QuickRecordingEngine.Result
    func cancel() async throws
}

actor QuickRecordingEngine: QuickRecording {
    enum RecordingError: LocalizedError {
        case microphoneDenied
        case couldNotRecord
        case notRecording
        case cleanupFailed(fileURL: URL, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access is denied. Enable it for VoicePrompt in System Settings."
            case .couldNotRecord:
                return "VoicePrompt could not start the microphone."
            case .notRecording:
                return "There is no active recording."
            case let .cleanupFailed(fileURL, underlying):
                return "The audio file could not be deleted: \(underlying.localizedDescription)\nAudio saved at: \(fileURL.path)"
            }
        }
    }

    struct Result: Sendable {
        let sessionID: UUID
        let fileURL: URL
        let durationMilliseconds: Int
    }

    struct MeterReading: Sendable {
        let level: Double
        let duration: TimeInterval
    }

    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var sessionID: UUID?
    private var pendingStartID: UUID?
    private var meterTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    func start(meterChanged: @escaping @MainActor @Sendable (MeterReading) -> Void) async throws {
        let startID = UUID()
        pendingStartID = startID
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard pendingStartID == startID else { throw CancellationError() }
        pendingStartID = nil
        guard allowed else {
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
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let reading = await self?.meterReading() else { return }
                await meterChanged(reading)
            }
        }
    }

    func stop() throws -> Result {
        meterTask?.cancel()
        meterTask = nil
        guard let recorder, let sessionID else {
            throw RecordingError.notRecording
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.sessionID = nil
        return Result(
            sessionID: sessionID,
            fileURL: recorder.url,
            durationMilliseconds: max(1, Int(duration * 1_000))
        )
    }

    func cancel() throws {
        pendingStartID = nil
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        defer {
            recorder = nil
            sessionID = nil
        }
        if let url = recorder?.url {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw RecordingError.cleanupFailed(fileURL: url, underlying: error)
            }
        }
    }

    private func meterReading() -> MeterReading? {
        guard let recorder else { return nil }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return MeterReading(
            level: min(1, max(0.04, Double(pow(10, decibels / 24)))),
            duration: recorder.currentTime
        )
    }
}
