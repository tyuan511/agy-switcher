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
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let desktop = SecretFile(url: gemini.appendingPathComponent("jetski-standalone-oauth-token"))
        let cli = SecretFile(url: gemini.appendingPathComponent("antigravity-cli/antigravity-oauth-token"))
        let keychain = KeychainCredentialStore(service: "gemini")
        targets = [
            Target(keychainEncoding: true, read: { try keychain.read("antigravity", interaction: $0) },
                   write: { try keychain.write($0, account: "antigravity", interaction: .allowed) }),
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

    func install(_ credential: AntigravityCredential) throws {
        let json = try JSONEncoder().encode(credential)
        let updates = targets.map { target in
            target.keychainEncoding ? Self.keychainPrefix + json.base64EncodedData() : json
        }
        // Validate local files before touching the keychain so unsupported credentials fail without prompting.
        var previous = [Data?](repeating: nil, count: targets.count)
        let readOrder = targets.indices.sorted { !targets[$0].keychainEncoding && targets[$1].keychainEncoding }
        for index in readOrder {
            let data = try targets[index].read(.allowed)
            if let data {
                guard let current = try? Self.decode(data), current.authMethod == "consumer" else {
                    throw AGYError.unsupportedCredential
                }
            }
            previous[index] = data
        }

        var attempted: [Int] = []
        do {
            for index in targets.indices {
                if !targets[index].keychainEncoding {
                    guard try targets[index].read(.allowed) == previous[index] else { throw AGYError.credentialChanged }
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
                do {
                    let value = try targets[index].read(.allowed)
                    if value == previous[index] { continue }
                    guard value == updates[index] else {
                        // Another client wrote here during the switch. Keep its newer value.
                        recoveryFailed = true
                        continue
                    }
                    try targets[index].write(previous[index])
                    if try targets[index].read(.allowed) != previous[index] { recoveryFailed = true }
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
