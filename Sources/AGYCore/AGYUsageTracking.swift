import CryptoKit
import Darwin
import Foundation

struct AGYUsageObservation: Codable, Sendable {
    let conversationID: String
    let email: String
    let firstSeenAt: Date
    let lastSeenAt: Date
}

struct AGYUsageTracking: Sendable {
    static let recordArgument = "--record-agy-usage-account"
    static let cliDirectory = URL.homeDirectory.appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory)

    private static let commandMarker = "# AGY Switcher account tracking"
    private let cliDirectory: URL
    private let trackingDirectory: URL

    private var settings: URL { cliDirectory.appending(path: "settings.json") }
    private var setupFile: URL { trackingDirectory.appending(path: "setup.json") }
    private var observationsDirectory: URL { trackingDirectory.appending(path: "accounts", directoryHint: .isDirectory) }

    init(cliDirectory: URL = Self.cliDirectory,
         trackingDirectory: URL = URL.applicationSupportDirectory.appending(path: "AGY Switcher/agy-usage", directoryHint: .isDirectory)) {
        self.cliDirectory = cliDirectory
        self.trackingDirectory = trackingDirectory
    }

    private struct Setup: Codable {
        let token: UUID
        let executablePath: String
        let command: String
        let previousStatusLine: Data?
    }

    private struct StatusLinePayload: Decodable {
        let conversation_id: UUID?
        let session_id: UUID?
        let email: String?

        init(from decoder: any Decoder) throws {
            let data = try decoder.container(keyedBy: CodingKeys.self)
            conversation_id = (try? data.decode(String.self, forKey: .conversation_id)).flatMap(UUID.init(uuidString:))
            session_id = (try? data.decode(String.self, forKey: .session_id)).flatMap(UUID.init(uuidString:))
            email = try? data.decode(String.self, forKey: .email)
        }

        private enum CodingKeys: String, CodingKey { case conversation_id, session_id, email }
    }

    enum TrackingError: LocalizedError {
        case invalidSettings, missingSetup, locked

        var errorDescription: String? {
            switch self {
            case .invalidSettings: "Invalid agy settings JSON."
            case .missingSetup: "The existing AGY Switcher status line could not be restored from its backup."
            case .locked: "The AGY Switcher account tracker could not be locked."
            }
        }
    }

    func isEnabled(executable: URL) throws -> Bool {
        guard let setup = try loadSetup() else { return false }
        let line = try loadSettings()["statusLine"] as? [String: Any]
        return setup.executablePath == executable.path && line?["command"] as? String == setup.command
            && line?["enabled"] as? Bool != false
    }

    func setEnabled(_ enabled: Bool, executable: URL) throws {
        try withLock {
            var configuration = try loadSettings()
            let line = configuration["statusLine"] as? [String: Any]
            let command = line?["command"] as? String
            let setup = try loadSetup()
            let ownsCommand = command != nil && command == setup?.command
            if command?.hasPrefix(Self.commandMarker) == true && !ownsCommand { throw TrackingError.missingSetup }

            if enabled {
                if ownsCommand, setup?.executablePath == executable.path, line?["enabled"] as? Bool != false { return }
                let previous = try ownsCommand ? setup?.previousStatusLine : configuration["statusLine"].map {
                    try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
                }
                let original = try previous.flatMap { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
                let previousLine = original as? [String: Any]
                let token = UUID()
                let existingCommand = previousLine?["enabled"] as? Bool == false ? nil : previousLine?["command"] as? String
                let recorder = Self.statusLineCommand(executable: executable, token: token, previousCommand: existingCommand)
                var updatedLine = existingCommand == nil ? ["stack_with_default": true] : (previousLine ?? [:])
                updatedLine["type"] = "command"
                updatedLine["command"] = recorder
                updatedLine["enabled"] = true
                configuration["statusLine"] = updatedLine

                let next = Setup(token: token, executablePath: executable.path, command: recorder, previousStatusLine: previous)
                try JSONEncoder().encode(next).write(to: setupFile, options: .atomic)
                do {
                    try writeSettings(configuration)
                } catch {
                    if let setup { try? JSONEncoder().encode(setup).write(to: setupFile, options: .atomic) }
                    else { try? FileManager.default.removeItem(at: setupFile) }
                    throw error
                }
            } else if let setup {
                if ownsCommand {
                    configuration["statusLine"] = try setup.previousStatusLine.map {
                        try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
                    }
                    try writeSettings(configuration)
                }
                try FileManager.default.removeItem(at: setupFile)
            }
        }
    }

    func record(_ data: Data, token: UUID, now: Date = .now) throws {
        let payload = try JSONDecoder().decode(StatusLinePayload.self, from: data)
        guard let conversation = payload.conversation_id ?? payload.session_id,
              let email = payload.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              email.utf8.count <= 320, email.contains("@") else { return }
        try withLock {
            guard let setup = try loadSetup(), setup.token == token else { return }
            let conversationID = conversation.uuidString.lowercased()
            let emailKey = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = observationsDirectory.appending(path: "\(conversationID)-\(token.uuidString)-\(emailKey).json")
            let previous = try? JSONDecoder().decode(AGYUsageObservation.self, from: Data(contentsOf: file))
            if let previous, previous.lastSeenAt >= now { return }
            try FileManager.default.createDirectory(at: observationsDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let observation = AGYUsageObservation(conversationID: conversationID, email: email,
                                                  firstSeenAt: previous?.firstSeenAt ?? now, lastSeenAt: now)
            try JSONEncoder().encode(observation).write(to: file, options: .atomic)
        }
    }

    func observations() throws -> [AGYUsageObservation] {
        guard FileManager.default.fileExists(atPath: observationsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: observationsDirectory, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]).compactMap { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(AGYUsageObservation.self, from: data)
        }
    }

    private func loadSetup() throws -> Setup? {
        guard FileManager.default.fileExists(atPath: setupFile.path) else { return nil }
        return try JSONDecoder().decode(Setup.self, from: Data(contentsOf: setupFile))
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        let data = try Data(contentsOf: settings)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrackingError.invalidSettings
        }
        return settings
    }

    private func writeSettings(_ configuration: [String: Any]) throws {
        try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data([0x0A])).write(to: settings, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: trackingDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = trackingDirectory.appending(path: "tracking.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TrackingError.locked }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw TrackingError.locked }
        return try body()
    }

    private static func statusLineCommand(executable: URL, token: UUID, previousCommand: String?) -> String {
        let executable = shellQuote(executable.path)
        let observe = "\(executable) \(recordArgument) \(token.uuidString) >/dev/null 2>&1"
        if let previousCommand, !previousCommand.isEmpty {
            return """
            \(commandMarker)
            agy_usage_payload=$(/bin/cat)
            printf '%s\\n' "$agy_usage_payload" | \(observe)
            printf '%s\\n' "$agy_usage_payload" | /bin/sh -c \(shellQuote(previousCommand))
            """
        }
        return "\(commandMarker)\n\(observe)\nexit 0"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
