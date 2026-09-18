import AppKit
import SwiftUI
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

    @Test func errorsUseABoundedExpandedSizeEvenWhenPreviouslyMinimized() {
        for minimized in [true, false] {
            #expect(TranscriptionOverlayLayout.size(isMinimized: minimized, hasError: true)
                == TranscriptionOverlayLayout.errorSize)
        }
        #expect(TranscriptionOverlayLayout.size(isMinimized: true, hasError: false)
            == TranscriptionOverlayLayout.minimizedSize)
        #expect(TranscriptionOverlayLayout.size(isMinimized: false, hasError: false)
            == TranscriptionOverlayLayout.expandedSize)
    }

    @Test func errorExpansionPreservesTopCenterAndRestoresTheOriginalSize() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let original = NSRect(x: 540, y: 720, width: 366, height: 92)
        let expanded = TranscriptionOverlayLayout.frame(
            resizing: original, to: TranscriptionOverlayLayout.errorSize, within: screen
        )
        #expect(expanded.midX == original.midX)
        #expect(expanded.maxY == original.maxY)
        #expect(expanded.size == NSSize(width: 366, height: 220))
        #expect(TranscriptionOverlayLayout.frame(
            resizing: expanded, to: TranscriptionOverlayLayout.expandedSize, within: screen
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
            for size in [TranscriptionOverlayLayout.expandedSize, TranscriptionOverlayLayout.errorSize] {
                let frame = TranscriptionOverlayLayout.frame(
                    resizing: NSRect(origin: origin, size: TranscriptionOverlayLayout.minimizedSize),
                    to: size,
                    within: screen
                )
                #expect(screen.contains(frame))
            }
        }
    }

    @Test func longRecoveryErrorsAreScrollableAndExposeTheCompletePath() throws {
        let path = "/Users/Recording User/Library/Application Support/VoicePrompt/QuickRecordings/\(UUID()).m4a"
        let message = String(repeating: "The server could not save the transcript. ", count: 40)
            + "\nAudio saved at: \(path)"
        let hostingView = NSHostingView(rootView:
            TranscriptionOverlay.TranscriptionErrorDetails(message: message).frame(width: 314, height: 116)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 314, height: 116),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        #expect(hostingView.fittingSize == NSSize(width: 314, height: 116))

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try #require(scrollView(in: hostingView))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentSize.height)
        document.scrollToVisible(NSRect(
            x: 0, y: document.bounds.maxY - 1, width: 1, height: 1
        ))
        #expect(scroll.contentView.bounds.maxY >= document.bounds.maxY - 1)

        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "recovery-error-scrolled-to-complete-path.png")
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
