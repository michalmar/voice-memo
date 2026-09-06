import Foundation
#if canImport(Security)
import Security

public actor KeychainCredentialStore {
    private let service: String
    public init(service: String) { self.service = service }

    public func save(_ value: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw CocoaError(.fileWriteNoPermission)
        }
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
        guard status == errSecSuccess else { throw CocoaError(.fileReadNoPermission) }
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

public actor EntraCredentialProvider: CredentialProvider {
    public enum Error: Swift.Error { case signInRequired, invalidTokenResponse }

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
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let value = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw Error.invalidTokenResponse }
        let tokens = EntraTokens(
            accessToken: value.accessToken,
            refreshToken: value.refreshToken ?? fallbackRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn))
        )
        try await store.save(JSONEncoder().encode(tokens), account: account)
        return tokens
    }
}

@MainActor
public final class EntraAuthorizationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    public enum Error: Swift.Error { case invalidCallback, stateMismatch }

    private let configuration: EntraConfiguration
    private var webSession: ASWebAuthenticationSession?

    public init(configuration: EntraConfiguration) {
        self.configuration = configuration
    }

    public func signIn(using provider: EntraCredentialProvider) async throws {
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
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: callbackScheme) {
                url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: Error.invalidCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            session.start()
        }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.first(where: { $0.name == "state" })?.value == state else { throw Error.stateMismatch }
        guard let code = values.first(where: { $0.name == "code" })?.value else { throw Error.invalidCallback }
        try await provider.exchangeAuthorizationCode(code, verifier: verifier)
        webSession = nil
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
