import CryptoKit
import Foundation
import Security
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
        let cached = try await service.refreshQuota(for: sample.id, interaction: .allowed)
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

        let refreshed = try await service.refreshQuota(for: other.id, interaction: .allowed)
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
        let vaultAccesses = Mutex([KeychainInteraction]())
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
            },
            vaultAccess: { interaction in vaultAccesses.withLock { $0.append(interaction) } }
        )
        _ = try await service.saveAuthorization(identity: sample, credential: makeCredential("old"))
        vaultAccesses.withLock { $0.removeAll() }

        _ = try await service.refreshQuota(for: sample.id, interaction: .disallowed)
        #expect(renewals.withLock { $0 } == 1)
        #expect(quota.withLock { $0.first } == "Bearer access-old")
        let accesses = vaultAccesses.withLock { $0 }
        #expect(!accesses.isEmpty && accesses.allSatisfy { $0 == .disallowed })
        #expect(try fixture.credential(sample.id)?.token.accessToken == "renewed")
        #expect(try fixture.credential(sample.id)?.token.refreshToken == "refresh-old")
    }

    @Test func failedRefreshPreservesLastQuota() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let online = fixture.service()
        _ = try await online.saveAuthorization(identity: sample, credential: makeCredential("one"))
        let refreshed = try await online.refreshQuota(for: sample.id, interaction: .allowed)
        let offline = fixture.service(send: { _ in (Data(), 503) })
        await #expect(throws: AGYError.serviceRejected(503)) {
            try await offline.refreshQuota(for: sample.id, interaction: .allowed)
        }
        #expect(try await offline.list().first?.quota == refreshed.quota)
    }

    @Test func lockedKeychainDefersAutomaticQuotaRefreshAndAllowsManualRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let initial = fixture.service()
        _ = try await initial.saveAuthorization(identity: sample, credential: makeCredential("one"))
        let cached = try await initial.refreshQuota(for: sample.id, interaction: .allowed)
        let locked = fixture.service(vaultAccess: { interaction in
            if interaction == .disallowed { throw AGYError.keychainInteractionRequired }
        })

        await #expect(throws: AGYError.keychainInteractionRequired) {
            try await locked.refreshQuota(for: sample.id, interaction: .disallowed)
        }
        #expect(try await locked.list().first?.quota == cached.quota)
        let refreshed = try await locked.refreshQuota(for: sample.id, interaction: .allowed)
        #expect(refreshed.quota?.entries == cached.quota?.entries)
    }

    @Test func activeAccountIsUnknownWhenLegacyCredentialNeedsKeychainPermission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let initial = fixture.service()
        _ = try await initial.saveAuthorization(identity: sample, credential: makeCredential("one"))
        try await initial.switchAccount(to: sample.id)
        let locked = fixture.service(vaultAccess: { interaction in
            #expect(interaction == .disallowed)
            throw AGYError.keychainInteractionRequired
        })

        #expect(try await locked.activeAccount() == .unknown)
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

    @Test func backupExportsAnEncryptedFileAndRestoresAccountsOnAnotherService() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let origin = fixture.service()
        _ = try await origin.saveAuthorization(identity: sample, credential: makeCredential("alex"))
        let other = GoogleIdentity(id: "other", email: "other@example.com", name: nil)
        _ = try await origin.saveAuthorization(identity: other, credential: makeCredential("other"))

        let url = fixture.root.appendingPathComponent("backup.\(AccountBackup.fileExtension)")
        let count = try await origin.exportBackup(to: url, passphrase: "open sesame")
        #expect(count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        let contents = try Data(contentsOf: url)
        #expect(!String(decoding: contents, as: UTF8.self).contains("refresh-alex"))
        let entries = try AccountBackup.read(contents, passphrase: "open sesame")
        #expect(entries.map(\.identity) == [sample, other])

        // Simulate a different machine with its own account directory and credential vault.
        let restoredVault = Mutex<[String: Data]>([:])
        let target = AccountService(
            repository: .init(directory: fixture.root.appendingPathComponent("other-machine/accounts")),
            vault: .init(
                read: { id, _ in restoredVault.withLock { $0[id] } },
                write: { data, id, _ in restoredVault.withLock { $0[id] = data } }
            ),
            clients: fixture.clients,
            quota: QuotaClient(version: "2.34.0", send: quotaReply)
        )
        let summary = try await target.importBackup(contents, passphrase: "open sesame")
        #expect(summary == BackupImportSummary(imported: 2, skipped: 0))
        let originAccounts = try await origin.list()
        #expect(try await target.list() == originAccounts)
        #expect(try fixture.credential("alex")?.token.refreshToken == "refresh-alex")
        #expect(try fixture.credential("other")?.token.refreshToken == "refresh-other")
    }

    @Test func importingTwiceSkipsExistingAccountsAndRejectsWrongPassphrase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entries = [BackupAccount(identity: sample, credential: makeCredential("backup"), quota: nil)]
        let contents = try AccountBackup.write(entries, passphrase: "open sesame")

        let target = fixture.service()
        let first = try await target.importBackup(contents, passphrase: "open sesame")
        #expect(first == BackupImportSummary(imported: 1, skipped: 0))
        let second = try await target.importBackup(contents, passphrase: "open sesame")
        #expect(second == BackupImportSummary(imported: 0, skipped: 1))
        #expect(try fixture.credential("alex")?.token.refreshToken == "refresh-backup")

        await #expect(throws: AGYError.invalidBackup) {
            _ = try await target.importBackup(contents, passphrase: "wrong passphrase")
        }
    }

    @Test func importRestoresLostCredentialsWithoutDuplicatingTheAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = fixture.service()
        _ = try await target.saveAuthorization(identity: sample, credential: makeCredential("temporary"))
        fixture.vault.withLock { $0[sample.id] = nil }

        let entries = [BackupAccount(identity: sample, credential: makeCredential("restored"), quota: nil)]
        let contents = try AccountBackup.write(entries, passphrase: "open sesame")
        let summary = try await target.importBackup(contents, passphrase: "open sesame")
        #expect(summary == BackupImportSummary(imported: 1, skipped: 0))
        #expect(try await target.list().map(\.id) == [sample.id])
        #expect(try fixture.credential(sample.id)?.token.refreshToken == "refresh-restored")
    }

    @Test func emptyBackupsAreRejectedOnExportAndImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        await #expect(throws: AGYError.emptyBackup) {
            _ = try await service.exportBackup(
                to: fixture.root.appendingPathComponent("empty.\(AccountBackup.fileExtension)"),
                passphrase: "open sesame"
            )
        }
        let contents = try AccountBackup.write([], passphrase: "open sesame")
        await #expect(throws: AGYError.emptyBackup) {
            _ = try await service.importBackup(contents, passphrase: "open sesame")
        }
    }
}

