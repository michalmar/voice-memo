import AppKit
import Testing
@testable import VoicePromptMac

@MainActor
struct TranscriptionOverlayTests {
    @Test func recordingsStartMinimizedAndRememberExpansionUntilTheNextRecording() {
        let presentation = TranscriptionOverlayPresentation()
        presentation.update(captureState: .starting, hasError: false)
        #expect(!presentation.isMinimized)
        presentation.update(captureState: .listening, hasError: false)
        #expect(presentation.isMinimized)
        presentation.setMinimized(false)
        presentation.update(captureState: .listening, hasError: false)
        #expect(!presentation.isMinimized)
        presentation.setMinimized(true)
        #expect(presentation.isMinimized)
        presentation.update(captureState: .idle, hasError: false)
        #expect(!presentation.isMinimized)
        presentation.update(captureState: .listening, hasError: false)
        #expect(presentation.isMinimized)
    }

    @Test func errorsAndProcessingCannotBeHiddenByMinimizing() {
        let presentation = TranscriptionOverlayPresentation()
        presentation.update(captureState: .listening, hasError: false)
        presentation.update(captureState: .listening, hasError: true)
        #expect(!presentation.isMinimized)
        presentation.setMinimized(true)
        #expect(!presentation.isMinimized)
        presentation.update(captureState: .idle, hasError: false)
        presentation.setMinimized(true)
        #expect(!presentation.isMinimized)
    }

    @Test func resizingPreservesTopCenterAndRestoresOriginalSize() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let original = NSRect(x: 540, y: 720, width: 366, height: 92)
        let minimized = TranscriptionOverlayLayout.frame(
            resizing: original, to: TranscriptionOverlayLayout.minimizedSize, within: screen
        )
        #expect(minimized.size == NSSize(width: 152, height: 60))
        #expect(minimized.midX == original.midX)
        #expect(minimized.maxY == original.maxY)
        #expect(TranscriptionOverlayLayout.frame(
            resizing: minimized, to: TranscriptionOverlayLayout.expandedSize, within: screen
        ) == original)
    }

    @Test func expandingAtDisplayEdgesStaysOnScreen() {
        // A display to the left of the primary screen also has negative coordinates.
        let screen = NSRect(x: -1440, y: 24, width: 1440, height: 876)
        for origin in [
            NSPoint(x: screen.minX, y: screen.minY),
            NSPoint(x: screen.maxX - 152, y: screen.minY),
            NSPoint(x: screen.minX, y: screen.maxY - 60),
            NSPoint(x: screen.maxX - 152, y: screen.maxY - 60),
        ] {
            let frame = TranscriptionOverlayLayout.frame(
                resizing: NSRect(origin: origin, size: TranscriptionOverlayLayout.minimizedSize),
                to: TranscriptionOverlayLayout.expandedSize,
                within: screen
            )
            #expect(screen.contains(frame))
        }
    }

    @Test func waveformUsesMoreThinnerBarsWithBoundedAudioResponsiveHeights() {
        #expect(SoundWaveform.barCount == 17)
        #expect(SoundWaveform.barWidth == 2)
        #expect(CGFloat(SoundWaveform.barCount) * SoundWaveform.barWidth
            + CGFloat(SoundWaveform.barCount - 1) * SoundWaveform.barSpacing <= 70)
        for time in stride(from: 0.0, through: 2.0, by: 1.0 / 30) {
            for index in 0..<SoundWaveform.barCount {
                let quiet = SoundWaveform.height(for: index, level: 0.04, time: time, reduceMotion: false)
                let loud = SoundWaveform.height(for: index, level: 1, time: time, reduceMotion: false)
                #expect((3...5).contains(quiet))
                #expect((3...34).contains(loud))
                #expect(loud > quiet)
            }
        }
        let centerHeights = stride(from: 0.0, through: 1.0, by: 1.0 / 30).map {
            SoundWaveform.height(for: 8, level: 1, time: $0, reduceMotion: false)
        }
        #expect(centerHeights.max()! - centerHeights.min()! > 15)
    }

    @Test func reducedMotionRemovesTheDecorativeWaveButRetainsAudioFeedback() {
        for index in 0..<SoundWaveform.barCount {
            let first = SoundWaveform.height(for: index, level: 0.5, time: 0, reduceMotion: true)
            let later = SoundWaveform.height(for: index, level: 0.5, time: 20, reduceMotion: true)
            #expect(first == later)
            #expect(first > SoundWaveform.height(for: index, level: 0.04, time: 0, reduceMotion: true))
        }
    }
}
