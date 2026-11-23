import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import Synchronization

enum KeychainInteraction: Sendable {
    case allowed, disallowed
}

struct KeychainCredentialStore: Sendable {
    private static let interactionLock = Mutex(())
    let service: String

    func read(_ account: String, interaction: KeychainInteraction) throws -> Data? {
        try withQuery(account, interaction: interaction) { request in
            var request = request
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = value as? Data else { throw AGYError.invalidResponse }
            return data
        }
    }

    func write(_ data: Data?, account: String, interaction: KeychainInteraction) throws {
        try withQuery(account, interaction: interaction) { request in
            guard let data else {
                let status = SecItemDelete(request as CFDictionary)
                if status != errSecItemNotFound { try check(status) }
                return
            }

            let attributes = [kSecValueData as String: data]
            let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            guard status == errSecItemNotFound else {
                try check(status)
                return
            }
            var item = request
            item[kSecValueData as String] = data
            try check(SecItemAdd(item as CFDictionary, nil))
        }
    }

    private func withQuery<Result: Sendable>(
        _ account: String, interaction: KeychainInteraction, perform: ([String: Any]) throws -> Result
    ) throws -> Result {
        var request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return try Self.interactionLock.withLock { _ in
            guard interaction == .disallowed else { return try perform(request) }

            // Legacy login-keychain items use a process-wide setting for prompts.
            var wasAllowed = DarwinBoolean(false)
            try check(SecKeychainGetUserInteractionAllowed(&wasAllowed))
            try check(SecKeychainSetUserInteractionAllowed(false))
            defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }

            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
            do {
                return try perform(request)
            } catch AGYError.keychain(let status) where status == errSecAuthFailed || status == errSecUserCanceled {
                throw AGYError.keychainInteractionRequired
            }
        }
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed { throw AGYError.keychainInteractionRequired }
        guard status == errSecSuccess else { throw AGYError.keychain(status) }
    }
}

struct SecretFile: Sendable {
    let url: URL