struct AccountBackupTests {
    private let sample = GoogleIdentity(id: "alex", email: "alex@example.com", name: "Alex")
    private let passphrase = "open sesame"

    @Test func roundTripsAccountsAndNeverStoresPlaintextCredentials() throws {
        let entries = [BackupAccount(identity: sample, credential: makeCredential("alex"), quota: nil)]
        let file = try AccountBackup.write(entries, passphrase: passphrase)
        #expect(!String(decoding: file, as: UTF8.self).contains("refresh-alex"))
        #expect(try AccountBackup.read(file, passphrase: passphrase) == entries)
    }

    @Test func rejectsWrongPassphrasesUnrecognizedFilesAndTampering() throws {
        let entries = [BackupAccount(identity: sample, credential: makeCredential("alex"), quota: nil)]
        let file = try AccountBackup.write(entries, passphrase: passphrase)
        #expect(throws: AGYError.invalidBackup) {
            _ = try AccountBackup.read(file, passphrase: "wrong passphrase")
        }
        #expect(throws: AGYError.invalidBackup) {
            _ = try AccountBackup.read(Data(#"{"format":"something.else"}"#.utf8), passphrase: passphrase)
        }

        var object = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        object["format"] = "something.else"
        object["version"] = 99
        object["iterations"] = 500_000_000
        #expect(throws: AGYError.invalidBackup) {
            _ = try AccountBackup.read(try JSONSerialization.data(withJSONObject: object), passphrase: passphrase)
        }

