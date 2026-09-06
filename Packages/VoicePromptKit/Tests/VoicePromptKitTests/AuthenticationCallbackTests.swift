#if canImport(AuthenticationServices)
import Foundation
import Testing
@testable import VoicePromptKit

@MainActor
@Test func authorizationCallbackCanArriveOffTheMainActor() async throws {
    let expected = URL(string: "voiceprompt-test://auth?code=test-code")!
    let result: URL = try await withCheckedThrowingContinuation { continuation in
        let callback = AuthorizationCallback(continuation)
        let handler = callback.handler
        Task.detached {
            handler(expected, nil)
        }
    }
    #expect(result == expected)
}

@MainActor
@Test func authorizationStartFailureAndCallbackResumeOnlyOnce() async {
    await #expect(throws: EntraAuthorizationCoordinator.Error.couldNotStart) {
        let _: URL = try await withCheckedThrowingContinuation { continuation in
            let callback = AuthorizationCallback(continuation)
            callback.complete(error: EntraAuthorizationCoordinator.Error.couldNotStart)
            Task.detached {
                callback.handler(URL(string: "voiceprompt-test://auth"), nil)
            }
        }
    }
}

@Test func emptyAuthorizationCallbackSurfacesAnError() async {
    await #expect(throws: EntraAuthorizationCoordinator.Error.invalidCallback) {
        let _: URL = try await withCheckedThrowingContinuation { continuation in
            AuthorizationCallback(continuation).handler(nil, nil)
        }
    }
}
#endif
