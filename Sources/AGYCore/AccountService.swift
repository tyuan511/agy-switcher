import Foundation

actor AccountService {
    struct Vault: Sendable {
        let read: @Sendable (String) throws -> Data?
        let write: @Sendable (Data?, String) throws -> Void

        static let keychain: Vault = {
            let store = KeychainCredentialStore(service: "com.tyuan511.agy-switcher.accounts")
            return Vault(read: store.read, write: store.write)
        }()
    }

    private let repository: AccountRepository
    private let vault: Vault
    private let clients: ClientCredentials
    private let oauth: GoogleOAuth
    private let quota: QuotaClient
    private var accounts: [Account]?
    private var renewals: [String: Task<AntigravityCredential, Error>] = [:]

    init(
        repository: AccountRepository, vault: Vault = .keychain, clients: ClientCredentials = .init(),
        oauth: GoogleOAuth = .init(), quota: QuotaClient
    ) {
        self.repository = repository
        self.vault = vault
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
        return try clients.activeAccount(knownSubjects: subjects) { refreshToken in
            for id in subjects {
                if let data = try vault.read(id),
                   let credential = try? ClientCredentials.decode(data),
                   credential.token.refreshToken == refreshToken { return id }
            }
            return nil
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

    func switchAccount(to id: String) async throws {
        let credential = try await credential(for: id)
        try Task.checkCancellation()
        guard try list().contains(where: { $0.id == id }) else { throw AGYError.authenticationRequired }
        try clients.install(credential)
    }

    func refreshQuota(for id: String) async throws -> Account {
        let current = try await credential(for: id)
        let snapshot: QuotaSnapshot
        do {
            snapshot = try await quota.fetch(for: current)
        } catch AGYError.authenticationRequired {
            let renewed = try await credential(for: id, rejecting: current.token.accessToken)
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
        let previous = try vault.read(id)
        try vault.write(credential, id)
        do {
            try repository.save(items)
        } catch {
            try vault.write(previous, id)
            throw error
        }
        accounts = items
    }

    private func credential(for id: String, rejecting access: String? = nil) async throws -> AntigravityCredential {
        guard let data = try vault.read(id) else { throw AGYError.authenticationRequired }
        let current = try ClientCredentials.decode(data)
        if current.token.accessToken != access, let expiry = current.token.expiresAt,
           expiry.timeIntervalSinceNow > 90 { return current }
        if let pending = renewals[id] { return try await pending.value }

        let task = Task {
            let updated = try await oauth.refresh(current)
            guard try vault.read(id) == data else { throw AGYError.credentialChanged }
            try vault.write(JSONEncoder().encode(updated), id)
            return updated
        }
        renewals[id] = task
        defer { renewals[id] = nil }
        return try await task.value
    }
}
