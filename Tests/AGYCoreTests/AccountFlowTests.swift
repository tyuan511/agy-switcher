import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AGYCore

struct AccountFlowTests {
    private let sample = GoogleIdentity(id: "alex", email: "alex@example.com", name: "Alex")

    @Test func automaticQuotaRefreshUsesTheSelectedInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        let lastRefresh = now.addingTimeInterval(-300)

        #expect(QuotaRefreshInterval.fiveMinutes.hasElapsed(since: lastRefresh, at: now))
        #expect(!QuotaRefreshInterval.tenMinutes.hasElapsed(since: lastRefresh, at: now))
        #expect(!QuotaRefreshInterval.fiveMinutes.hasElapsed(since: lastRefresh, at: now.addingTimeInterval(-1)))
        #expect(QuotaRefreshInterval.oneHour.hasElapsed(since: nil, at: now))
    }

    @Test func authorizingAgainUsesGoogleSubjectAndKeepsQuota() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        _ = try await service.saveAuthorization(identity: sample, credential: makeCredential("old"))
        let cached = try await service.refreshQuota(for: sample.id)
        let renamed = GoogleIdentity(id: sample.id, email: "updated@example.com", name: nil)
        _ = try await service.saveAuthorization(identity: renamed, credential: makeCredential("new"))

        let reopened = try await fixture.service().list()
        #expect(reopened == [Account(identity: renamed, quota: cached.quota)])
        #expect(try fixture.credential(sample.id)?.token.refreshToken == "refresh-new")
    }

    @Test func refreshingAnInactiveAccountKeepsClientCredentialsAndCachesResults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        let other = GoogleIdentity(id: "other", email: "other@example.com", name: nil)
        _ = try await service.saveAuthorization(identity: sample, credential: makeCredential("alex"))
        _ = try await service.saveAuthorization(identity: other, credential: makeCredential("other"))
        try await service.switchAccount(to: sample.id)

        let refreshed = try await service.refreshQuota(for: other.id)
        #expect(refreshed.quota?.entries.first?.fraction == 0.75)
        #expect(try await service.activeAccount() == .managed(sample.id))
        #expect(try fixture.system.read().map(ClientCredentials.decode)?.token.refreshToken == "refresh-alex")
        #expect(try fixture.repository.load().first(where: { $0.id == other.id })?.quota == refreshed.quota)
    }

    @Test func refreshingRetriesUnauthorizedQuotaOnceAndSavesRenewedToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let renewals = Mutex(0)
        let quota = Mutex([String]())
        let service = fixture.service(
            oauth: GoogleOAuth { request in
                #expect(request.url?.host == "oauth2.googleapis.com")
                renewals.withLock { $0 += 1 }
                return (Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8), 200)
            },
            send: { request in
                let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
                quota.withLock { $0.append(authorization) }
                if authorization == "Bearer access-old" { return (Data(), 401) }
                return quotaReply(for: request)
            }
        )
        _ = try await service.saveAuthorization(identity: sample, credential: makeCredential("old"))

        _ = try await service.refreshQuota(for: sample.id)
        #expect(renewals.withLock { $0 } == 1)
        #expect(quota.withLock { $0.first } == "Bearer access-old")
        #expect(try fixture.credential(sample.id)?.token.accessToken == "renewed")
        #expect(try fixture.credential(sample.id)?.token.refreshToken == "refresh-old")
    }

    @Test func failedRefreshPreservesLastQuota() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let online = fixture.service()
        _ = try await online.saveAuthorization(identity: sample, credential: makeCredential("one"))
        let refreshed = try await online.refreshQuota(for: sample.id)
        let offline = fixture.service(send: { _ in (Data(), 503) })
        await #expect(throws: AGYError.serviceRejected(503)) {
            try await offline.refreshQuota(for: sample.id)
        }
        #expect(try await offline.list().first?.quota == refreshed.quota)
    }

    @Test func removingAnAccountDoesNotSignClientsOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        let saved = try await service.saveAuthorization(identity: sample, credential: makeCredential("one"))
        try await service.switchAccount(to: saved.id)

        try await service.remove(saved.id)
        #expect(try await service.list().isEmpty)
        #expect(try fixture.credential(saved.id) == nil)
        #expect(try await service.activeAccount() == .unmanaged)
    }
}

