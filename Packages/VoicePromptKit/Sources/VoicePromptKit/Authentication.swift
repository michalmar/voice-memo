import Foundation
#if canImport(Security)
import Security

public actor KeychainCredentialStore {
    public struct StoreError: LocalizedError {
        public let status: OSStatus

        public var errorDescription: String? {
            if status == errSecMissingEntitlement {
                #if os(macOS)
                return "VoicePrompt cannot access the sign-in Keychain. Rebuild and install the Mac app with code signing enabled."
                #else
                return "iOS cannot access the sign-in Keychain. Rebuild the simulator app with code signing enabled (ad-hoc signing is sufficient)."
                #endif
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Sign-in Keychain error (\(status)): \(detail)"
        }
    }

    private let service: String
    public init(service: String) { self.service = service }

    public func save(_ value: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    public func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        return value as? Data
    }
    public func clear(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
#endif

#if canImport(AuthenticationServices)
import AuthenticationServices
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct EntraConfiguration: Sendable {
    public let tenantID: String
    public let clientID: String
    public let redirectURI: String
    public let apiScope: String

    public init(tenantID: String, clientID: String, redirectURI: String, apiScope: String) {
        self.tenantID = tenantID
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.apiScope = apiScope
    }

    var authorizationEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/authorize")!
    }

    var tokenEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(tenantID)/oauth2/v2.0/token")!
    }
}

private struct EntraTokens: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct TokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

public actor EntraCredentialProvider: CredentialProvider {
    public enum Error: LocalizedError {
        case signInRequired, invalidTokenResponse
        case authorization(code: String, description: String?)

        public var errorDescription: String? {
            switch self {
            case .signInRequired:
                return "Sign in with Microsoft to upload your saved recordings."
            case .invalidTokenResponse:
                return "Microsoft returned an invalid sign-in response. Please try signing in again."
            case .authorization(let code, let description):
                return "Microsoft sign-in failed (\(code)). \(description ?? "Please try again.")"
            }
        }
    }

    private let configuration: EntraConfiguration
    private let store: KeychainCredentialStore
    private let session: URLSession
    private let account = "entra-tokens"

    public init(
        configuration: EntraConfiguration,
        store: KeychainCredentialStore,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.store = store
        self.session = session
    }

    public func accessToken() async throws -> String {
        guard let data = try await store.read(account: account),
              let tokens = try? JSONDecoder().decode(EntraTokens.self, from: data)
        else { throw Error.signInRequired }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else { throw Error.signInRequired }
        return try await exchange([
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "redirect_uri": configuration.redirectURI,
            "scope": "\(configuration.apiScope) offline_access openid profile",
        ], fallbackRefreshToken: refreshToken).accessToken
    }

    public func exchangeAuthorizationCode(_ code: String, verifier: String) async throws {
        _ = try await exchange([
            "client_id": configuration.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": configuration.redirectURI,
            "scope": "\(configuration.apiScope) offline_access openid profile",
        ])
    }

    public func signOut() async {
        await store.clear(account: account)
    }

    private func exchange(
        _ parameters: [String: String],
        fallbackRefreshToken: String? = nil
    ) async throws -> EntraTokens {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidTokenResponse }
        if !(200..<300).contains(http.statusCode) {
            guard let failure = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) else {
                throw Error.invalidTokenResponse
            }
            if fallbackRefreshToken != nil,
               ["invalid_grant", "interaction_required", "consent_required"].contains(failure.error) {
                throw Error.signInRequired
            }
            throw Error.authorization(code: failure.error, description: failure.errorDescription)
        }
        let value = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !value.accessToken.isEmpty, value.expiresIn > 0 else { throw Error.invalidTokenResponse }
        let tokens = EntraTokens(
            accessToken: value.accessToken,
            refreshToken: value.refreshToken ?? fallbackRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn))
        )
        try await store.save(JSONEncoder().encode(tokens), account: account)
        return tokens
    }
}

// Safari can call this on an XPC queue. Creating the handler outside MainActor
// prevents Swift 6 from asserting main-actor isolation when Objective-C invokes it.
final class AuthorizationCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Swift.Error>?

    init(_ continuation: CheckedContinuation<URL, Swift.Error>) {
        self.continuation = continuation
    }

    var handler: @Sendable (URL?, Swift.Error?) -> Void {
        { [self] url, error in complete(url: url, error: error) }
    }

    func complete(url: URL? = nil, error: Swift.Error? = nil) {
        // A failed start and the system callback may both try to finish.
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        if let pending {
            if let error { pending.resume(throwing: error) }
            else if let url { pending.resume(returning: url) }
            else { pending.resume(throwing: EntraAuthorizationCoordinator.Error.invalidCallback) }
        }
    }
}

@MainActor
public final class EntraAuthorizationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    public enum Error: LocalizedError {
        case invalidCallback, stateMismatch, alreadySigningIn, couldNotStart

        public var errorDescription: String? {
            switch self {
            case .invalidCallback: return "Microsoft sign-in did not return an authorization code."
            case .stateMismatch: return "The sign-in response could not be verified. Please try again."
            case .alreadySigningIn: return "A Microsoft sign-in is already in progress."
            case .couldNotStart: return "The Microsoft sign-in window could not be opened. Please try again."
            }
        }
    }

    private let configuration: EntraConfiguration
    private var webSession: ASWebAuthenticationSession?

    public init(configuration: EntraConfiguration) {
        self.configuration = configuration
    }

    public func signIn(using provider: EntraCredentialProvider) async throws {
        guard webSession == nil else { throw Error.alreadySigningIn }
        defer { webSession = nil }
        let verifier = Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafeString()
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: "\(configuration.apiScope) offline_access openid profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let callbackScheme = URL(string: configuration.redirectURI)?.scheme
        let callback: URL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Swift.Error>) in
            let callback = AuthorizationCallback(continuation)
            let session = ASWebAuthenticationSession(
                url: components.url!, callbackURLScheme: callbackScheme,
                completionHandler: callback.handler
            )
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                callback.complete(error: Error.couldNotStart)
            }
        }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.first(where: { $0.name == "state" })?.value == state else { throw Error.stateMismatch }
        if let error = values.first(where: { $0.name == "error" })?.value {
            throw EntraCredentialProvider.Error.authorization(
                code: error,
                description: values.first(where: { $0.name == "error_description" })?.value
            )
        }
        guard let code = values.first(where: { $0.name == "code" })?.value else { throw Error.invalidCallback }
        try await provider.exchangeAuthorizationCode(code, verifier: verifier)
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
        #endif
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
#endif
