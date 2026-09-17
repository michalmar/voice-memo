import AppKit
import SwiftUI

@MainActor
final class TranscriptionOverlayController {
    private let panel: NSPanel

    init(controller: TranscriptionController, shortcut: GlobalShortcutManager) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 366, height: 92),
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
        panel.contentView = NSHostingView(
            rootView: TranscriptionOverlay(controller: controller, shortcut: shortcut)
        )
    }

    func update(isVisible: Bool) {
        guard isVisible else {
            panel.orderOut(nil)
            return
        }
        if !panel.setFrameUsingName("quick-transcription-overlay") {
            position()
        }
        panel.orderFrontRegardless()
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

private struct TranscriptionOverlay: View {
    @ObservedObject var controller: TranscriptionController
    @ObservedObject var shortcut: GlobalShortcutManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(QuickTranscriptionDefaults.refine) private var refine = true

    var body: some View {
        HStack(spacing: 14) {
            PanelDragHandle()

            if controller.captureState == .listening {
                SoundBars(level: controller.level)
                    .frame(width: 54, height: 34)
            } else if controller.refinementRequestedTranscriptions > 0 {
                RefinementProgressIndicator(
                    isRefining: controller.displayedProcessingPhase == .refining
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 54)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if controller.captureState == .listening {
                Toggle("Refine", isOn: $refine)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Refine")
                    .accessibilityLabel("Refine")

                Button {
                    Task { await controller.cancelListening() }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel without transcribing")
                .accessibilityLabel("Cancel recording")

                Button {
                    Task { await controller.stopListening() }
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .systemGreen), in: Circle())
                }
                .buttonStyle(.borderless)
                .help("Stop and transcribe")
                .accessibilityLabel("Stop and transcribe")
            } else if controller.lastError != nil {
                Button {
                    controller.dismissError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 346, height: 72)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                        : AnyShapeStyle(.ultraThickMaterial)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.primary : .white.opacity(0.16))
        }
        .padding(10)
        .help("Drag the panel to move it")
    }

    private var title: String {
        if let error = controller.lastError { return error }
        if controller.captureState == .starting { return "Opening microphone" }
        if controller.captureState == .listening { return "Listening" }
        if controller.displayedProcessingPhase == .refining {
            return "Refining with Luna"
        }
        return controller.activeTranscriptions == 1
            ? "Transcribing"
            : "Transcribing \(controller.activeTranscriptions) recordings"
    }

    private var detail: String {
        if controller.lastError != nil { return retryMessage }
        if controller.captureState == .listening {
            if controller.refiningTranscriptions > 0 {
                return controller.activeTranscriptions == 1
                    ? "Luna refining an earlier recording"
                    : "Luna refining · \(controller.activeTranscriptions) earlier recordings"
            }
            return controller.activeTranscriptions > 0
                ? "\(controller.activeTranscriptions) earlier recording processing"
                : "Stop to transcribe · × to cancel"
        }
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
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Color(nsColor: .systemGreen).opacity(index == 2 ? 1 : 0.78))
                        .frame(width: 6, height: height(for: index, at: timeline.date))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
                }
            }
        }
        .accessibilityLabel("Microphone level")
    }

    private func height(for index: Int, at date: Date) -> CGFloat {
        let shape = [0.55, 0.82, 1.0, 0.76, 0.48][index]
        let phase = date.timeIntervalSinceReferenceDate * 6 + Double(index) * 0.9
        let pulse = reduceMotion ? 0.75 : 0.72 + sin(phase) * 0.18
        return max(6, 34 * shape * (0.28 + level * pulse))
    }
}
