import Foundation

actor AccountService {
    struct Vault: Sendable {
        let read: @Sendable (String, KeychainInteraction) throws -> Data?
        let write: @Sendable (Data?, String, KeychainInteraction) throws -> Void

        static func encrypted(directory: URL) -> Vault {
            let store = EncryptedCredentialVault(directory: directory)
            return Vault(read: store.read, write: store.write)
        }
    }

    private let repository: AccountRepository
    private let vault: Vault
    private let clients: ClientCredentials
    private let oauth: GoogleOAuth
    private let quota: QuotaClient
    private var accounts: [Account]?
    private var renewals: [String: (task: Task<AntigravityCredential, Error>, interaction: KeychainInteraction)] = [:]

    init(
        repository: AccountRepository, vault: Vault? = nil, clients: ClientCredentials = .init(),
        oauth: GoogleOAuth = .init(), quota: QuotaClient
    ) {
        self.repository = repository
        self.vault = vault ?? .encrypted(directory: repository.directory)
        self.clients = clients
        self.oauth = oauth
        self.quota = quota
    }

    func list() throws -> [Account] {
        if let accounts { return accounts }
        let saved = try repository.load()
        accounts = saved
        return saved
    }

    func activeAccount() throws -> ActiveAccount {
        let subjects = Set(try list().map(\.id))
        do {
            return try clients.activeAccount(knownSubjects: subjects) { refreshToken in
                for id in subjects {
                    if let data = try vault.read(id, .disallowed),
                       let credential = try? ClientCredentials.decode(data),
                       credential.token.refreshToken == refreshToken { return id }
                }
                return nil
            }
        } catch AGYError.keychainInteractionRequired {
            return .unknown
        }
    }

    func authorize(
        account: GoogleIdentity?, language: AppLanguage, openBrowser: @escaping LoopbackOAuth.Browser
    ) async throws -> Account {
        let credential = try await LoopbackOAuth.authorize(
            with: oauth, email: account?.email, language: language, openBrowser: openBrowser
        )
        let identity = try await oauth.identity(for: credential)
        try Task.checkCancellation()
        if let account, account.id != identity.id { throw AGYError.differentAccount }
        return try saveAuthorization(identity: identity, credential: credential)
    }

    func saveAuthorization(identity: GoogleIdentity, credential: AntigravityCredential) throws -> Account {
        var items = try list()
        let index = items.firstIndex { $0.id == identity.id }
        let account = Account(identity: identity, quota: index.flatMap { items[$0].quota })
        if let index {
            items[index] = account
        } else {
            items.append(account)
        }
        try save(items, updating: identity.id, credential: JSONEncoder().encode(credential))
        return account
    }

    func remove(_ id: String) throws {
        let items = try list().filter { $0.id != id }
        try save(items, updating: id, credential: nil)
    }

    func exportBackup(to url: URL, passphrase: String) throws -> Int {
        let entries = try list().compactMap { account -> BackupAccount? in
            guard let data = try vault.read(account.id, .allowed) else { return nil }
            return BackupAccount(
                identity: account.identity,
                credential: try ClientCredentials.decode(data),
                quota: account.quota
            )
        }
        guard !entries.isEmpty else { throw AGYError.emptyBackup }
        let data = try AccountBackup.write(entries, passphrase: passphrase)
        if !FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            throw AGYError.backupWriteFailed
        }
        return entries.count
    }

    func importBackup(_ data: Data, passphrase: String) throws -> BackupImportSummary {
        let entries = try AccountBackup.read(data, passphrase: passphrase)
        guard !entries.isEmpty else { throw AGYError.emptyBackup }
        var items = try list()
        var summary = BackupImportSummary(imported: 0, skipped: 0)
        var written: [String] = []
        do {
            for entry in entries {
                let index = items.firstIndex { $0.id == entry.identity.id }
                if let index, try vault.read(entry.identity.id, .allowed) != nil {
                    summary.skipped += 1
                    continue
                }
                try vault.write(JSONEncoder().encode(entry.credential), entry.identity.id, .allowed)
                written.append(entry.identity.id)
                let account = Account(identity: entry.identity, quota: entry.quota)
                if let index {
                    items[index] = account
                } else {
                    items.append(account)
                }
                summary.imported += 1
            }
            try repository.save(items)
        } catch {
            // Only entries written by this import can be reverted; skip decisions stay untouched.
            for id in written { try? vault.write(nil, id, .allowed) }
            throw error
        }
        accounts = items
        return summary
    }

    func switchAccount(to id: String) async throws {
        let credential = try await credential(for: id, interaction: .allowed)
        try Task.checkCancellation()
        guard try list().contains(where: { $0.id == id }) else { throw AGYError.authenticationRequired }
        try clients.install(credential)
    }

    func refreshQuota(for id: String, interaction: KeychainInteraction) async throws -> Account {
        let current = try await credential(for: id, interaction: interaction)
        let snapshot: QuotaSnapshot
        do {
            snapshot = try await quota.fetch(for: current)
        } catch AGYError.authenticationRequired {
            let renewed = try await credential(for: id, rejecting: current.token.accessToken, interaction: interaction)
            snapshot = try await quota.fetch(for: renewed)
        }
        try Task.checkCancellation()

        var items = try list()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw AGYError.authenticationRequired
        }
        items[index].quota = snapshot
        try repository.save(items)
        accounts = items
        return items[index]
    }

    private func save(_ items: [Account], updating id: String, credential: Data?) throws {
        let previous = try vault.read(id, .allowed)
        try vault.write(credential, id, .allowed)
        do {
            try repository.save(items)
        } catch {
            try vault.write(previous, id, .allowed)
            throw error
        }
        accounts = items
    }

    private func credential(
        for id: String, rejecting access: String? = nil, interaction: KeychainInteraction
    ) async throws -> AntigravityCredential {
        guard let data = try vault.read(id, interaction) else { throw AGYError.authenticationRequired }
        let current = try ClientCredentials.decode(data)
        if current.token.accessToken != access, let expiry = current.token.expiresAt,
           expiry.timeIntervalSinceNow > 90 { return current }
        if let pending = renewals[id] {
            do {
                return try await pending.task.value
            } catch AGYError.keychainInteractionRequired where interaction == .allowed && pending.interaction == .disallowed {
                // An explicit action can retry a renewal that required permission in the background.
                return try await credential(for: id, rejecting: access, interaction: interaction)
            }
        }

        let task = Task {
            defer { renewals[id] = nil }
            let updated = try await oauth.refresh(current)
            guard try vault.read(id, interaction) == data else { throw AGYError.credentialChanged }
            try vault.write(JSONEncoder().encode(updated), id, interaction)
            return updated
        }
        renewals[id] = (task, interaction)
        return try await task.value
    }
}
