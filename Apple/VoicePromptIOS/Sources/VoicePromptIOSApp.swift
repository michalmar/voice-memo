import SwiftUI
import VoicePromptKit

private struct DevelopmentCredentials: CredentialProvider {
    func identityToken() async throws -> (token: String, nonce: String) {
        throw CocoaError(.userAuthenticationRequired)
    }
}

@main
struct VoicePromptIOSApp: App {
    @StateObject private var model: RecordingViewModel

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseURL = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? "https://voiceprompt.invalid/")!
        let client = APIClient(baseURL: baseURL, credentials: DevelopmentCredentials())
        let queue = try! UploadQueue(directory: support.appending(path: "Uploads"))
        _model = StateObject(wrappedValue: RecordingViewModel(
            recorder: RecordingEngine(directory: support.appending(path: "Recordings")),
            client: client,
            queue: queue
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}
