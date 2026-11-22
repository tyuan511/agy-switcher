import Foundation
import SQLite3

struct AGYUsageDatabase: Sendable {
    let directory: URL

    func report(observations: [AGYUsageObservation], dayCount: Int) throws -> AGYUsageReport {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return AGYUsageReport(events: [], dayCount: dayCount)
        }

        let now = Date.now
        let calendar = Calendar.current
        let oldestDay = calendar.date(byAdding: .day, value: 1 - dayCount, to: calendar.startOfDay(for: now)) ?? now
        var events: [AGYUsageEvent] = []
        var skipped = 0
        var seenIdentifiers: Set<String> = []
        let linkedIDs = Set(observations.map(\.conversationID))
        let databases = files.filter { $0.pathExtension == "db" }.sorted { first, second in
            let firstLinked = linkedIDs.contains(first.deletingPathExtension().lastPathComponent.lowercased())
            let secondLinked = linkedIDs.contains(second.deletingPathExtension().lastPathComponent.lowercased())
            if firstLinked != secondLinked { return firstLinked }
            return first.lastPathComponent < second.lastPathComponent
        }
        for file in databases {
            try Task.checkCancellation()
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let wal = URL(filePath: file.path + "-wal")
            if let modified, modified < oldestDay, !FileManager.default.fileExists(atPath: wal.path) { continue }
            do {
                let calls = try Self.calls(in: file)
                let conversationID = file.deletingPathExtension().lastPathComponent.lowercased()
                for call in calls.sorted(by: { $0.timestamp < $1.timestamp }) where call.timestamp >= oldestDay {
                    let duplicate = !seenIdentifiers.isDisjoint(with: call.usage.identifiers)
                    seenIdentifiers.formUnion(call.usage.identifiers)
                    if !duplicate { events.append(call.event(conversationID: conversationID)) }
                }
            } catch {
                skipped += 1
            }
        }
        return AGYUsageReport(events: events, observations: observations, skippedDatabases: skipped,
                              dayCount: dayCount, now: now, calendar: calendar)
    }

    private static func calls(in file: URL) throws -> [Call] {
        let wal = file.path + "-wal"
        let shm = file.path + "-shm"
        func hasSidecars() -> Bool {
            FileManager.default.fileExists(atPath: wal) || FileManager.default.fileExists(atPath: shm)
        }

        if hasSidecars() { return try readCalls(in: file, immutable: false) }
        // The system SQLite cannot open agy's checkpointed WAL databases normally after the sidecars disappear.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let version = try file.resourceValues(forKeys: keys)
        let result = Result { try readCalls(in: file, immutable: true) }
        var refreshed = file
        refreshed.removeAllCachedResourceValues()
        let current = try refreshed.resourceValues(forKeys: keys)
        if hasSidecars() || current.contentModificationDate != version.contentModificationDate || current.fileSize != version.fileSize {
            return try readCalls(in: file, immutable: false)
        }
        return try result.get()
    }

    private static func readCalls(in file: URL, immutable: Bool) throws -> [Call] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        let uri = file.absoluteString + (immutable ? "?mode=ro&immutable=1" : "?mode=ro")
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            throw ReaderError.database
        }
        sqlite3_busy_timeout(handle, 100)
        guard sqlite3_exec(handle, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReaderError.database }
        let tables = try tableNames(handle)
        guard tables.contains("gen_metadata") || tables.contains("steps") else { return [] }

        // agy may write the same call to both tables. Prefer generation metadata and use step timestamps or usage when needed.
        var steps: [Int64: Step] = [:]
        if tables.contains("steps") {
            for (index, data) in try rows(handle, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") {
                steps[index] = try Step(data)
            }
        }
        var calls: [Call] = []
        var coveredSteps: Set<Int64> = []
        var model: String?
        if tables.contains("gen_metadata") {
            for (_, data) in try rows(handle, "SELECT idx, data FROM gen_metadata ORDER BY idx") {
                let generation = try Generation(data)
                model = generation.model ?? model
                let linked = generation.stepIndices.compactMap { steps[$0] }
                guard let timestamp = generation.timestamp ?? linked.compactMap(\.timestamp).first else { continue }
                let callModel = generation.model ?? linked.compactMap(\.model).first ?? model ?? "unknown"
                if let usage = generation.usage, usage.hasTokens {
                    calls.append(Call(timestamp: timestamp, model: callModel, usage: usage))
                    coveredSteps.formUnion(generation.stepIndices)
                }
                calls += generation.retries.filter(\.hasTokens).map { retry in
                    let model = retry.modelID == generation.usage?.modelID ? callModel : "unknown"
                    return Call(timestamp: timestamp, model: model, usage: retry)
                }
            }
        }
        for (index, step) in steps.sorted(by: { $0.key < $1.key }) where !coveredSteps.contains(index) {
            guard let timestamp = step.timestamp, let usage = step.usage, usage.hasTokens else { continue }
            calls.append(Call(timestamp: timestamp, model: step.model ?? "unknown", usage: usage))
        }
        return calls
    }

    private static func tableNames(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError.database
        }
        defer { sqlite3_finalize(statement) }
        var tables: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = sqlite3_column_text(statement, 0) { tables.insert(String(cString: name)) }
            case SQLITE_DONE: return tables
            default: throw ReaderError.database
            }
        }
    }

    private static func rows(_ database: OpaquePointer, _ query: String) throws -> [(Int64, Data)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw ReaderError.database }
        defer { sqlite3_finalize(statement) }
        var rows: [(Int64, Data)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let blob = sqlite3_column_blob(statement, 1) {
                    let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
                    rows.append((sqlite3_column_int64(statement, 0), data))
                }
            case SQLITE_DONE: return rows
            default: throw ReaderError.database
            }
        }
    }

    private enum ReaderError: Error { case database, malformedProtobuf }

    private struct Call {
        let timestamp: Date
        let model: String
        let usage: Usage

        func event(conversationID: String) -> AGYUsageEvent {
            AGYUsageEvent(conversationID: conversationID, timestamp: timestamp, model: model,
                          freshInput: usage.input, cachedInput: usage.cacheRead, cacheWrite: usage.cacheWrite,
                          output: usage.output)
        }
    }

    private struct Usage {
        let modelID: Int64
        let input: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let output: Int64
        let identifiers: Set<String>

        var hasTokens: Bool { input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 }

        init(_ message: Proto) {
            modelID = message.count(1)
            input = message.count(2)
            cacheWrite = message.count(4)
            cacheRead = message.count(5)
            output = max(message.count(3), message.count(9) + message.count(10))
            identifiers = Set([7, 11, 12].compactMap { field in message.text(field).map { "\(field):\($0)" } })
        }

        func mirrors(_ other: Self) -> Bool {
            modelID == other.modelID && input == other.input && cacheRead == other.cacheRead && cacheWrite == other.cacheWrite && output == other.output
                && identifiers.isSubset(of: other.identifiers)
        }
    }

    private struct Generation {
        let model: String?
        let usage: Usage?
        let retries: [Usage]
        let timestamp: Date?
        let stepIndices: [Int64]

        init(_ data: Data) throws {
            let root = try Proto(data)
            let chat = try root.message(1)
            model = chat?.text(19) ?? chat?.text(21)
            usage = try chat?.message(4).map(Usage.init)
            timestamp = try chat?.message(9)?.message(4)?.timestamp
            stepIndices = try root.indices(2)

            var retries = try chat?.messages(17).compactMap { try $0.message(2).map(Usage.init) } ?? []
            if let usage, let index = retries.firstIndex(where: { $0.mirrors(usage) }) { retries.remove(at: index) }
            self.retries = retries
        }
    }

    private struct Step {
        let model: String?
        let usage: Usage?
        let timestamp: Date?

        init(_ data: Data) throws {
            let root = try Proto(data)
            let modelInfo = try root.message(24)
            model = modelInfo?.text(12) ?? modelInfo?.text(8)
            usage = try root.message(9).map(Usage.init)
            timestamp = try root.message(8)?.timestamp ?? root.message(1)?.timestamp
        }
    }

    // The conversation store uses protobuf blobs. Decode only wire fields needed for usage reports.
    private struct Proto {
        private var numbers: [Int: [UInt64]] = [:]
        private var bytes: [Int: [Data]] = [:]

        init(_ data: Data) throws {
            var input = data[...]
            while !input.isEmpty {
                let tag = try Self.varint(&input)
                let field = Int(tag >> 3)
                guard field > 0 else { throw ReaderError.malformedProtobuf }
                switch tag & 7 {
                case 0: numbers[field, default: []].append(try Self.varint(&input))
                case 1: _ = try Self.take(8, from: &input)
                case 2:
                    let length = try Self.varint(&input)
                    guard let count = Int(exactly: length) else { throw ReaderError.malformedProtobuf }
                    bytes[field, default: []].append(try Self.take(count, from: &input))
                case 5: _ = try Self.take(4, from: &input)
                default: throw ReaderError.malformedProtobuf
                }
            }
        }

        var timestamp: Date? {
            let seconds = count(1)
            guard seconds > 0, seconds < 253_402_300_800 else { return nil }
            return Date(timeIntervalSince1970: Double(seconds) + Double(min(count(2), 999_999_999)) / 1e9)
        }

        func count(_ field: Int) -> Int64 {
            guard let value = numbers[field]?.last, value <= Int64.max / 100 else { return 0 }
            return Int64(value)
        }

        func text(_ field: Int) -> String? {
            guard let data = bytes[field]?.last, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        }

        func message(_ field: Int) throws -> Proto? { try bytes[field]?.first.map(Proto.init) }
        func messages(_ field: Int) throws -> [Proto] { try (bytes[field] ?? []).map(Proto.init) }

        func indices(_ field: Int) throws -> [Int64] {
            var values = numbers[field] ?? []
            for data in bytes[field] ?? [] {
                var remaining = data[...]
                while !remaining.isEmpty { values.append(try Self.varint(&remaining)) }
            }
            return values.compactMap(Int64.init(exactly:))
        }

        private static func varint(_ input: inout Data) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard let byte = input.popFirst(), shift < 63 || byte <= 1 else { throw ReaderError.malformedProtobuf }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw ReaderError.malformedProtobuf
        }

        private static func take(_ count: Int, from input: inout Data) throws -> Data {
            guard count <= input.count else { throw ReaderError.malformedProtobuf }
            let bytes = input.prefix(count)
            input = input.dropFirst(count)
            return bytes
        }
    }
}
