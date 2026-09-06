import AVFoundation
import Testing
@testable import VoicePromptIOS

@Suite(.serialized)
@MainActor
struct RecordingEngineTests {
    @Test func audioSessionUsesSupportedRecordingMode() throws {
        let session = AVAudioSession.sharedInstance()
        let previousCategory = session.category
        let previousMode = session.mode
        let previousOptions = session.categoryOptions
        defer {
            #expect(throws: Never.self) {
                try session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            }
        }

        try RecordingEngine.configureAudioSession(session)

        #expect(session.category == .record)
        #expect(session.mode == .default)
        #expect(session.availableModes.contains(session.mode))
        #expect(session.categoryOptions.contains(.allowBluetoothHFP))
    }
}