    func read() throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor == -1 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size <= 1_048_576 else { throw AGYError.unsupportedCredential }
        return try handle.readToEnd() ?? Data()
    }

    func write(_ data: Data?) throws {
        guard let data else {
            if Darwin.unlink(url.path) != 0 && errno != ENOENT { throw posixError() }
            return
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var template = directory.appendingPathComponent(".agy-switcher-XXXXXX").path.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw posixError() }
        let temporaryPath = template.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        defer { _ = Darwin.unlink(temporaryPath) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporaryPath, url.path) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct AccountRepository: Sendable {
    let directory: URL

    private var file: SecretFile { SecretFile(url: directory.appendingPathComponent("accounts.json")) }

    func load() throws -> [Account] {
        guard let data = try file.read() else { return [] }
        return try JSONDecoder().decode([Account].self, from: data)
    }

    func save(_ accounts: [Account]) throws {
        try file.write(JSONEncoder().encode(accounts))
    }
}

final class EncryptedCredentialVault: Sendable {
    struct KeyStore: Sendable {
        let read: @Sendable (String, KeychainInteraction) throws -> Data?
        let write: @Sendable (Data?, String, KeychainInteraction) throws -> Void

        init(store: KeychainCredentialStore) {
            self.read = store.read
            self.write = store.write
        }

        init(
            read: @escaping @Sendable (String, KeychainInteraction) throws -> Data?,
            write: @escaping @Sendable (Data?, String, KeychainInteraction) throws -> Void
        ) {
            self.read = read
            self.write = write
        }
    }

    private struct State {
        var masterKey: SymmetricKey?
        var entries: [String: Data]?
    }

    private static let header = Data("AGYV\u{01}".utf8)
    private static let masterKeyAccount = "master-key"

    private let file: SecretFile
    private let keyStore: KeyStore
    private let legacyStore: KeyStore?
    private let state = Mutex(State())

    init(
        directory: URL,
        keyStore: KeyStore = KeyStore(store: KeychainCredentialStore(service: "com.tyuan511.agy-switcher.vault")),
        legacyStore: KeyStore? = KeyStore(store: KeychainCredentialStore(service: "com.tyuan511.agy-switcher.accounts"))
    ) {
        self.file = SecretFile(url: directory.appendingPathComponent("credentials.enc"))
        self.keyStore = keyStore
        self.legacyStore = legacyStore
    }

    func read(_ account: String, interaction: KeychainInteraction) throws -> Data? {
        try state.withLock { state in
            if let entries = try loadEntriesIfPresent(state: &state, interaction: interaction),
               let data = entries[account] {
                return data
            }

            guard let legacyStore,
                  let migrated = try legacyStore.read(account, interaction) else {
                return nil
            }

            // Migrate legacy per-account keychain items into the single encrypted vault on first read.
            if let key = try? masterKey(state: &state, createIfMissing: true, interaction: interaction) {
                var entries = state.entries ?? [:]
                entries[account] = migrated
                if (try? persist(entries, using: key)) != nil {
                    state.entries = entries
                    // Best-effort cleanup without triggering an extra prompt.
                    try? legacyStore.write(nil, account, .disallowed)
                }
            }
            return migrated
        }
    }

    func write(_ data: Data?, account: String, interaction: KeychainInteraction) throws {
        try state.withLock { state in
            guard let data else {
                if var entries = try loadEntriesIfPresent(state: &state, interaction: interaction),
                   entries.removeValue(forKey: account) != nil {
                    if entries.isEmpty {
                        try file.write(nil)
                    } else if let key = try masterKey(state: &state, createIfMissing: false, interaction: interaction) {
                        try persist(entries, using: key)
                    }
                    state.entries = entries
                }
                if let legacyStore {
                    try? legacyStore.write(nil, account, .disallowed)
                }
                return
            }

            var entries = try loadEntriesIfPresent(state: &state, interaction: interaction) ?? [:]
            let key = try masterKey(state: &state, createIfMissing: true, interaction: interaction)!
            entries[account] = data
            try persist(entries, using: key)
            state.entries = entries
            if let legacyStore {
                try? legacyStore.write(nil, account, .disallowed)
            }
        }
    }

    private func loadEntriesIfPresent(state: inout State, interaction: KeychainInteraction) throws -> [String: Data]? {
        if let cached = state.entries { return cached }
        guard let ciphertext = try file.read() else { return nil }
        guard let key = try masterKey(state: &state, createIfMissing: false, interaction: interaction) else {
            throw AGYError.unsupportedCredential
        }
        let entries = try decrypt(ciphertext, using: key)
        state.entries = entries
        return entries
    }

    private func masterKey(
        state: inout State, createIfMissing: Bool, interaction: KeychainInteraction
    ) throws -> SymmetricKey? {
        if let cached = state.masterKey { return cached }
        if let raw = try keyStore.read(Self.masterKeyAccount, interaction) {
            guard raw.count == 32 else { throw AGYError.unsupportedCredential }
            let key = SymmetricKey(data: raw)
            state.masterKey = key
            return key
        }
        guard createIfMissing else { return nil }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try keyStore.write(raw, Self.masterKeyAccount, interaction)
        state.masterKey = key
        return key
    }

    private func persist(_ entries: [String: Data], using key: SymmetricKey) throws {
        let plaintext = try JSONEncoder().encode(entries)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw AGYError.unsupportedCredential }
        try file.write(Self.header + combined)
    }

    private func decrypt(_ data: Data, using key: SymmetricKey) throws -> [String: Data] {
        guard data.starts(with: Self.header) else { throw AGYError.unsupportedCredential }
        let payload = data.dropFirst(Self.header.count)
        let box: AES.GCM.SealedBox
        let plaintext: Data
        do {
            box = try AES.GCM.SealedBox(combined: payload)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw AGYError.unsupportedCredential
        }
        return try JSONDecoder().decode([String: Data].self, from: plaintext)
    }
}
