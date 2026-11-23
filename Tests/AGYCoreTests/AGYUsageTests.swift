import Foundation
import SQLite3
import Testing
@testable import AGYCore

struct AGYUsageTests {
    @Test(arguments: AppLanguage.allCases) func formatsTokenCountsAboveOneHundredThousand(_ language: AppLanguage) {
        #expect(AGYUsageTokenFormat.format(0, in: language) == "0")
        #expect(AGYUsageTokenFormat.format(0.25, in: language) == "0.25")
        #expect(AGYUsageTokenFormat.format(99_999, in: language) == "99,999")
        #expect(AGYUsageTokenFormat.format(100_000, in: language) == "100,000")
        #expect(AGYUsageTokenFormat.format(100_001, in: language) == "0.1M")
        #expect(AGYUsageTokenFormat.format(1_234_567, in: language) == "1.23M")
        #expect(AGYUsageTokenFormat.format(999_500_000, in: language) == "999.5M")
        #expect(AGYUsageTokenFormat.format(1_000_000_000, in: language) == "1B")
        #expect(AGYUsageTokenFormat.format(1_250_000_000, in: language) == "1.25B")
    }

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
            #expect(try reader.report(dayCount: 7).totals.input == 2900)
        }

        let result = try reader.report(dayCount: 7)
        #expect(result.skippedDatabases == 0)
        #expect(result.totals.input == 2900)
        #expect(result.totals.cachedInput == 500)
        #expect(result.totals.output == 300)
        let estimate = try #require(result.totals.estimatedUSD)
        #expect(abs(estimate - 0.0058875) < 0.0000000001)
    }

    @Test func groupsByLocalDayAndTracksUnpricedModels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = Date(timeIntervalSince1970: 1_796_083_200)
        let early = now.addingTimeInterval(-28_801)
        let late = now.addingTimeInterval(-28_799)
        let events = [event("alex", early), event("alex", late), event("shared", late, model: "unknown-model"),
                      event("alex", early.addingTimeInterval(-8 * 86400))]
        let report = AGYUsageReport(events: events, now: now, calendar: calendar)
        #expect(report.days.count == 7)
        #expect(report.days.suffix(2).map(\.totals.input) == [1_000_000, 2_000_000])
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

    @Test func calculatesWeightedCacheHitRatesAcrossDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_796_083_200)
        let yesterday = now.addingTimeInterval(-86_400)
        let model = "claude-sonnet-5.5"
        let events = [
            AGYUsageEvent(conversationID: "alex", timestamp: yesterday, model: model,
                          freshInput: 20, cachedInput: 60, cacheWrite: 20, output: 50),
            AGYUsageEvent(conversationID: "alex", timestamp: now, model: model,
                          freshInput: 130, cachedInput: 20, cacheWrite: 50, output: 50),
            AGYUsageEvent(conversationID: "other", timestamp: now, model: model,
                          freshInput: 100, cachedInput: 0, cacheWrite: 0, output: 50)
        ]
        let report = AGYUsageReport(events: events, dayCount: 3, now: now, calendar: calendar)

        #expect(report.totals.cacheHitRate == 0.2)
        #expect(report.days.map(\.totals.cacheHitRate) == [nil, 0.6, 20.0 / 300])
    }

    @Test func anUninitializedCLIHasAnEmptyReport() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = AGYUsageDatabase(directory: folder.appending(path: "missing"))
        #expect(try reader.report(dayCount: 7).totals.isEmpty)
    }

    @Test func readsAndDeduplicatesAcrossMultipleDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cliDir = root.appending(path: "cli", directoryHint: .isDirectory)
        let antigravityDir = root.appending(path: "antigravity", directoryHint: .isDirectory)
        let missingDir = root.appending(path: "missing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: antigravityDir, withIntermediateDirectories: true)

        let now = Date.now
        let timestamp = number(1, UInt64(now.timeIntervalSince1970) - 5)

        func writeDB(in dir: URL, conversationID: String, input: UInt64, output: UInt64, responseID: String) throws {
            let usage = number(1, 1526) + number(2, input) + number(3, output) + field(11, Data(responseID.utf8))
            let chat = field(4, usage) + field(19, Data("gemini-4-hydrogen".utf8))
            let generation = field(1, chat) + field(2, Data([0]))
            let step = field(8, timestamp)
            let file = dir.appending(path: "\(conversationID).db")
            var database: OpaquePointer?
            try #require(sqlite3_open(file.path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            try sql(database, "CREATE TABLE steps (idx INTEGER, metadata BLOB)")
            try sql(database, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            try sql(database, "INSERT INTO steps VALUES (0, \(hex(step)))")
            try sql(database, "INSERT INTO gen_metadata VALUES (0, \(hex(generation)))")
        }

        let cliConv = UUID().uuidString.lowercased()
        let agConv = UUID().uuidString.lowercased()
        let dupConv = UUID().uuidString.lowercased()
        try writeDB(in: cliDir, conversationID: cliConv, input: 1000, output: 100, responseID: "resp-cli")
        try writeDB(in: antigravityDir, conversationID: agConv, input: 2000, output: 200, responseID: "resp-ag")
        try writeDB(in: antigravityDir, conversationID: dupConv, input: 1000, output: 100, responseID: "resp-cli")

        let reader = AGYUsageDatabase(directories: [missingDir, cliDir, antigravityDir])
        let report = try reader.report(dayCount: 7)

        #expect(report.skippedDatabases == 0)
        #expect(report.totals.input == 3000)
        #expect(report.totals.output == 300)
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
