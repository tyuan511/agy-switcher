import Foundation

struct ClientCredentials: Sendable {
    struct Target: Sendable {
        let keychainEncoding: Bool
        let read: @Sendable () throws -> Data?
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
            Target(keychainEncoding: true, read: { try keychain.read("antigravity") },
                   write: { try keychain.write($0, account: "antigravity") }),
            Target(keychainEncoding: false, read: desktop.read, write: desktop.write),
            Target(keychainEncoding: false, read: cli.read, write: cli.write),
        ]
    }

    init(targets: [Target]) {
        self.targets = targets
    }

    func activeAccount(knownSubjects: Set<String>, matchToken: (String) throws -> String?) throws -> ActiveAccount {
        let present = try targets.compactMap { try $0.read() }
        guard !present.isEmpty else { return .signedOut }
        let credentials = present.compactMap { try? Self.decode($0) }
        guard let first = credentials.first else {
            return present.dropFirst().allSatisfy { $0 == present[0] } ? .unmanaged : .inconsistent
        }
        guard credentials.count == present.count,
              credentials.dropFirst().allSatisfy({ $0.matches(first) }) else { return .inconsistent }
        if let subject = first.subject, knownSubjects.contains(subject) { return .managed(subject) }
        if let id = try matchToken(first.token.refreshToken) { return .managed(id) }
        return .unmanaged
    }

    func install(_ credential: AntigravityCredential) throws {
        let json = try JSONEncoder().encode(credential)
        let updates = targets.map { target in
            target.keychainEncoding ? Self.keychainPrefix + json.base64EncodedData() : json
        }
        let previous = try targets.map { try $0.read() }
        for data in previous.compactMap({ $0 }) {
            guard let current = try? Self.decode(data), current.authMethod == "consumer" else {
                throw AGYError.unsupportedCredential
            }
        }

        var attempted: [Int] = []
        do {
            for index in targets.indices {
                guard try targets[index].read() == previous[index] else { throw AGYError.credentialChanged }
                attempted.append(index)
                try targets[index].write(updates[index])
            }
            for index in targets.indices {
                guard try targets[index].read() == updates[index] else { throw AGYError.switchVerification }
            }
        } catch {
            var recoveryFailed = false
            for index in attempted.reversed() {
                do {
                    let value = try targets[index].read()
                    if value == previous[index] { continue }
                    guard value == updates[index] else {
                        // Another client wrote here during the switch. Keep its newer value.
                        recoveryFailed = true
                        continue
                    }
                    try targets[index].write(previous[index])
                    if try targets[index].read() != previous[index] { recoveryFailed = true }
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