struct OAuthAndQuotaTests {
    @Test func pkceAndCallbackMatchOAuthContract() {
        let attempt = OAuthAttempt(state: "test", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(attempt.callback(requestTarget: "/oauth-callback?state=test&code=one%2Btwo") == .code("one+two"))
        #expect(attempt.callback(requestTarget: "/oauth-callback?state=test&error=access_denied") == .denied)
        #expect(attempt.callback(requestTarget: "/oauth-callback?state=other&code=one") == .invalid)
        #expect(attempt.callback(requestTarget: "/oauth-callback?state=test&state=other&code=one") == .invalid)
        #expect(attempt.callback(requestTarget: "/elsewhere?state=test&code=one") == .invalid)
        #expect(String(decoding: GoogleOAuth.formBody(["key": "+%& ?"]), as: UTF8.self) == "key=%2B%25%26%20%3F")
    }

    @Test(arguments: AppLanguage.allCases)
    func callbackResponsePermitsItsEmbeddedStylesheet(language: AppLanguage) throws {
        let code = "sample-callback-code"
        let response = String(decoding: OAuthCallbackPage.response(for: .code(code), language: language), as: UTF8.self)
        let separator = try #require(response.range(of: "\r\n\r\n"))
        let headers = response[..<separator.lowerBound]
        let page = response[separator.upperBound...]
        let start = try #require(page.range(of: "<style>"))
        let end = try #require(page.range(of: "</style>"))
        let stylesheet = page[start.upperBound..<end.lowerBound]
        let hash = Data(SHA256.hash(data: Data(stylesheet.utf8))).base64EncodedString()

        #expect(headers.contains("Content-Security-Policy: default-src 'none'; style-src 'sha256-\(hash)'"))
        #expect(headers.contains("Content-Length: \(page.utf8.count)\r\n"))
        let title = language == .english ? "Google authorization complete" : "Google 授权成功"
        #expect(page.contains("<h1 id=\"title\">\(title)</h1>"))
        #expect(page.contains("<html lang=\"\(language.rawValue)\">"))
        #expect(!page.contains(code))
    }

    @Test func englishErrorsKeepTheirDetails() {
        let language = AppLanguage.english
        let detail = language.errorDescription(AGYError.serviceRejected(503))
        #expect(language.text("切换失败。\(detail)") == "Could not switch accounts. The request failed (HTTP 503).")
        #expect(AppLanguage.simplifiedChinese.text("设置") == "设置")
        #expect(language.text("设置") == "Settings")
    }

    @Test func authorizationExchangesCodeWithPKCEAndReadsVerifiedIdentity() async throws {
        let attempt = OAuthAttempt(state: "state", verifier: "verifier")
        let redirect = try #require(URL(string: "http://127.0.0.1:45678/oauth-callback"))
        let oauth = GoogleOAuth { request in
            switch request.url?.host {
            case "oauth2.googleapis.com":
                let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                #expect(form.contains("code=sample%2Bcode"))
                #expect(form.contains("code_verifier=verifier"))
                return (Data(#"{"access_token":"granted","expires_in":3600,"refresh_token":"offline","id_token":"identity"}"#.utf8), 200)
            case "openidconnect.googleapis.com":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer granted")
                return (Data(#"{"sub":"123","email":"new@example.com","email_verified":true}"#.utf8), 200)
            default: return (Data(), 404)
            }
        }

        let url = oauth.authorizationURL(redirect: redirect, attempt: attempt, email: nil)
        #expect(url.host == "accounts.google.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "code_challenge", value: attempt.challenge)))
        #expect(query.contains(URLQueryItem(name: "state", value: attempt.state)))
        let credential = try await oauth.exchange(code: "sample+code", redirect: redirect, attempt: attempt)
        #expect(credential.token.refreshToken == "offline")
        #expect(credential.idToken == "identity")
        let identity = try await oauth.identity(for: credential)
        #expect(identity.id == "123")
        #expect(identity.email == "new@example.com")
    }

    @Test func quotaUsesGroupWindowsAndProjectFromEntitlement() async throws {
        let client = QuotaClient(version: "2.34.0") { request in
            if request.url?.path.hasSuffix("loadCodeAssist") == false {
                let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
                #expect(body["project"] == "test-project")
            }
            return quotaReply(for: request)
        }
        let quota = try await client.fetch(for: makeCredential("one"))
        #expect(quota.tier == "Pro")
        #expect(!quota.partial)
        #expect(quota.entries.map(\.window) == ["5 小时", "每周"])
        #expect(quota.entries.map(\.fraction) == [0.75, 0])
        #expect(quota.entries.first?.resetsAt != nil)
        #expect(quota.entries.first?.groupName == "Gemini")
    }

    @Test func hubQuotaSummaryKeepsArgonWeeklySeparateFromGemini() async throws {
        let client = QuotaClient(version: "2.34.0") { request in
            guard request.url?.path.hasSuffix("retrieveUserQuotaSummary") == true else {
                return quotaReply(for: request)
            }
            #expect(request.url?.host == "daily-cloudcode-pa.googleapis.com")
            let userAgent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
            #expect(userAgent.hasPrefix("antigravity/hub/2.34.0 darwin/"))
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
            #expect(body["project"] == "test-project")

            return (Data("""
                {"groups":[
                    {"displayName":"Gemini Models","buckets":[
                        {"bucketId":"gemini-weekly","remainingFraction":0.99},
                        {"bucketId":"gemini-5h","remainingFraction":0.96}
                    ]},
                    {"displayName":"Claude and GPT models","buckets":[
                        {"bucketId":"3p-weekly","remainingFraction":1},
                        {"bucketId":"3p-5h","remainingFraction":1}
                    ]},
                    {"displayName":"Gemini 4 Argon","buckets":[
                        {"bucketId":"gemini-argon-wtu-weekly","displayName":"Weekly Limit",
                         "remaining":{"remainingFraction":0.91,"resetTime":"2100-01-01T00:00:00Z"}}
                    ]}
                ]}
                """.utf8), 200)
        }

        let quota = try await client.fetch(for: makeCredential("one"))
        let groups = QuotaGroup.groups(for: quota)
        #expect(groups.map(\.id) == ["gemini", "claude", "argon"])
        #expect(groups.map { $0.entries.map(\.fraction) } == [[0.99, 0.96], [1, 1], [0.91]])
        let argon = try #require(groups.last?.entries.first)
        #expect(argon.windowTitle() == "每周额度")
        #expect(argon.resetsAt == parseTimestamp("2100-01-01T00:00:00Z"))
    }

    @Test func quotaFallsBackToModelsAndPreservesUnknownFractions() async throws {
        let client = QuotaClient(version: "2.34.0") { request in
            if request.url?.path.hasSuffix("retrieveUserQuotaSummary") == true { return (Data(), 403) }
            return quotaReply(for: request)
        }
        let quota = try await client.fetch(for: makeCredential("one"))
        #expect(quota.partial)
        #expect(quota.entries.map(\.id) == ["gemini-test"])
        #expect(quota.entries.first?.fraction == 0.25)
        #expect(QuotaGroup.groups(for: quota).map(\.name) == ["Gemini Test"])
    }

    @Test func groupsCachedBucketsByModelEvenWhenTheirDisplayNamesMatch() throws {
        let data = Data("""
            [
              {"id":"3p:5h","name":"Five Hour Limit Remaining","window":"5 小时","fraction":1},
              {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5 小时","fraction":0.97},
              {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"每周","fraction":1},
              {"id":"gemini:weekly","name":"Weekly Limit Remaining","window":"每周","fraction":0.99},
              {"id":"gemini-argon-wtu-weekly","name":"Weekly Limit Remaining","window":"每周","fraction":0.91}
            ]
            """.utf8)
        let entries = try JSONDecoder().decode([QuotaEntry].self, from: data)
        let snapshot = QuotaSnapshot(entries: entries, updatedAt: .now, tier: nil, partial: false)
        let groups = QuotaGroup.groups(for: snapshot)

        #expect(groups.map(\.id) == ["gemini", "claude", "argon"])
        #expect(groups.map { $0.entries.map(\.fraction) } == [[0.99, 0.97], [1, 1], [0.91]])
        #expect(groups.first?.entries.map { $0.windowTitle() } == ["每周额度", "5 小时额度"])
        let english = QuotaGroup.groups(for: snapshot, language: .english)
        #expect(english.map(\.name) == ["Gemini models", "Claude and GPT models", "Gemini 4 Argon"])
        #expect(english.first?.entries.map { $0.windowTitle(in: .english) } == ["Weekly quota", "5-hour quota"])
    }
}

struct ClientCredentialTests {
    @Test func installationUsesKeychainEnvelopeAndPrivateFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let credential = makeCredential("new")
        try fixture.clients.install(credential)
        let system = try #require(fixture.system.read())
        #expect(system.starts(with: Data("go-keyring-base64:".utf8)))
        #expect(try ClientCredentials.decode(system) == credential)
        for file in [fixture.desktop, fixture.cli] {
            let contents = try file.read()
            let data = try #require(contents)
            #expect(try ClientCredentials.decode(data) == credential)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func partialWriteRestoresPreviousCredentialAndRemovesNewFallback() throws {
        let system = Cell()
        let newFallback = Cell()
        let before = try JSONEncoder().encode(makeCredential("old"))
        system.write(before)
        let clients = ClientCredentials(targets: [
            system.target(keychain: true),
            newFallback.target(),
            .init(keychainEncoding: false, read: { nil }, write: { _ in throw AGYError.keychain(-1) }),
        ])
        #expect(throws: AGYError.keychain(-1)) {
            try clients.install(makeCredential("new"))
        }
        #expect(system.read() == before)
        #expect(newFallback.read() == nil)
    }

    @Test func inconsistentClientsDoNotReportAnActiveAccount() throws {
        let desktop = Cell()
        let cli = Cell()
        desktop.write(try JSONEncoder().encode(makeCredential("one")))
        cli.write(try JSONEncoder().encode(makeCredential("two")))
        let clients = ClientCredentials(targets: [desktop.target(), cli.target()])
        #expect(try clients.activeAccount(knownSubjects: [], matchToken: { _ in "one" }) == .inconsistent)
    }
}

private final class Cell: Sendable {
    private let value = Mutex<Data?>(nil)

    func read() -> Data? { value.withLock { $0 } }
    func write(_ data: Data?) { value.withLock { $0 = data } }

    func target(keychain: Bool = false) -> ClientCredentials.Target {
        .init(keychainEncoding: keychain, read: read, write: write)
    }
}

private final class Fixture: Sendable {
    let root: URL
    let system = Cell()
    let vault = Mutex<[String: Data]>([:])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    var desktop: SecretFile { SecretFile(url: root.appendingPathComponent("desktop-token")) }
    var cli: SecretFile { SecretFile(url: root.appendingPathComponent("cli/token")) }

    var clients: ClientCredentials {
        ClientCredentials(targets: [
            system.target(keychain: true),
            .init(keychainEncoding: false, read: desktop.read, write: desktop.write),
            .init(keychainEncoding: false, read: cli.read, write: cli.write),
        ])
    }

    func service(oauth: GoogleOAuth = .init(), send: @escaping HTTPTransport = quotaReply) -> AccountService {
        AccountService(repository: repository, vault: .init(
            read: { id in self.vault.withLock { $0[id] } },
            write: { data, id in self.vault.withLock { $0[id] = data } }
        ), clients: clients, oauth: oauth, quota: QuotaClient(version: "2.34.0", send: send))
    }

    var repository: AccountRepository { .init(directory: root.appendingPathComponent("accounts")) }

    func credential(_ id: String) throws -> AntigravityCredential? {
        try vault.withLock { $0[id] }.map(ClientCredentials.decode)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func makeCredential(_ id: String) -> AntigravityCredential {
    .init(token: .init(accessToken: "access-" + id, refreshToken: "refresh-" + id,
                       tokenType: "Bearer", expiry: "2100-01-01T00:00:00.123456Z"),
          authMethod: "consumer", idToken: nil)
}

private func quotaReply(for request: URLRequest) -> (Data, Int) {
    let response: String
    switch request.url?.path.split(separator: ":").last {
    case "loadCodeAssist":
        response = #"{"cloudaicompanionProject":{"id":"test-project"},"paidTier":{"id":"g1-pro-tier"}}"#
    case "retrieveUserQuotaSummary":
        response = """
            {"groups":[{"displayName":"Gemini","buckets":[
                {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2100-01-01T00:00:00Z"},
                {"bucketId":"gemini-weekly","remainingFraction":0}
            ]}]}
            """
    case "fetchAvailableModels":
        response = """
            {"models":{
                "gemini-test":{"displayName":"Gemini Test","quotaInfo":{"remainingFraction":0.25}},
                "gemini-unknown":{"displayName":"Unknown","quotaInfo":{}}
            }}
            """
    default: return (Data(), 404)
    }
    return (Data(response.utf8), 200)
}
