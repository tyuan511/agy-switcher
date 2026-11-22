import Foundation

enum AGYUsagePricing {
    static let source = URL(string: "https://cloud.google.com/model-garden/pricing")!
    static let partnerSource = URL(string: "https://cloud.google.com/model-garden/partner-models/pricing")!

    private struct Rate {
        let input: Double
        let cacheRead: Double
        let output: Double
        var cacheWrite: Double? = nil
    }

    // Google Cloud Agent Platform, Standard Model, Global. Rates are USD per million tokens.
    private static let dec2026 = Date(timeIntervalSince1970: 1_796_083_200)
    private static let jan2027 = Date(timeIntervalSince1970: 1_798_761_600)
    private static let cacheWriteStart = Date(timeIntervalSince1970: 1_799_712_000)

    static func estimate(_ event: AGYUsageEvent) -> Double? {
        guard let rate = rate(for: event), let writeRate = event.cacheWrite == 0 ? 0 : rate.cacheWrite else {
            return nil
        }
        return (Double(event.freshInput) * rate.input + Double(event.cachedInput) * rate.cacheRead
                + Double(event.cacheWrite) * writeRate + Double(event.output) * rate.output) / 1_000_000
    }

    private static func rate(for event: AGYUsageEvent) -> Rate? {
        switch modelFamily(event.model) {
        case "gemini-4-neon":
            return Rate(input: 3, cacheRead: 0.15, output: 15,
                        cacheWrite: event.timestamp >= cacheWriteStart ? 3.75 : nil)
        case "gemini-4-hydrogen":
            return Rate(input: 1.5, cacheRead: 0.075, output: 7.5,
                        cacheWrite: event.timestamp >= cacheWriteStart ? 1.875 : nil)
        case "gemini-4-carbon", "gemini-4-argon":
            return event.timestamp < dec2026 ? Rate(input: 2, cacheRead: 0.10, output: 10)
                : Rate(input: 4, cacheRead: 0.20, output: 20)
        case "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash":
            return event.timestamp < jan2027 ? Rate(input: 0.75, cacheRead: 0.075, output: 3.75)
                : Rate(input: 1.5, cacheRead: 0.15, output: 7.5)
        case "gemini-3.5-flash":
            return Rate(input: 1.5, cacheRead: 0.15, output: 9)
        case "gemini-3.5-flash-lite":
            return Rate(input: 0.30, cacheRead: 0.03, output: 2.50)
        case "gemini-3.1-flash-lite":
            return Rate(input: 0.25, cacheRead: 0.025, output: 1.50)
        case "gemini-3.1-pro", "gemini-3.1-pro-preview":
            return event.input <= 200_000 ? Rate(input: 2, cacheRead: 0.2, output: 12)
                : Rate(input: 4, cacheRead: 0.4, output: 18)
        case "gemini-3-flash-preview":
            return Rate(input: 0.5, cacheRead: 0.05, output: 3)
        case "claude-opus-5.5", "claude-opus-5-5":
            return Rate(input: 4, cacheRead: 0.20, output: 20, cacheWrite: 5)
        case "claude-sonnet-5.5", "claude-sonnet-5-5":
            return Rate(input: 2, cacheRead: 0.10, output: 10, cacheWrite: 2.50)
        default:
            return nil
        }
    }

    private static func modelFamily(_ name: String) -> String {
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let model = name.replacingOccurrences(of: #"\s*\((?:extra-low|low|medium|high|xhigh|max|thinking)\)$"#,
                                              with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        let slug = model.split(separator: "/").last.map(String.init) ?? model
        return slug.replacingOccurrences(of: #"-(?:extra-low|low|medium|high|xhigh|max|thinking)$"#,
                                         with: "", options: .regularExpression)
    }
}
