import SwiftUI
import VoicePromptKit

@main
struct VoicePromptIOSApp: App {
    @State private var startup: Result<RecordingViewModel, Error>
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseURL = URL(string:
            UserDefaults.standard.string(forKey: "backendURL")
                ?? Bundle.main.object(forInfoDictionaryKey: "BACKEND_URL") as? String
                ?? "https://voiceprompt.invalid/"
        )!
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
        let authorization = EntraAuthorizationCoordinator(configuration: configuration)
        let client = APIClient(baseURL: baseURL, credentials: credentials)
        let recordingsDirectory = support.appending(path: "Recordings")
        _startup = State(initialValue: Result {
            let queue = try UploadQueue(
                directory: support.appending(path: "Uploads"),
                recordingsDirectory: recordingsDirectory
            )
            return RecordingViewModel(
                recorder: RecordingEngine(directory: recordingsDirectory),
                client: client,
                queue: queue,
                credentials: credentials,
                signIn: { try await authorization.signIn(using: credentials) },
                signOut: { await credentials.signOut() }
            )
        })
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case .success(let model):
                ContentView(model: model)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task {
                                await model.restoreAuthentication()
                                await model.transcriptLibrary.refresh()
                            }
                        }
                    }
            case .failure(let error):
                ContentUnavailableView(
                    "Saved recordings need attention",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The upload queue could not be opened: \(error.localizedDescription) Your recordings have not been deleted.")
                )
            }
        }
    }
}
