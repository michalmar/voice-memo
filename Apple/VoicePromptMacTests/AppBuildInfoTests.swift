import Foundation
import Testing
@testable import VoicePromptMac

struct AppBuildInfoTests {
    @Test func displaysVersionAndBuildFromBundleMetadata() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "2.3.1",
            "CFBundleVersion": "47",
        ])
        #expect(info.version == "2.3.1")
        #expect(info.build == "47")
        #expect(info.displayText == "Version 2.3.1 (Build 47)")
    }

    @Test func trimsMetadataWhitespace() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.0\n",
            "CFBundleVersion": "\t12 ",
        ])
        #expect(info.displayText == "Version 1.0 (Build 12)")
    }

    @Test func missingOrInvalidMetadataIsExplicitlyUnavailable() {
        for dictionary: [String: Any] in [
            [:],
            ["CFBundleShortVersionString": "", "CFBundleVersion": " \n"],
            ["CFBundleShortVersionString": 1, "CFBundleVersion": 42],
        ] {
            let info = AppBuildInfo(infoDictionary: dictionary)
            #expect(info.displayText == "Version Unavailable (Build Unavailable)")
        }
    }

    @Test func missingBuildDoesNotHideKnownVersion() {
        let info = AppBuildInfo(infoDictionary: ["CFBundleShortVersionString": "1.0"])
        #expect(info.displayText == "Version 1.0 (Build Unavailable)")
    }

    @Test func currentAppHasResolvedVersionAndBuildMetadata() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(!version.isEmpty && !version.contains("$("))
        #expect(!build.isEmpty && !build.contains("$("))
        #expect(AppBuildInfo.current.version == version)
        #expect(AppBuildInfo.current.build == build)
    }
}
