import AVFoundation
import CryptoKit
import Foundation
import OSLog
import VoicePromptKit

protocol AudioRecording: Sendable {
    func start(sessionID: UUID) async throws
    func stop() async throws -> [ChunkMetadata]
}

actor RecordingEngine: AudioRecording {
    enum Error: LocalizedError {
        case microphoneDenied, notRecording, couldNotRecord

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Microphone access is denied. Enable it for VoicePrompt in Settings."
            case .notRecording: return "There is no active recording to save."
            case .couldNotRecord: return "The microphone could not start recording. Check the simulator's audio input."
            }
        }
    }

    private let segmentDuration: TimeInterval = 30
    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var sessionID: UUID?
    private var sequence = 0
    private var segmentStart = Date()
    private var timerTask: Task<Void, Never>?
    private var chunks: [ChunkMetadata] = []
    private var segmentError: (any Swift.Error)?

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
        segmentError = nil
        do { try beginSegment() }
        catch {
            deactivateAudioSession()
            self.sessionID = nil
            throw error
        }
        let duration = segmentDuration
        timerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(duration))
                    try Task.checkCancellation()
                    try await self?.rotateSegment()
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.segmentFailed(error)
            }
        }
    }

    func stop() async throws -> [ChunkMetadata] {
        timerTask?.cancel()
        timerTask = nil
        defer {
            recorder?.stop()
            recorder = nil
            sessionID = nil
            deactivateAudioSession()
        }
        if let segmentError { throw segmentError }
        guard recorder != nil else { throw Error.notRecording }
        try finishSegment()
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
        guard recorder?.record() == true else {
            recorder = nil
            throw Error.couldNotRecord
        }
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

    private func segmentFailed(_ error: any Swift.Error) {
        segmentError = error
        recorder?.stop()
        Logger(subsystem: "com.michalmar.voiceprompt.ios", category: "Recording")
            .error("Audio segment failed: \(error.localizedDescription, privacy: .private)")
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger(subsystem: "com.michalmar.voiceprompt.ios", category: "Recording")
                .error("Could not release the microphone: \(error.localizedDescription, privacy: .private)")
        }
    }
}
