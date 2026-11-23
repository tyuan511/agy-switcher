import Foundation

enum AGYUsageTokenFormat {
    static func format(_ count: Double, in language: AppLanguage) -> String {
        guard count > 100_000 else { return count.formatted(.number.locale(language.locale)) }

        let (divisor, unit): (Double, String) = count >= 1_000_000_000 ? (1_000_000_000, "B") : (1_000_000, "M")
        let amount = (count / divisor).formatted(.number.precision(.fractionLength(0...2)).locale(language.locale))
        return amount + unit
    }
}

struct AGYUsageEvent: Sendable {
    let conversationID: String
    let timestamp: Date
    let model: String
    let freshInput: Int64
    let cachedInput: Int64
    let cacheWrite: Int64
    let output: Int64

    var input: Int64 { freshInput + cachedInput + cacheWrite }
}

struct AGYUsageTotals: Sendable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var output: Int64 = 0
    var estimatedUSD: Double?
    var unpricedModels: Set<String> = []

    var isEmpty: Bool { input == 0 && output == 0 }

    var cacheHitRate: Double? {
        guard input > 0 else { return nil }
        return Double(cachedInput) / Double(input)
    }

    mutating func add(_ other: Self) {
        input += other.input
        cachedInput += other.cachedInput
        output += other.output
        if let amount = other.estimatedUSD { estimatedUSD = (estimatedUSD ?? 0) + amount }
        unpricedModels.formUnion(other.unpricedModels)
    }

    mutating func add(_ event: AGYUsageEvent) {
        let estimate = AGYUsagePricing.estimate(event)
        add(.init(input: event.input, cachedInput: event.cachedInput, output: event.output, estimatedUSD: estimate,
                  unpricedModels: estimate == nil ? [event.model] : []))
    }
}

struct AGYUsageDay: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let totals: AGYUsageTotals
}

struct AGYUsageReport: Sendable {
    let totals: AGYUsageTotals
    let days: [AGYUsageDay]
    let skippedDatabases: Int

    init(events: [AGYUsageEvent], skippedDatabases: Int = 0,
         dayCount: Int = 7, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var overall = AGYUsageTotals()
        var byDay: [Date: AGYUsageTotals] = [:]

        for event in events where event.timestamp >= (dates.first ?? today) && event.timestamp <= now {
            let date = calendar.startOfDay(for: event.timestamp)
            var totals = AGYUsageTotals()
            totals.add(event)
            overall.add(totals)
            byDay[date, default: .init()].add(totals)
        }

        self.totals = overall
        days = dates.map { .init(date: $0, totals: byDay[$0, default: .init()]) }
        self.skippedDatabases = skippedDatabases
    }
}
