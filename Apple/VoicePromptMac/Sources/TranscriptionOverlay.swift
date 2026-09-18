import AppKit
import Combine
import SwiftUI

@MainActor
final class TranscriptionOverlayPresentation: ObservableObject {
    @Published private(set) var isMinimized = false
    private var captureState = TranscriptionController.CaptureState.idle
    private var hasError = false

    func update(captureState: TranscriptionController.CaptureState, hasError: Bool) {
        if captureState != .listening || hasError {
            isMinimized = false
        } else if self.captureState != .listening {
            isMinimized = true
        }
        self.captureState = captureState
        self.hasError = hasError
    }

    func setMinimized(_ minimized: Bool) {
        guard captureState == .listening, !hasError else { return }
        isMinimized = minimized
    }
}

enum TranscriptionOverlayLayout {
    static let expandedSize = NSSize(width: 366, height: 92)
    static let minimizedSize = NSSize(width: 152, height: 60)
    static let errorSize = NSSize(width: 366, height: 220)

    static func size(isMinimized: Bool, hasError: Bool) -> NSSize {
        if hasError { return errorSize }
        return isMinimized ? minimizedSize : expandedSize
    }

    static func frame(resizing frame: NSRect, to size: NSSize, within screen: NSRect) -> NSRect {
        NSRect(
            x: min(max(frame.midX - size.width / 2, screen.minX), screen.maxX - size.width),
            y: min(max(frame.maxY - size.height, screen.minY), screen.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class TranscriptionOverlayController {
    private let panel: NSPanel
    private let controller: TranscriptionController
    private let presentation = TranscriptionOverlayPresentation()
    private var sizeSubscription: AnyCancellable?

    init(controller: TranscriptionController, shortcut: GlobalShortcutManager) {
        self.controller = controller
        panel = TranscriptionPanel(
            contentRect: NSRect(origin: .zero, size: TranscriptionOverlayLayout.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.setFrameAutosaveName("quick-transcription-overlay")
        let hostingView = NSHostingView(
            rootView: TranscriptionOverlay(
                controller: controller, shortcut: shortcut, presentation: presentation
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        sizeSubscription = presentation.$isMinimized.removeDuplicates().sink { [weak self] minimized in
            self?.resize(minimized: minimized)
        }
    }

    func update() {
        guard controller.isVisible else {
            panel.orderOut(nil)
            presentation.update(captureState: controller.captureState, hasError: controller.lastError != nil)
            return
        }
        if !panel.isVisible {
            if !panel.setFrameUsingName("quick-transcription-overlay") {
                position()
            }
        }
        presentation.update(captureState: controller.captureState, hasError: controller.lastError != nil)
        resize(minimized: presentation.isMinimized)
        panel.orderFrontRegardless()
    }

    private func resize(minimized: Bool) {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let size = TranscriptionOverlayLayout.size(isMinimized: minimized, hasError: controller.lastError != nil)
        let frame = TranscriptionOverlayLayout.frame(
            resizing: panel.frame, to: size, within: screen.visibleFrame
        )
        guard frame != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.setFrame(frame, display: true, animate: panel.isVisible && context.duration > 0)
        }
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.maxY - frame.height - 56
        ))
    }
}

private final class TranscriptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct TranscriptionOverlay: View {
    @ObservedObject var controller: TranscriptionController
    @ObservedObject var shortcut: GlobalShortcutManager
    @ObservedObject var presentation: TranscriptionOverlayPresentation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(QuickTranscriptionDefaults.refine) private var refine = true

    private var isMinimized: Bool {
        presentation.isMinimized && controller.lastError == nil
    }

    private var size: NSSize {
        TranscriptionOverlayLayout.size(isMinimized: isMinimized, hasError: controller.lastError != nil)
    }

    var body: some View {
        Group {
            if isMinimized {
                minimizedContent
            } else {
                VStack(spacing: 0) {
                    expandedContent
                        .frame(height: 72)
                    if let error = controller.lastError {
                        TranscriptionErrorDetails(message: error)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(
            width: size.width - 20,
            height: size.height - 20
        )
        .background {
            RoundedRectangle(cornerRadius: isMinimized ? 20 : 18, style: .continuous)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                        : AnyShapeStyle(.ultraThickMaterial)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: isMinimized ? 20 : 18, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.primary : .white.opacity(0.16))
                .allowsHitTesting(false)
        }
        .padding(10)
    }

    private var minimizedContent: some View {
        HStack(spacing: 12) {
            Button {
                presentation.setMinimized(false)
            } label: {
                SoundBars(level: controller.level)
                    .frame(width: 72, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDButtonStyle())
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help("Expand recording HUD")
            .accessibilityLabel("Expand recording HUD")
            .accessibilityIdentifier("expand-recording-hud")

            stopButton(size: 24)
        }
        .padding(.horizontal, 12)
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            PanelDragHandle()

            if controller.captureState == .listening {
                SoundBars(level: controller.level)
                    .frame(width: 70, height: 34)
            } else if controller.refinementRequestedTranscriptions > 0 {
                RefinementProgressIndicator(
                    isRefining: controller.displayedProcessingPhase == .refining
                )
            } else if controller.lastError != nil && controller.activeTranscriptions == 0 {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(width: 54)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 54)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if controller.captureState == .listening {
                        Text(controller.recordingTime)
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityLabel("Recording time")
                            .accessibilityValue(controller.recordingTime)
                            .accessibilityIdentifier("recording-timer")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if controller.captureState == .listening {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle("Refine", isOn: $refine)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Refine")
                            .accessibilityLabel("Refine")

                        Button {
                            presentation.setMinimized(true)
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.caption)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(HUDButtonStyle())
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .disabled(controller.lastError != nil)
                        .help("Minimize recording HUD")
                        .accessibilityLabel("Minimize recording HUD")
                        .accessibilityIdentifier("minimize-recording-hud")
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task { await controller.cancelListening() }
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(HUDButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel without transcribing")
                        .accessibilityLabel("Cancel recording")

                        stopButton(size: 28)
                    }
                }
            } else if controller.lastError != nil {
                Button {
                    controller.dismissError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 16)
    }

    private func stopButton(size: CGFloat) -> some View {
        Button {
            Task { await controller.stopListening() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(nsColor: .systemGreen), in: Circle())
        }
        .buttonStyle(HUDButtonStyle())
        .keyboardShortcut(.defaultAction)
        .help("Stop and transcribe")
        .accessibilityLabel("Stop and transcribe")
        .accessibilityIdentifier("stop-recording")
    }

    private struct HUDButtonStyle: ButtonStyle {
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
        }
    }

    private var title: String {
        if controller.captureState == .starting { return "Opening microphone" }
        if controller.captureState == .listening { return "Listening" }
        if controller.lastError != nil && controller.activeTranscriptions == 0 { return "Recording issue" }
        if controller.displayedProcessingPhase == .refining {
            return "Refining with Luna"
        }
        return controller.activeTranscriptions == 1
            ? "Transcribing"
            : "Transcribing \(controller.activeTranscriptions) recordings"
    }

    private var detail: String {
        if controller.captureState == .listening {
            if controller.refiningTranscriptions > 0 {
                return controller.activeTranscriptions == 1
                    ? "Luna refining an earlier recording"
                    : "Luna refining · \(controller.activeTranscriptions) earlier recordings"
            }
            return controller.activeTranscriptions > 0
                ? "\(controller.activeTranscriptions) earlier recording processing"
                : "Stop to transcribe"
        }
        if controller.lastError != nil && controller.activeTranscriptions == 0 { return retryMessage }
        if controller.refiningTranscriptions > 0 && controller.activeTranscriptions > 1 {
            let transcribing = controller.activeTranscriptions - controller.refiningTranscriptions
            return transcribing > 0
                ? "\(controller.refiningTranscriptions) refining · \(transcribing) transcribing"
                : "\(controller.refiningTranscriptions) recordings refining"
        }
        return shortcut.isEnabled
            ? "Press \(shortcut.shortcut.displayName) to record another"
            : "Use the menu to record another"
    }

    struct TranscriptionErrorDetails: View {
        let message: String

        var body: some View {
            ScrollView(.vertical) {
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("transcription-error-message")
            }
            .scrollIndicators(.visible)
            .help(message)
            .id(message)
            .accessibilityIdentifier("transcription-error-details")
        }
    }

    private var retryMessage: String {
        shortcut.isEnabled
            ? "Press \(shortcut.shortcut.displayName) to try again"
            : "Use the menu to try again"
    }
}

private struct RefinementProgressIndicator: View {
    let isRefining: Bool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 54)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isRefining
                ? "Refining transcription with Luna"
                : "Transcribing with refinement enabled"
        )
    }
}

private struct PanelDragHandle: View {
    var body: some View {
        ZStack {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            WindowDragArea()
        }
        .frame(width: 10, height: 34)
        .help("Drag to move the transcription panel")
        .accessibilityLabel("Move transcription panel")
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct SoundBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: SoundWaveform.barSpacing) {
                ForEach(0..<SoundWaveform.barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: SoundWaveform.barWidth, height: SoundWaveform.height(
                            for: index,
                            level: level,
                            time: timeline.date.timeIntervalSinceReferenceDate,
                            reduceMotion: reduceMotion
                        ))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

enum SoundWaveform {
    static let barCount = 17
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2

    static func height(for index: Int, level: Double, time: TimeInterval, reduceMotion: Bool) -> CGFloat {
        let position = Double(index) / Double(barCount - 1)
        let envelope = 0.35 + 0.65 * pow(sin(position * .pi), 0.7)
        let energy = pow(min(1, max(0, (level - 0.04) * 2.6)), 0.65)
        let wave = reduceMotion ? 0.8 :
            0.25 + 0.5 * abs(sin(Double(index) * 0.68 - time * 11))
                + 0.25 * abs(sin(Double(index) * 1.17 + time * 17))
        return 3 + 31 * envelope * (0.04 + 0.96 * energy) * wave
    }
}
