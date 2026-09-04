import AVFoundation
import CryptoKit
import Foundation
import VoicePromptKit

protocol AudioRecording: Sendable {
    func start(sessionID: UUID) async throws
    func stop() async throws -> [ChunkMetadata]
}

actor RecordingEngine: AudioRecording {
    enum Error: Swift.Error { case microphoneDenied, notRecording }

    private let segmentDuration: TimeInterval = 30
    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var sessionID: UUID?
    private var sequence = 0
    private var segmentStart = Date()
    private var timerTask: Task<Void, Never>?
    private var chunks: [ChunkMetadata] = []

    init(directory: URL) {
        self.directory = directory
    }

    func start(sessionID: UUID) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Error.microphoneDenied }
        try FileManager.default.createDirectory(
            at: directory.appending(path: sessionID.uuidString),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
        try session.setActive(true)
        self.sessionID = sessionID
        sequence = 0
        chunks = []
        try beginSegment()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(segmentDuration))
                try? await self?.rotateSegment()
            }
        }
    }

    func stop() async throws -> [ChunkMetadata] {
        guard recorder != nil else { throw Error.notRecording }
        timerTask?.cancel()
        try finishSegment()
        recorder = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return chunks
    }

    private func rotateSegment() throws {
        try finishSegment()
        sequence += 1
        try beginSegment()
    }

    private func beginSegment() throws {
        guard let sessionID else { throw Error.notRecording }
        let url = directory
            .appending(path: sessionID.uuidString)
            .appending(path: String(format: "%06d.m4a", sequence))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        segmentStart = Date()
        recorder?.record()
    }

    private func finishSegment() throws {
        guard let recorder, let sessionID else { throw Error.notRecording }
        recorder.stop()
        let data = try Data(contentsOf: recorder.url, options: .mappedIfSafe)
        let duration = max(1, Int(Date().timeIntervalSince(segmentStart) * 1_000))
        chunks.append(ChunkMetadata(
            sessionID: sessionID,
            sequence: sequence,
            startedMilliseconds: sequence * Int(segmentDuration * 1_000),
            durationMilliseconds: duration,
            byteLength: data.count,
            checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            fileURL: recorder.url,
            attempts: 0
        ))
    }
}

