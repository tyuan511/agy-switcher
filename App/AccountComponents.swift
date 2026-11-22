import SwiftUI

struct SwitchButton: View {
    let model: AccountsModel
    let account: Account
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button {
            model.switchTo(account)
        } label: {
            if model.switching == account.id {
                ProgressView().controlSize(.small).accessibilityLabel(language.text("正在切换"))
            } else {
                Text(language.text("切换"))
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(model.changing || model.needsAuthorization.contains(account.id))
        .accessibilityLabel(language.text("切换到 \(account.identity.email)"))
    }
}

struct MessageBar: View {
    let text: String
    let symbol: String
    var dismiss: (() -> Void)?
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(language.text("关闭提示"), systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

struct AccountQuota: View {
    let model: AccountsModel
    let account: Account
    var remove: (() -> Void)? = nil
    @Environment(\.appLanguage) private var language

    private var refreshing: Bool { model.refreshing.contains(account.id) }
    private var current: Bool { model.active == .managed(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.identity.email)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = account.quota?.tier, !plan.isEmpty {
                    SubscriptionBadge(plan: plan)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                if refreshing {
                    ProgressView().controlSize(.small).accessibilityLabel(language.text("正在刷新配额"))
                }
                if let remove {
                    Menu {
                        Button(language.text("刷新配额"), systemImage: "arrow.clockwise") { model.refresh(account.id) }
                            .disabled(refreshing)
                        Button(language.text("重新授权"), systemImage: "person.crop.circle") { model.add(account) }
                            .disabled(model.changing || refreshing)
                        Button(language.text("移除账号"), systemImage: "trash", role: .destructive, action: remove)
                            .disabled(model.changing || refreshing)
                    } label: {
                        Label(language.text("账号操作"), systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if current {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .help(language.text("当前账号"))
                        .accessibilityLabel(language.text("当前账号"))
                } else {
                    SwitchButton(model: model, account: account)
                }
            }

            if let snapshot = account.quota {
                QuotaUsage(snapshot: snapshot)
            } else if !refreshing && model.quotaErrors[account.id] == nil {
                Text(language.text("暂无配额")).font(.caption).foregroundStyle(.secondary)
            }

            if let error = model.quotaErrors[account.id] {
                let title = language.text(model.needsAuthorization.contains(account.id) ? "需要重新授权" : "配额刷新失败")
                Label(title, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(language.errorDescription(error))
            }
        }
    }
}

private struct SubscriptionBadge: View {
    let plan: String
    @Environment(\.appLanguage) private var language

    private var palette: (start: Color, end: Color) {
        switch plan {
        case "Pro": (.blue, .purple)
        case "Ultra": (.indigo, .pink)
        default: (.secondary, .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if plan == "Pro" || plan == "Ultra" {
                Image(systemName: "sparkle")
                    .foregroundStyle(gradient(opacity: 1))
                    .accessibilityHidden(true)
            }
            Text(plan)
                .foregroundStyle(plan == "Free" ? .secondary : .primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(palette.start.opacity(0.09), in: .capsule)
        .overlay {
            Capsule().strokeBorder(gradient(opacity: 0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("订阅计划 \(plan)"))
    }

    private func gradient(opacity: Double) -> LinearGradient {
        LinearGradient(colors: [palette.start.opacity(opacity), palette.end.opacity(opacity)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

private struct QuotaUsage: View {
    let snapshot: QuotaSnapshot
    @Environment(\.appLanguage) private var language

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 11) {
                ForEach(QuotaGroup.groups(for: snapshot, language: language)) { group in
                    if let entry = group.entries.first, group.entries.count == 1 {
                        QuotaUsageRow(
                            title: group.name, caption: snapshot.partial ? nil : entry.windowTitle(in: language),
                            entry: entry, now: context.date, primary: true
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.name).font(.subheadline.weight(.semibold))
                            ForEach(group.entries) { entry in
                                QuotaUsageRow(
                                    title: entry.windowTitle(in: language) ?? entry.name, caption: nil,
                                    entry: entry, now: context.date, primary: false
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct QuotaUsageRow: View {
    let title: String
    let caption: String?
    let entry: QuotaEntry
    let now: Date
    let primary: Bool
    @Environment(\.appLanguage) private var language

    private var percent: String {
        entry.fraction.formatted(.percent.precision(.fractionLength(0)).locale(language.locale))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(primary ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(primary ? .primary : .secondary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(language.text("剩余 \(percent)"))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            Gauge(value: entry.fraction) { Text(language.text("剩余配额")) }
                .gaugeStyle(QuotaRingStyle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        guard let reset = entry.resetsAt else { return caption }
        let seconds = reset.timeIntervalSince(now)
        let countdown: String
        switch seconds {
        case ...0:
            countdown = language.text("已到重置时间")
        case ..<60:
            countdown = language.text("不到 1 分钟后重置")
        default:
            let remaining = Duration.seconds((seconds / 60).rounded(.down) * 60)
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)
                    .locale(language.locale))
            countdown = language.text("\(remaining)后重置")
        }
        return [caption, countdown].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct QuotaRingStyle: GaugeStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().strokeBorder(.quaternary, lineWidth: 2)
            Circle().inset(by: 1)
                .trim(from: 0, to: configuration.value)
                .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}
