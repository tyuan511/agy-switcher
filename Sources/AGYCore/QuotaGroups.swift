import Foundation

struct QuotaGroup: Identifiable {
    let id: String
    let name: String
    let entries: [QuotaEntry]

    private static let knownGroups: [(id: String, name: String.LocalizationValue)] = [
        (id: "gemini", name: "Gemini 模型"),
        (id: "claude", name: "Claude 和 GPT 模型"),
        (id: "argon", name: "Gemini 4 Argon"),
        (id: "carbon", name: "Gemini 4 Carbon"),
    ]

    static func groups(for snapshot: QuotaSnapshot, language: AppLanguage = .simplifiedChinese) -> [Self] {
        if snapshot.partial {
            return snapshot.entries.map { Self(id: $0.id, name: $0.name, entries: [$0]) }
        }

        let buckets = Dictionary(grouping: snapshot.entries, by: \.modelGroupID)
        let known = knownGroups.compactMap { group in
            buckets[group.id].map { Self(id: group.id, name: language.text(group.name), entries: sortWindows($0)) }
        }
        let remaining = buckets.compactMap { id, entries -> Self? in
            guard !knownGroups.contains(where: { $0.id == id }), let entry = entries.first else { return nil }
            let name = entries.compactMap(\.groupName).first ?? (entry.windowTitle(in: language) == nil ? entry.name : id)
            return Self(id: id, name: name, entries: sortWindows(entries))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return known + remaining
    }

    private static func sortWindows(_ entries: [QuotaEntry]) -> [QuotaEntry] {
        entries.sorted { first, second in
            if first.period != second.period { return first.period.rawValue < second.period.rawValue }
            return first.id < second.id
        }
    }
}

extension QuotaEntry {
    fileprivate enum Period: Int {
        case weekly, fiveHours, other
    }

    fileprivate var period: Period {
        let suffix = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == ":" }).last
        return switch suffix {
        case "weekly": .weekly
        case "5h": .fiveHours
        default: .other
        }
    }

    func windowTitle(in language: AppLanguage = .simplifiedChinese) -> String? {
        switch period {
        case .weekly: return language.text("每周额度")
        case .fiveHours: return language.text("5 小时额度")
        case .other:
            switch window {
            case "每周": return language.text("每周")
            case "5 小时": return language.text("5 小时")
            default: return window
            }
        }
    }

    fileprivate var modelGroupID: String {
        let key = id.lowercased()
        let stem: String
        switch period {
        case .weekly: stem = String(key.dropLast("-weekly".count))
        case .fiveHours: stem = String(key.dropLast("-5h".count))
        case .other: return groupName.map { "group:" + $0 } ?? key
        }
        switch stem {
        case "3p", "claude": return "claude"
        case "gemini-argon-wtu", "argon": return "argon"
        case "gemini-carbon-wtu", "carbon": return "carbon"
        default: return stem
        }
    }
}
