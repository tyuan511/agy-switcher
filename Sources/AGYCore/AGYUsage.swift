import Foundation

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
    var output: Int64 = 0
    var estimatedUSD: Double?
    var unpricedModels: Set<String> = []

    mutating func add(_ other: Self) {
        input += other.input
        output += other.output
        if let amount = other.estimatedUSD { estimatedUSD = (estimatedUSD ?? 0) + amount }
        unpricedModels.formUnion(other.unpricedModels)
    }

    mutating func add(_ event: AGYUsageEvent) {
        let estimate = AGYUsagePricing.estimate(event)
        add(.init(input: event.input, output: event.output, estimatedUSD: estimate,
                  unpricedModels: estimate == nil ? [event.model] : []))
    }
}

struct AGYUsageDay: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let totals: AGYUsageTotals
}

struct AGYUsageAccount: Identifiable, Sendable {
    var id: String? { email }
    let email: String?
    let totals: AGYUsageTotals
    let days: [AGYUsageDay]
}

struct AGYUsageReport: Sendable {
    let totals: AGYUsageTotals
    let days: [AGYUsageDay]
    let accounts: [AGYUsageAccount]
    let skippedDatabases: Int

    init(events: [AGYUsageEvent], observations: [AGYUsageObservation] = [], skippedDatabases: Int = 0,
         dayCount: Int = 7, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let observationsByConversation = Dictionary(grouping: observations, by: \.conversationID)
        var overall = AGYUsageTotals()
        var byDay: [Date: AGYUsageTotals] = [:]
        var byAccount: [String?: [Date: AGYUsageTotals]] = [:]

        for event in events where event.timestamp >= (dates.first ?? today) && event.timestamp <= now {
            let date = calendar.startOfDay(for: event.timestamp)
            let matches = observationsByConversation[event.conversationID.lowercased()] ?? []
            let owners = Set(matches.map(\.email))
            let observed = matches.contains { $0.firstSeenAt <= event.timestamp && event.timestamp <= $0.lastSeenAt }
            let email = owners.count == 1 && observed ? owners.first : nil
            var totals = AGYUsageTotals()
            totals.add(event)
            overall.add(totals)
            byDay[date, default: .init()].add(totals)
            byAccount[email, default: [:]][date, default: .init()].add(totals)
        }

        self.totals = overall
        days = dates.map { .init(date: $0, totals: byDay[$0, default: .init()]) }
        accounts = byAccount.map { email, perDay in
            let days = dates.map { AGYUsageDay(date: $0, totals: perDay[$0, default: .init()]) }
            let totals = days.reduce(into: AGYUsageTotals()) { $0.add($1.totals) }
            return AGYUsageAccount(email: email, totals: totals, days: days)
        }.sorted { first, second in
            if (first.email == nil) != (second.email == nil) { return first.email != nil }
            let firstTotal = first.totals.input + first.totals.output
            let secondTotal = second.totals.input + second.totals.output
            if firstTotal != secondTotal { return firstTotal > secondTotal }
            return (first.email ?? "") < (second.email ?? "")
        }
        self.skippedDatabases = skippedDatabases
    }
}