        object = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        let payload = try #require(Data(base64Encoded: object["payload"] as? String ?? ""))
        var tampered = payload
        tampered[payload.count - 1] ^= 0xFF
        object["payload"] = tampered.base64EncodedString()
        #expect(throws: AGYError.invalidBackup) {
            _ = try AccountBackup.read(try JSONSerialization.data(withJSONObject: object), passphrase: passphrase)
        }
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
    @Test(arguments: [false, true])
    func installationUsesKeychainEnvelopeAndPrivateFiles(existingCredentials: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        if existingCredentials {
            let previous = try JSONEncoder().encode(makeCredential("old"))
            try fixture.desktop.write(previous)
            try fixture.cli.write(previous)
        }
        let credential = makeCredential("new", subject: "new-account")
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
        #expect(try fixture.clients.activeAccount(knownSubjects: ["new-account"], matchToken: { _ in nil }) == .managed("new-account"))
    }

    @Test func partialWriteRestoresPreviousCredentialAndRemovesNewFallback() throws {
        let system = Cell()
        let newFallback = Cell()
        let before = try JSONEncoder().encode(makeCredential("old"))
        system.write(before)
        let clients = ClientCredentials(targets: [
            system.target(keychain: true),
            newFallback.target(),
            .init(keychainEncoding: false, read: { _ in nil }, write: { _ in throw AGYError.keychain(-1) }),
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

    @Test(arguments: [true, false])
    func identifiesTheKnownClientWhenTheSharedKeychainIsLockedOrLacksASubject(locked: Bool) throws {
        let encoder = JSONEncoder()
        let shared = try encoder.encode(makeCredential("same"))
        let cli = Cell()
        cli.write(try encoder.encode(makeCredential("same", subject: "alex")))
        let clients = ClientCredentials(targets: [
            .init(keychainEncoding: true, read: { interaction in
                #expect(interaction == .disallowed)
                if locked { throw AGYError.keychainInteractionRequired }
                return shared
            }, write: { _ in }),
            cli.target(),
        ])

        let account = try clients.activeAccount(knownSubjects: ["alex"]) { _ in
            Issue.record("A known subject should be enough to identify the account.")
            return nil
        }
        #expect(account == .managed("alex"))
    }

    @Test func differentClientSubjectsRemainInconsistentWhenAThirdCredentialLacksASubject() throws {
        let encoder = JSONEncoder()
        let shared = Cell()
        let desktop = Cell()
        let cli = Cell()
        shared.write(try encoder.encode(makeCredential("same")))
        desktop.write(try encoder.encode(makeCredential("same", subject: "alex")))
        cli.write(try encoder.encode(makeCredential("same", subject: "other")))
        let clients = ClientCredentials(targets: [shared.target(keychain: true), desktop.target(), cli.target()])

        #expect(try clients.activeAccount(knownSubjects: ["alex", "other"], matchToken: { _ in "alex" }) == .inconsistent)
    }

    @Test func sharedKeychainNeverPromptsDuringStatusReadOrSwitch() throws {
        let system = Cell()
        let clients = ClientCredentials(targets: [
            .init(keychainEncoding: true, read: { interaction in
                #expect(interaction == .disallowed)
                throw AGYError.keychainInteractionRequired
            }, write: system.write),
        ])

        #expect(throws: AGYError.keychainInteractionRequired) {
            try clients.activeAccount(knownSubjects: [], matchToken: { _ in nil })
        }
        try clients.install(makeCredential("new"))
        #expect(try system.read().map(ClientCredentials.decode)?.token.refreshToken == "refresh-new")
    }

    @Test func installationReadsSharedKeychainAtMostOnceAndSkipsItForUnsupportedLocalCredentials() throws {
        let system = Cell()
        let desktop = Cell()
        let reads = Mutex(0)
        let clients = ClientCredentials(targets: [
            .init(keychainEncoding: true, read: { _ in
                reads.withLock { $0 += 1 }
                return system.read()
            }, write: system.write),
            desktop.target(),
        ])

        try clients.install(makeCredential("first"))
        #expect(reads.withLock { $0 } == 1)

        desktop.write(Data(#"{"token":{"access_token":"a","refresh_token":"r","token_type":"Bearer","expiry":"2100-01-01T00:00:00Z"},"auth_method":"enterprise"}"#.utf8))
        reads.withLock { $0 = 0 }
        #expect(throws: AGYError.unsupportedCredential) {
            try clients.install(makeCredential("second"))
        }
        #expect(reads.withLock { $0 } == 0)
    }

    @Test func encryptedVaultUsesSingleCachedMasterKeyAndMigratesLegacyItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let keyEntries = Mutex<[String: Data]>([:])
        let keyReads = Mutex(0)
        let keyWrites = Mutex(0)
        let keyStore = EncryptedCredentialVault.KeyStore(
            read: { account, _ in
                keyReads.withLock { $0 += 1 }
                return keyEntries.withLock { $0[account] }
            },
            write: { data, account, _ in
                keyWrites.withLock { $0 += 1 }
                keyEntries.withLock { $0[account] = data }
            }
        )

        let legacyEntries = Mutex<[String: Data]>(["legacy-user": Data("secret-legacy-token".utf8)])
        let legacyStore = EncryptedCredentialVault.KeyStore(
            read: { account, _ in legacyEntries.withLock { $0[account] } },
            write: { data, account, _ in legacyEntries.withLock { $0[account] = data } }
        )

        let vault = EncryptedCredentialVault(directory: root, keyStore: keyStore, legacyStore: legacyStore)
        let migrated = try vault.read("legacy-user", interaction: .allowed)
        #expect(migrated == Data("secret-legacy-token".utf8))
        #expect(legacyEntries.withLock { $0["legacy-user"] } == nil)
        #expect(keyEntries.withLock { $0.keys.sorted() } == ["master-key"])

        try vault.write(Data("secret-second-token".utf8), account: "second-user", interaction: .allowed)
        #expect(keyWrites.withLock { $0 } == 1)
        #expect(keyReads.withLock { $0 } == 1)

        let fileURL = root.appendingPathComponent("credentials.enc")
        let encryptedBytes = try Data(contentsOf: fileURL)
        #expect(!String(decoding: encryptedBytes, as: UTF8.self).contains("secret-second-token"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        // Simulate app relaunch: reading two accounts should only read the master key once.
        keyReads.withLock { $0 = 0 }
        let reopened = EncryptedCredentialVault(directory: root, keyStore: keyStore, legacyStore: legacyStore)
        #expect(try reopened.read("legacy-user", interaction: .disallowed) == Data("secret-legacy-token".utf8))
        #expect(try reopened.read("second-user", interaction: .disallowed) == Data("secret-second-token".utf8))
        #expect(keyReads.withLock { $0 } == 1)

        try reopened.write(nil, account: "legacy-user", interaction: .allowed)
        try reopened.write(nil, account: "second-user", interaction: .allowed)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func migratingMasterKeyStoreMigratesLegacyKeyAndFallsBackWhenUnentitled() throws {
        let primaryEntries = Mutex<[String: Data]>([:])
        let fallbackEntries = Mutex<[String: Data]>(["master-key": Data(repeating: 7, count: 32)])
        let primary = EncryptedCredentialVault.KeyStore(
            read: { account, _ in primaryEntries.withLock { $0[account] } },
            write: { data, account, _ in primaryEntries.withLock { $0[account] = data } }
        )
        let fallback = EncryptedCredentialVault.KeyStore(
            read: { account, _ in fallbackEntries.withLock { $0[account] } },
            write: { data, account, _ in fallbackEntries.withLock { $0[account] = data } }
        )
        let store = EncryptedCredentialVault.KeyStore.migrating(primary: primary, fallback: fallback)

        let migrated = try store.read("master-key", .allowed)
        #expect(migrated == Data(repeating: 7, count: 32))
        #expect(primaryEntries.withLock { $0["master-key"] } == Data(repeating: 7, count: 32))
        #expect(fallbackEntries.withLock { $0["master-key"] } == Data(repeating: 7, count: 32))

        // Unentitled primary falls back transparently on both write and read.
        let unentitledPrimary = EncryptedCredentialVault.KeyStore(
            read: { _, _ in throw AGYError.keychain(errSecMissingEntitlement) },
            write: { _, _, _ in throw AGYError.keychain(errSecMissingEntitlement) }
        )
        let unentitledStore = EncryptedCredentialVault.KeyStore.migrating(primary: unentitledPrimary, fallback: fallback)
        try unentitledStore.write(Data(repeating: 9, count: 32), "master-key", .allowed)
        #expect(try unentitledStore.read("master-key", .disallowed) == Data(repeating: 9, count: 32))
    }
}

private final class Cell: Sendable {
    private let value = Mutex<Data?>(nil)

    func read() -> Data? { value.withLock { $0 } }
    func write(_ data: Data?) { value.withLock { $0 = data } }

    func target(keychain: Bool = false) -> ClientCredentials.Target {
        .init(keychainEncoding: keychain, read: { _ in self.read() }, write: write)
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

    var desktop: SecretFile { SecretFile(url: root.appendingPathComponent(".gemini/jetski-standalone-oauth-token")) }
    var cli: SecretFile { SecretFile(url: root.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")) }

    var clients: ClientCredentials {
        ClientCredentials(home: root, sharedKeychain: system.target(keychain: true))
    }

    func service(
        oauth: GoogleOAuth = .init(), send: @escaping HTTPTransport = quotaReply,
        vaultAccess: @escaping @Sendable (KeychainInteraction) throws -> Void = { _ in }
    ) -> AccountService {
        AccountService(repository: repository, vault: .init(
            read: { id, interaction in
                try vaultAccess(interaction)
                return self.vault.withLock { $0[id] }
            },
            write: { data, id, interaction in
                try vaultAccess(interaction)
                self.vault.withLock { $0[id] = data }
            }
        ), clients: clients, oauth: oauth, quota: QuotaClient(version: "2.34.0", send: send))
    }

    var repository: AccountRepository { .init(directory: root.appendingPathComponent("accounts")) }

    func credential(_ id: String) throws -> AntigravityCredential? {
        try vault.withLock { $0[id] }.map(ClientCredentials.decode)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func makeCredential(_ id: String, subject: String? = nil) -> AntigravityCredential {
    let idToken = subject.map {
        let claims = Data("{\"sub\":\"\($0)\"}".utf8).base64EncodedString()
        return "header.\(claims).signature"
    }
    return .init(token: .init(accessToken: "access-" + id, refreshToken: "refresh-" + id,
                              tokenType: "Bearer", expiry: "2100-01-01T00:00:00.123456Z"),
                 authMethod: "consumer", idToken: idToken)
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
