import Foundation

/// 生成 README 截图用的虚构用量报表。数据固定可复现：以周日节奏为基底，
/// 按天做确定性扰动，全部使用有标价的模型，保证美元估值无「部分」标注。
enum AGYUsageDemo {
    /// 一周七天的用量系数（周日开头），周末偏低。
    private static let dayShapes: [Double] = [0.6, 1.0, 1.1, 0.9, 1.2, 1.0, 0.7]
    /// 每天拆成三笔调用：输入占比、缓存占比、距离当天零点的小时数。
    private static let calls: [(input: Double, cached: Double, hour: Int)] = [
        (0.45, 0.62, 9), (0.35, 0.55, 13), (0.20, 0.60, 17),
    ]

    static func report(dayCount: Int, now: Date = .now, calendar: Calendar = .current) -> AGYUsageReport {
        let today = calendar.startOfDay(for: now)
        var events: [AGYUsageEvent] = []
        for dayIndex in 0..<dayCount {
            let date = calendar.date(byAdding: .day, value: -dayIndex, to: today)!
            let weekday = calendar.component(.weekday, from: date)
            let wobble = 0.8 + 0.4 * Double((dayIndex * 17) % 10) / 9
            let input = Int64(460_000 * dayShapes[weekday - 1] * wobble)
            let output = Int64(Double(input) * (0.09 + 0.04 * Double((dayIndex * 7) % 5) / 4))
            events += self.events(day: date, dayIndex: dayIndex, input: input, output: output,
                                  now: now, calendar: calendar)
        }
        return AGYUsageReport(events: events, dayCount: dayCount, now: now, calendar: calendar)
    }

    private static func events(day: Date, dayIndex: Int, input: Int64, output: Int64,
                               now: Date, calendar: Calendar) -> [AGYUsageEvent] {
        let outputShares = [0.5, 0.3, 0.2]
        return calls.enumerated().map { index, call in
            // 缓存占比按天和调用位置小幅扰动，避免每天的命中率一模一样。
            let cached = min(0.7, max(0.4, call.cached + Double((dayIndex * 11 + index * 7) % 5 - 2) / 50))
            let eventInput = Int64(Double(input) * call.input)
            // 今天的调用按「距现在」回退，避免时间落在未来而被报表过滤掉。
            let timestamp = dayIndex == 0
                ? now - TimeInterval((2 - index) * 40 * 60)
                : calendar.date(byAdding: .hour, value: call.hour, to: day)!
            return AGYUsageEvent(
                conversationID: "demo-\(Int(day.timeIntervalSince1970))-\(index)",
                timestamp: timestamp,
                model: index == 2 ? "claude-sonnet-5-5" : "gemini-3.1-pro (high)",
                freshInput: Int64(Double(eventInput) * (1 - cached)),
                cachedInput: Int64(Double(eventInput) * cached),
                cacheWrite: 0,
                output: Int64(Double(output) * outputShares[index])
            )
        }
    }
}
