import Darwin
import Foundation
import Security

struct KeychainCredentialStore: Sendable {
    let service: String

    func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AGYError.keychain(status) }
        guard let data = value as? Data else { throw AGYError.invalidResponse }
        return data
    }

    func write(_ data: Data?, account: String) throws {
        let request = query(account)
        guard let data else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AGYError.keychain(status) }
            return
        }

        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AGYError.keychain(status) }
        var item = request
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw AGYError.keychain(added) }
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
