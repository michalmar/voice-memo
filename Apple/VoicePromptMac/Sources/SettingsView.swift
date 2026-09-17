import ApplicationServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var synchronizer: CompletionSynchronizer
    @ObservedObject var shortcut: GlobalShortcutManager
    @AppStorage("backendURL") private var backendURL =
        Bundle.main.object(forInfoDictionaryKey: "BACKEND_URL") as? String ?? "https://voiceprompt.invalid/"
    @AppStorage("pasteQuickTranscription") private var pasteQuickTranscription = true
    @AppStorage(QuickTranscriptionDefaults.refinementInstructions)
    private var refinementInstructions = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Quick Transcription") {
                Toggle(
                    "Enable global shortcut",
                    isOn: Binding(
                        get: { shortcut.isEnabled },
                        set: { shortcut.setEnabled($0) }
                    )
                )
                LabeledContent("Shortcut") {
                    ShortcutRecorder(manager: shortcut)
                        .disabled(!shortcut.isEnabled)
                }
                Toggle("Paste text into the active app", isOn: $pasteQuickTranscription)
                if pasteQuickTranscription {
                    LabeledContent(
                        "Accessibility access",
                        value: accessibilityTrusted ? "Granted" : "Required"
                    )
                    if !accessibilityTrusted {
                        HStack {
                            Button("Request Access") {
                                requestAccessibilityAccess()
                            }
                            Button("Open System Settings") {
                                openAccessibilitySettings()
                            }
                        }
                        Text("If System Settings shows VoicePrompt enabled while access is still required, remove the old VoicePrompt entry and add ~/Applications/VoicePromptMac.app again. This can happen after replacing an ad-hoc signed build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("When enabled and Accessibility access is granted, VoicePrompt returns to the app that was active when recording started and inserts the transcription at the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Click the shortcut, then press at least two modifier keys and another key. Stop releases the microphone before transcription, so you can immediately start another recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = shortcut.registrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Luna Refinement") {
                Text("These optional instructions are added to VoicePrompt's built-in refinement prompt for Mac quick transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $refinementInstructions)
                        .font(.body)
                        .padding(4)
                    if refinementInstructions.isEmpty {
                        Text("For example: Use concise bullet points and preserve code exactly.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                }
                HStack {
                    Text("Leave empty to use the built-in refinement prompt unchanged.")
                    Spacer()
                    Text(
                        "\(refinementInstructions.unicodeScalars.count)/\(QuickTranscriptionDefaults.maximumRefinementInstructionLength)"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .onChange(of: refinementInstructions) { _, value in
                    let limited = String(
                        value.unicodeScalars.prefix(
                            QuickTranscriptionDefaults.maximumRefinementInstructionLength
                        )
                    )
                    if limited != value {
                        refinementInstructions = limited
                    }
                }
            }

            Section("Connection") {
                TextField("Backend URL", text: $backendURL)
                Text("Restart VoicePrompt after changing the backend URL.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Connection", value: synchronizer.status)
                LabeledContent("Microsoft account", value: synchronizer.isSignedIn ? "Signed in on this Mac" : "Not signed in on this Mac")
                if synchronizer.isSignedIn {
                    LabeledContent("Live updates", value: synchronizer.liveConnected ? "Connected" : "Reconnecting; history refreshes every minute")
                }
                if let error = synchronizer.lastError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = synchronizer.liveError {
                    Text("Live updates: \(error)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                if let error = launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if synchronizer.isSignedIn {
                    Button("Sign Out", role: .destructive) {
                        Task { await synchronizer.signOut() }
                    }
                } else {
                    Button("Sign in with Microsoft") {
                        Task { await synchronizer.signIn() }
                    }
                    .disabled(synchronizer.isSigningIn)
                }
                Button("Sync Now") { Task { await synchronizer.reconcile() } }
                    .disabled(synchronizer.isSyncing || synchronizer.isSigningIn)
            }
        }
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
        ) { _ in
            refreshAccessibilityStatus()
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 560)
    }

    private func refreshAccessibilityStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
