import Foundation

enum AGYError: LocalizedError, Equatable {
    case authenticationRequired
    case authorizationDenied
    case authorizationTimedOut
    case browserUnavailable
    case invalidResponse
    case differentAccount
    case noQuota
    case serviceRejected(Int)
    case keychain(Int32)
    case unsupportedCredential
    case credentialChanged
    case switchVerification
    case switchRecoveryFailed
    case antigravityApplicationUnavailable
    case antigravityQuitFailed
    case antigravityQuitTimedOut
    case antigravityLaunchFailed

    var errorDescription: String? { description(in: .simplifiedChinese) }

    func description(in language: AppLanguage) -> String {
        switch self {
        case .authenticationRequired: language.text("Google 授权已失效，请重新授权。")
        case .authorizationDenied: language.text("Google 授权未完成。")
        case .authorizationTimedOut: language.text("等待 Google 授权超时。")
        case .browserUnavailable: language.text("无法打开默认浏览器。")
        case .invalidResponse: language.text("服务返回的数据无法识别。")
        case .differentAccount: language.text("你登录的是另一个 Google 账号。请重试并选择原账号。")
        case .noQuota: language.text("服务暂未返回可用的配额。")
        case .serviceRejected(let status): language.text("服务请求失败（HTTP \(String(status))）。")
        case .keychain(let status): language.text("无法访问钥匙串（\(String(status))）。")
        case .unsupportedCredential: language.text("检测到非个人账号凭据或未知的凭据格式。")
        case .credentialChanged: language.text("客户端凭据刚刚发生变化，请重试。")
        case .switchVerification: language.text("写入后的客户端凭据验证失败。")
        case .switchRecoveryFailed: language.text("切换中断，部分客户端凭据未能恢复。请重新切换或在客户端重新登录。")
        case .antigravityApplicationUnavailable: language.text("找不到 Antigravity 的应用位置。")
        case .antigravityQuitFailed: language.text("无法请求 Antigravity 退出。")
        case .antigravityQuitTimedOut: language.text("等待 Antigravity 退出超时。")
        case .antigravityLaunchFailed: language.text("Antigravity 的新进程未能启动。")
        }
    }
}

struct GoogleIdentity: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String?
}

struct Account: Codable, Equatable, Identifiable, Sendable {
    var identity: GoogleIdentity
    var quota: QuotaSnapshot?

    var id: String { identity.id }
}

struct QuotaSnapshot: Codable, Equatable, Sendable {
    let entries: [QuotaEntry]
    let updatedAt: Date
    let tier: String?
    let partial: Bool
}

enum QuotaRefreshInterval: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60

    var seconds: Int { rawValue * 60 }

    func hasElapsed(since lastRefresh: Date?, at now: Date) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= TimeInterval(seconds)
    }
}

struct QuotaEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let window: String?
    let fraction: Double
    let resetsAt: Date?
    var groupName: String? = nil
}

enum ActiveAccount: Equatable, Sendable {
    case unknown
    case signedOut
    case managed(String)
    case unmanaged
    case inconsistent
}

struct AntigravityCredential: Codable, Equatable, Sendable {
    struct Token: Codable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let expiry: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiry
        }

        var expiresAt: Date? { parseTimestamp(expiry) }
    }

    let token: Token
    let authMethod: String
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authMethod = "auth_method"
        case idToken = "id_token"
    }

    // A hint for matching locally stored credentials after another client rotates its token.
    var subject: String? {
        guard let part = idToken?.split(separator: ".").dropFirst().first else { return nil }
        var encoded = part.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        struct Claims: Decodable { let sub: String }
        return try? JSONDecoder().decode(Claims.self, from: data).sub
    }

    func matches(_ other: Self) -> Bool {
        if let subject, let otherSubject = other.subject {
            return subject == otherSubject
        }
        return !token.refreshToken.isEmpty && token.refreshToken == other.token.refreshToken
    }
}

func parseTimestamp(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}
