import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecordingViewModel
    @GestureState private var pressing = false

    var body: some View {
        VStack(spacing: 36) {
            Spacer()
            Image(systemName: "mic.fill.badge.plus")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("VoicePrompt").font(.largeTitle.bold())
            Text(model.state.rawValue)
                .font(.headline)
                .foregroundStyle(model.state == .error ? .red : .secondary)
                .accessibilityLabel("Status: \(model.state.rawValue)")
            Text(model.backendReady ? "Cloud ready" : "Cloud warming up — recording is available")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.toggle() }
            } label: {
                Label(model.state == .recording ? "Stop" : "Start", systemImage: model.state == .recording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityHint("Double tap to start or stop continuous recording")

            Text("Hold to talk")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 88)
                .background(pressing ? Color.orange : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($pressing) { _, value, _ in value = true }
                        .onChanged { _ in
                            if model.state != .recording { Task { await model.start() } }
                        }
                        .onEnded { _ in Task { await model.stop() } }
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Recording runs only while held")
            Spacer()
        }
        .padding(24)
        .task { await model.warmBackend() }
    }
}

