import SwiftUI
import VoicePromptKit

@main
struct VoicePromptIOSApp: App {
    @StateObject private var model: RecordingViewModel
    private let credentials: EntraCredentialProvider
    private let authorization: EntraAuthorizationCoordinator

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseURL = URL(string: UserDefaults.standard.string(forKey: "backendURL") ?? "https://voiceprompt.invalid/")!
        let configuration = EntraConfiguration(
            tenantID: Bundle.main.object(forInfoDictionaryKey: "ENTRA_TENANT_ID") as? String ?? "",
            clientID: Bundle.main.object(forInfoDictionaryKey: "ENTRA_CLIENT_ID") as? String ?? "",
            redirectURI: "msauth.com.michalmar.voiceprompt.ios://auth",
            apiScope: Bundle.main.object(forInfoDictionaryKey: "ENTRA_API_SCOPE") as? String ?? ""
        )
        let credentials = EntraCredentialProvider(
            configuration: configuration,
            store: KeychainCredentialStore(service: "com.michalmar.voiceprompt.ios")
        )
        self.credentials = credentials
        authorization = EntraAuthorizationCoordinator(configuration: configuration)
        let client = APIClient(baseURL: baseURL, credentials: credentials)
        let queue = try! UploadQueue(directory: support.appending(path: "Uploads"))
        _model = StateObject(wrappedValue: RecordingViewModel(
            recorder: RecordingEngine(directory: support.appending(path: "Recordings")),
            client: client,
            queue: queue
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model) {
                Task { try? await authorization.signIn(using: credentials) }
            }
        }
    }
}
