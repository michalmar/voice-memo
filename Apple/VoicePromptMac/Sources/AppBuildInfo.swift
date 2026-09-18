import Foundation

struct AppBuildInfo: Sendable {
    static let current = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let build: String

    var displayText: String {
        "Version \(version) (Build \(build))"
    }

    init(infoDictionary: [String: Any]) {
        version = Self.metadataValue(infoDictionary["CFBundleShortVersionString"])
        build = Self.metadataValue(infoDictionary["CFBundleVersion"])
    }

    private static func metadataValue(_ value: Any?) -> String {
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unavailable"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
