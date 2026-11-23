import CommonCrypto
import CryptoKit
import Foundation
import Security

struct BackupAccount: Codable, Equatable, Sendable {
    var identity: GoogleIdentity
    var credential: AntigravityCredential
    var quota: QuotaSnapshot?
}

struct BackupImportSummary: Equatable, Sendable {
    var imported: Int
    var skipped: Int
}

/// A passphrase-encrypted archive of accounts and their credentials for moving between machines.
enum AccountBackup {
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: String
        var payload: String
    }

    static let fileExtension = "agyaccounts"

    private static let format = "com.tyuan511.agy-switcher.account-backup"
    private static let version = 1
    private static let kdf = "PBKDF2-HMAC-SHA256"
    private static let iterationCount = 600_000
    private static let maximumIterations = 10_000_000
    private static let saltSize = 32
    private static let keySize = 32

    static func write(_ accounts: [BackupAccount], passphrase: String) throws -> Data {
        var salt = Data(repeating: 0, count: saltSize)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw AGYError.backupWriteFailed }
        let key = try derivedKey(from: passphrase, salt: salt, iterations: iterationCount)
        let plaintext = try JSONEncoder().encode(accounts)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw AGYError.backupWriteFailed
        }
        let envelope = Envelope(
            format: format, version: version, kdf: kdf,
            iterations: iterationCount, salt: salt.base64EncodedString(),
            payload: combined.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }

    static func read(_ data: Data, passphrase: String) throws -> [BackupAccount] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == format, envelope.version == version,
              envelope.kdf == kdf, envelope.iterations > 0, envelope.iterations <= maximumIterations,
              let salt = Data(base64Encoded: envelope.salt), salt.count >= 8,
              let payload = Data(base64Encoded: envelope.payload) else {
            throw AGYError.invalidBackup
        }
        let key = try derivedKey(from: passphrase, salt: salt, iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode([BackupAccount].self, from: plaintext)
        } catch {
            throw AGYError.invalidBackup
        }
    }

    private static func derivedKey(from passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.utf8CString)
        var derived = Data(repeating: 0, count: keySize)
        let status = derived.withUnsafeMutableBytes { derivedBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.count - 1,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(clamping: iterations),
                    derivedBuffer.bindMemory(to: UInt8.self).baseAddress, keySize
                )
            }
        }
        guard status == kCCSuccess else { throw AGYError.invalidBackup }
        return SymmetricKey(data: derived)
    }
}
