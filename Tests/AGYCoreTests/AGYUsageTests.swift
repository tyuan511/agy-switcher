import Foundation
import SQLite3
import Testing
@testable import AGYCore

struct AGYUsageTests {
    @Test func readsLocalSQLiteWithoutDoubleCountingStepsOrRetryMirrors() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID().uuidString.lowercased()
        let file = folder.appending(path: conversation + ".db")
        let now = Date.now
        let timestamp = number(1, UInt64(now.timeIntervalSince1970) - 5)
        let mainUsage = number(1, 1526) + number(2, 2000) + number(3, 250) + number(5, 500)
            + number(9, 100) + number(10, 150) + field(11, Data("response-1".utf8))
        let retryUsage = number(1, 1526) + number(2, 400) + number(3, 50) + field(11, Data("retry-1".utf8))
        let chat = field(4, mainUsage) + field(17, field(2, mainUsage)) + field(17, field(2, retryUsage))
            + field(19, Data("gemini-4-hydrogen".utf8))
        let generation = field(1, chat) + field(2, Data([1]))
        let step = field(8, timestamp) + field(9, mainUsage)
        let observations = [AGYUsageObservation(conversationID: conversation, email: "alex@example.com",
                                                firstSeenAt: now.addingTimeInterval(-60), lastSeenAt: now)]
        let reader = AGYUsageDatabase(directory: folder)

        var database: OpaquePointer?
        try #require(sqlite3_open(file.path, &database) == SQLITE_OK)
        do {
            defer { sqlite3_close(database) }
            try sql(database, "PRAGMA journal_mode=WAL")
            try sql(database, "CREATE TABLE steps (idx INTEGER, metadata BLOB)")
            try sql(database, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            try sql(database, "INSERT INTO steps VALUES (1, \(hex(step)))")
            try sql(database, "INSERT INTO gen_metadata VALUES (0, \(hex(generation)))")
            #expect(try reader.report(observations: observations, dayCount: 7).totals.input == 2900)
        }

        let result = try reader.report(observations: observations, dayCount: 7)
        #expect(result.skippedDatabases == 0)
        #expect(result.totals.input == 2900)
        #expect(result.totals.output == 300)
        #expect(result.accounts.map(\.email) == ["alex@example.com"])
        let estimate = try #require(result.totals.estimatedUSD)
        #expect(abs(estimate - 0.0058875) < 0.0000000001)
    }

    @Test func groupsByLocalDayAndKeepsUnconfirmedAccountsSeparate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_796_083_200)
        let early = now.addingTimeInterval(-28_801)
        let late = now.addingTimeInterval(-28_799)
        let events = [event("alex", early), event("alex", late), event("shared", late, model: "unknown-model"),
                      event("alex", early.addingTimeInterval(-8 * 86400))]
        let observations = [
            AGYUsageObservation(conversationID: "alex", email: "alex@example.com", firstSeenAt: late, lastSeenAt: now),
            AGYUsageObservation(conversationID: "shared", email: "one@example.com", firstSeenAt: early, lastSeenAt: now),
            AGYUsageObservation(conversationID: "shared", email: "two@example.com", firstSeenAt: early, lastSeenAt: now)
        ]
        let report = AGYUsageReport(events: events, observations: observations, now: now, calendar: calendar)
        #expect(report.days.count == 7)
        #expect(report.days.suffix(2).map(\.totals.input) == [1_000_000, 2_000_000])
        #expect(report.accounts.map(\.email) == ["alex@example.com", nil])
        #expect(report.accounts.last?.totals.input == 2_000_000)
        #expect(report.totals.unpricedModels == ["unknown-model"])
    }

    @Test func officialPricesApplyToTheDateOfTheRequest() {
        let december = Date(timeIntervalSince1970: 1_796_083_200)
        let argon = "Gemini 4 Argon (Medium)"
        #expect(AGYUsagePricing.estimate(event("one", december.addingTimeInterval(-1), model: argon)) == 2)
        #expect(AGYUsagePricing.estimate(event("one", december, model: argon)) == 4)
        #expect(AGYUsagePricing.estimate(event("one", december, model: "gemini-4-hydrogen-medium")) == 1.5)
        #expect(AGYUsagePricing.estimate(event("one", december, model: "gemini-4-hydrogen-unlisted")) == nil)
    }

    @Test func accountTrackingPreservesConfigAndRestoresThePreviousStatusLine() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = folder.appending(path: "settings.json")
        let original = #"{"unrelated":"keep this","statusLine":{"type":"command","command":"/bin/cat","padding":2}}"#
        try Data(original.utf8).write(to: settings)
        let tracking = AGYUsageTracking(cliDirectory: folder, trackingDirectory: folder.appending(path: "usage"))
        let executable = URL(filePath: "/usr/bin/false")
        let now = Date.now

        #expect(try !tracking.isEnabled(executable: executable))
        try tracking.setEnabled(true, executable: executable)
        #expect(try tracking.isEnabled(executable: executable))
        #expect(try !tracking.isEnabled(executable: URL(filePath: "/different/path")))
        let configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let line = try #require(configuration["statusLine"] as? [String: Any])
        let command = try #require(line["command"] as? String)
        #expect(command.contains("/bin/sh -c '/bin/cat'"))
        #expect(line["padding"] as? Int == 2)
        let words = command.split(whereSeparator: \.isWhitespace)
        let argument = try #require(words.firstIndex(of: Substring(AGYUsageTracking.recordArgument)))
        let token = try #require(UUID(uuidString: String(words[argument + 1])))

        let conversation = UUID()
        let payload = Data("""
        {"conversation_id":"\(conversation.uuidString)","email":"Alex@Example.com","conversation_title":"private"}
        """.utf8)
        try tracking.record(payload, token: token, now: now)
        try tracking.record(payload, token: token, now: now.addingTimeInterval(60))
        try tracking.record(payload, token: token, now: now.addingTimeInterval(-60))
        let observation = try #require(tracking.observations().first)
        #expect(observation.conversationID == conversation.uuidString.lowercased())
        #expect(observation.email == "alex@example.com")
        #expect(observation.firstSeenAt == now)
        #expect(observation.lastSeenAt == now.addingTimeInterval(60))

        try tracking.setEnabled(false, executable: executable)
        #expect(try !tracking.isEnabled(executable: executable))
        let restored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary)
        #expect(restored == (try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary))
        try tracking.record(payload, token: token, now: now.addingTimeInterval(120))
        #expect(try tracking.observations().first?.lastSeenAt == now.addingTimeInterval(60))
    }

    @Test func anUninitializedCLIHasAnEmptyReport() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = AGYUsageDatabase(directory: folder.appending(path: "missing"))
        #expect(try reader.report(observations: [], dayCount: 7).accounts.isEmpty)
    }

    private func event(_ id: String, _ timestamp: Date, model: String = "gemini-4-neon") -> AGYUsageEvent {
        AGYUsageEvent(conversationID: id, timestamp: timestamp, model: model, freshInput: 1_000_000,
                      cachedInput: 0, cacheWrite: 0, output: 0)
    }

    private func temporaryDirectory() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func sql(_ database: OpaquePointer?, _ statement: String) throws {
        try #require(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK)
    }

    private func field(_ index: UInt64, _ data: Data) -> Data {
        varint((index << 3) | 2) + varint(UInt64(data.count)) + data
    }

    private func number(_ index: UInt64, _ value: UInt64) -> Data { varint(index << 3) + varint(value) }

    private func varint(_ value: UInt64) -> Data {
        var data = Data()
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
        return data
    }

    private func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }
}
