import Foundation

/// 生成 README 截图用的虚构账号与配额。数值固定可复现，重置倒计时相对启动时间计算，
/// 保证截图时倒计时文案可读。
enum AGYAccountsDemo {
    static var accounts: [Account] {
        let now = Date.now
        func entry(_ id: String, _ window: String, _ fraction: Double, resetsIn: TimeInterval) -> QuotaEntry {
            QuotaEntry(id: id, name: window, window: window, fraction: fraction,
                       resetsAt: now.addingTimeInterval(resetsIn))
        }

        let day: TimeInterval = 86_400
        let hour: TimeInterval = 3_600
        return [
            Account(
                identity: GoogleIdentity(id: "demo-alex", email: "alex@example.com", name: nil),
                quota: QuotaSnapshot(
                    entries: [
                        entry("gemini-weekly", "每周", 0.82, resetsIn: 2 * day + 23 * hour),
                        entry("gemini-5h", "5 小时", 0.63, resetsIn: 2 * hour + 57 * 60),
                        entry("claude-weekly", "每周", 0.46, resetsIn: day + 21 * hour),
                        entry("claude-5h", "5 小时", 0.29, resetsIn: hour + 33 * 60),
                    ],
                    updatedAt: now, tier: "Pro", partial: false
                )
            ),
            Account(
                identity: GoogleIdentity(id: "demo-morgan", email: "morgan@example.com", name: nil),
                quota: QuotaSnapshot(
                    entries: [
                        entry("gemini-weekly", "每周", 0.91, resetsIn: 4 * day + 3 * hour),
                        entry("claude-5h", "5 小时", 0.75, resetsIn: 4 * hour + 7 * 60),
                    ],
                    updatedAt: now, tier: "Free", partial: false
                )
            ),
        ]
    }
}
