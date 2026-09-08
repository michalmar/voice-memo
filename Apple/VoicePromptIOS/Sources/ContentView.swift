import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecordingViewModel
    @GestureState private var pressing = false
    @State private var holdingToTalk = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "mic.fill.badge.plus")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("VoicePrompt").font(.largeTitle.bold())
                Text(model.state.rawValue)
                    .font(.headline)
                    .foregroundStyle(model.state == .error ? .red : .secondary)
                    .accessibilityLabel("Status: \(model.state.rawValue)")
                if let progress = model.progressMessage {
                    if [.uploading, .processing].contains(model.state) {
                        ProgressView(progress)
                            .accessibilityLabel(progress)
                    } else {
                        Text(progress).font(.callout)
                    }
                }
                Text(model.checkingBackend ? "Checking cloud connection..." :
                        model.backendReady ? "Cloud ready" : "Cloud unavailable — recording is saved locally")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    Label(model.authenticationState.rawValue,
                          systemImage: model.authenticationState == .signedIn ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(model.authenticationState == .signedIn ? Color.green : Color.secondary)
                    if model.authenticationState == .signedIn {
                        Button("Sign Out") { Task { await model.signOut() } }
                            .disabled(model.isBusy || model.state == .recording)
                    } else {
                        Button("Sign in with Microsoft") { Task { await model.signIn() } }
                            .disabled([.checking, .signingIn].contains(model.authenticationState) || model.isBusy)
                    }
                    if let message = model.authenticationMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if model.canRetryUploads {
                    Text(model.pendingRecordingCount > 0 ?
                         "\(model.pendingRecordingCount) recording(s) saved on this device." :
                         "The recording could not be added to the upload queue. Retry saving it before closing the app.")
                        .font(.footnote)
                    Button("Retry saved uploads") { Task { await model.retryUploads() } }
                        .disabled(model.isBusy || model.state == .recording || model.authenticationState != .signedIn)
                }
                if model.processingSessionID != nil && [.error, .offline].contains(model.state) {
                    Button("Check processing status") { Task { await model.monitorProcessing() } }
                }
                Button {
                    Task { await model.toggle() }
                } label: {
                    Label(model.state == .recording ? "Stop" : "Start", systemImage: model.state == .recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.state == .recording ? .red : .orange)
                .disabled(model.state != .recording && !model.canStartRecording)
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
                                guard !holdingToTalk, model.canStartRecording else { return }
                                holdingToTalk = true
                                Task { await model.start() }
                            }
                            .onEnded { _ in
                                guard holdingToTalk else { return }
                                holdingToTalk = false
                                Task { await model.stop() }
                            }
                    )
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Recording runs only while held")
                .opacity(model.canStartRecording || holdingToTalk ? 1 : 0.5)
            }
            .padding(24)
        }
        .task { await model.prepare() }
        .task(id: model.processingSessionID) { await model.monitorProcessing() }
    }
}
