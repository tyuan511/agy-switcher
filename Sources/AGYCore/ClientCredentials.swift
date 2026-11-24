import Foundation

struct ClientCredentials: Sendable {
    struct Target: Sendable {
        let keychainEncoding: Bool
        let read: @Sendable (KeychainInteraction) throws -> Data?
        let write: @Sendable (Data?) throws -> Void
    }

    private static let keychainPrefix = Data("go-keyring-base64:".utf8)
    let targets: [Target]

    init(home: URL = .homeDirectory) {
        let keychain = KeychainCredentialStore(service: "gemini")
        self.init(home: home, sharedKeychain: Target(
            keychainEncoding: true,
            read: { try keychain.readForGoKeyring("antigravity", interaction: $0) },
            write: { try keychain.replaceForGoKeyring($0, account: "antigravity") }
        ))
    }

    init(home: URL, sharedKeychain: Target) {
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let desktop = SecretFile(url: gemini.appendingPathComponent("jetski-standalone-oauth-token"))
        let cli = SecretFile(url: gemini.appendingPathComponent("antigravity-cli/antigravity-oauth-token"))
        targets = [
            sharedKeychain,
            Target(keychainEncoding: false, read: { _ in try desktop.read() }, write: desktop.write),
            Target(keychainEncoding: false, read: { _ in try cli.read() }, write: cli.write),
        ]
    }

    init(targets: [Target]) {
        self.targets = targets
    }

    func activeAccount(knownSubjects: Set<String>, matchToken: (String) throws -> String?) throws -> ActiveAccount {
        var readable: [Data] = []
        var needsPermission = false
        for target in targets {
            do {
                if let data = try target.read(.disallowed) { readable.append(data) }
            } catch AGYError.keychainInteractionRequired {
                needsPermission = true
            }
        }
        let account = try Self.identifyAccount(in: readable, knownSubjects: knownSubjects, matchToken: matchToken)
        if needsPermission && (account == .signedOut || account == .unmanaged) {
            throw AGYError.keychainInteractionRequired
        }
        return account
    }

    private static func identifyAccount(
        in readable: [Data], knownSubjects: Set<String>, matchToken: (String) throws -> String?
    ) throws -> ActiveAccount {
        guard let firstData = readable.first else { return .signedOut }
        let credentials = readable.compactMap { try? Self.decode($0) }
        guard let first = credentials.first else {
            return readable.dropFirst().allSatisfy { $0 == firstData } ? .unmanaged : .inconsistent
        }
        let subjects = Set(credentials.compactMap(\.subject))
        guard subjects.count <= 1, credentials.count == readable.count,
              credentials.dropFirst().allSatisfy({ $0.matches(first) }) else { return .inconsistent }
        if let subject = subjects.first, knownSubjects.contains(subject) { return .managed(subject) }
        if let id = try matchToken(first.token.refreshToken) { return .managed(id) }
        return .unmanaged
    }

    func validateCurrentCredentials() throws {
        let readOrder = targets.indices.sorted { !targets[$0].keychainEncoding && targets[$1].keychainEncoding }
        for index in readOrder {
            let target = targets[index]
            let interaction: KeychainInteraction = target.keychainEncoding ? .disallowed : .allowed
            do {
                if let data = try target.read(interaction) {
                    guard let current = try? Self.decode(data), current.authMethod == "consumer" else {
                        throw AGYError.unsupportedCredential
                    }
                }
            } catch AGYError.keychainInteractionRequired where target.keychainEncoding {
                continue
            }
        }
    }

    func install(_ credential: AntigravityCredential) throws {
        enum PreviousValue {
            case known(Data?)
            case unreadable
        }

        let json = try JSONEncoder().encode(credential)
        let updates = targets.map { target in
            target.keychainEncoding ? Self.keychainPrefix + json.base64EncodedData() : json
        }
        // Validate local files before touching the shared keychain so unsupported credentials fail early.
        var previous = [PreviousValue](repeating: .known(nil), count: targets.count)
        let readOrder = targets.indices.sorted { !targets[$0].keychainEncoding && targets[$1].keychainEncoding }
        for index in readOrder {
            let target = targets[index]
            let interaction: KeychainInteraction = target.keychainEncoding ? .disallowed : .allowed
            do {
                let data = try target.read(interaction)
                if let data {
                    guard let current = try? Self.decode(data), current.authMethod == "consumer" else {
                        throw AGYError.unsupportedCredential
                    }
                }
                previous[index] = .known(data)
            } catch AGYError.keychainInteractionRequired where target.keychainEncoding {
                // Another client owns the shared keychain ACL; replace it silently via /usr/bin/security.
                previous[index] = .unreadable
            }
        }

        var attempted: [Int] = []
        do {
            // Write the shared keychain before local files so a running client watching local files
            // never observes updated files while the keychain still holds the previous token.
            for index in targets.indices {
                if !targets[index].keychainEncoding, case .known(let prior) = previous[index] {
                    guard try targets[index].read(.allowed) == prior else { throw AGYError.credentialChanged }
                }
                attempted.append(index)
                try targets[index].write(updates[index])
            }
            for index in targets.indices where !targets[index].keychainEncoding {
                guard try targets[index].read(.allowed) == updates[index] else { throw AGYError.switchVerification }
            }
        } catch {
            var recoveryFailed = false
            for index in attempted.reversed() {
                guard case .known(let prior) = previous[index] else { continue }
                let interaction: KeychainInteraction = targets[index].keychainEncoding ? .disallowed : .allowed
                do {
                    let value = try targets[index].read(interaction)
                    if value == prior { continue }
                    guard value == updates[index] else {
                        // Another client wrote here during the switch. Keep its newer value.
                        recoveryFailed = true
                        continue
                    }
                    try targets[index].write(prior)
                    if try targets[index].read(interaction) != prior { recoveryFailed = true }
                } catch {
                    recoveryFailed = true
                }
            }
            if recoveryFailed { throw AGYError.switchRecoveryFailed }
            throw error
        }
    }

    static func decode(_ data: Data) throws -> AntigravityCredential {
        if data.starts(with: keychainPrefix) {
            guard let json = Data(base64Encoded: Data(data.dropFirst(keychainPrefix.count))) else {
                throw AGYError.unsupportedCredential
            }
            return try JSONDecoder().decode(AntigravityCredential.self, from: json)
        }
        return try JSONDecoder().decode(AntigravityCredential.self, from: data)
    }
}
