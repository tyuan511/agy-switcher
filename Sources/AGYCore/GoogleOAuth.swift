import CryptoKit
import Foundation
import Security

typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, Int)

enum GoogleHTTP {
    // Authorization headers and form bodies only go to the configured Google endpoints.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(
        configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil
    )

    static let send: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AGYError.invalidResponse }
        return (data, response.statusCode)
    }
}

struct OAuthAttempt: Sendable {
    static let callbackPath = "/oauth-callback"

    let state: String
    let verifier: String

    init(state: String, verifier: String) {
        self.state = state
        self.verifier = verifier
    }

    init() throws {
        self.init(state: try Self.randomValue(), verifier: try Self.randomValue())
    }

    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw AGYError.keychain(status) }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum Callback: Equatable {
        case code(String)
        case denied
        case invalid
    }

    func callback(requestTarget: String) -> Callback {
        guard requestTarget.hasPrefix(Self.callbackPath + "?"),
              let url = URLComponents(string: requestTarget),
              let query = url.queryItems else { return .invalid }
        let states = query.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { return .invalid }
        if query.contains(where: { $0.name == "error" }) { return .denied }
        let codes = query.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { return .invalid }
        return .code(code)
    }
}

struct GoogleOAuth: Sendable {
    let send: HTTPTransport

    init(send: @escaping HTTPTransport = GoogleHTTP.send) {
        self.send = send
    }

    func authorizationURL(redirect: URL, attempt: OAuthAttempt, email: String?) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "accounts.google.com"
        url.path = "/o/oauth2/v2/auth"
        let scopes = ["cloud-platform", "userinfo.email", "userinfo.profile", "cclog", "experimentsandconfigs", "aicode"]
        url.queryItems = [
            URLQueryItem(name: "client_id", value: AntigravityDesktopClient.id),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: (["openid"] + scopes.map {
                "https://www.googleapis.com/auth/" + $0
            }).joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code_challenge", value: attempt.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let email { url.queryItems?.append(URLQueryItem(name: "login_hint", value: email)) }
        return url.url!
    }

    func exchange(code: String, redirect: URL, attempt: OAuthAttempt) async throws -> AntigravityCredential {
        try await token(fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect.absoluteString,
            "code_verifier": attempt.verifier,
        ], previous: nil)
    }

    func refresh(_ previous: AntigravityCredential) async throws -> AntigravityCredential {
        try await token(fields: [
            "grant_type": "refresh_token",
            "refresh_token": previous.token.refreshToken,
        ], previous: previous)
    }

    func identity(for credential: AntigravityCredential) async throws -> GoogleIdentity {
        struct Profile: Decodable {
            let sub: String
            let email: String
            let name: String?
            let emailVerified: Bool

            enum CodingKeys: String, CodingKey {
                case sub, email, name
                case emailVerified = "email_verified"
            }
        }

        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, timeoutInterval: 15)
        request.setValue("Bearer " + credential.token.accessToken, forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        if status == 401 { throw AGYError.authenticationRequired }
        guard status == 200 else { throw AGYError.serviceRejected(status) }
        guard let profile = try? JSONDecoder().decode(Profile.self, from: data),
              profile.emailVerified, !profile.email.isEmpty, !profile.sub.isEmpty else {
            throw AGYError.invalidResponse
        }
        return GoogleIdentity(id: profile.sub, email: profile.email, name: profile.name)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private func token(fields: [String: String], previous: AntigravityCredential?) async throws -> AntigravityCredential {
        var form = fields
        form["client_id"] = AntigravityDesktopClient.id
        form["client_secret"] = AntigravityDesktopClient.desktopParameter
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Self.formBody(form)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(request)
        struct Failure: Decodable { let error: String }
        if status == 400, let failure = try? JSONDecoder().decode(Failure.self, from: data),
           failure.error == "invalid_grant" {
            throw previous == nil ? AGYError.authorizationDenied : .authenticationRequired
        }
        guard status == 200 else { throw AGYError.serviceRejected(status) }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.accessToken.isEmpty, (1...86_400).contains(token.expiresIn),
              let refreshToken = token.refreshToken ?? previous?.token.refreshToken, !refreshToken.isEmpty else {
            throw AGYError.invalidResponse
        }
        let expiry = Date.now.addingTimeInterval(token.expiresIn)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return AntigravityCredential(
            token: .init(accessToken: token.accessToken, refreshToken: refreshToken, tokenType: "Bearer", expiry: expiry),
            authMethod: "consumer",
            idToken: token.idToken ?? previous?.idToken
        )
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return encodedKey + "=" + encodedValue
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
