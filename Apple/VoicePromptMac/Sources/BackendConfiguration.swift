import Foundation

enum BackendConfiguration {
    static func resolve(bundledURL: String, defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: "backendURL") else { return bundledURL }
        let value = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || URL(string: value)?.host?.lowercased() == "voiceprompt.invalid" {
            defaults.removeObject(forKey: "backendURL")
            return bundledURL
        }
        return value
    }
}
