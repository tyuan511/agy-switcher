import Charts
import SwiftUI

struct UsagePage: View {
    private enum Destination: Hashable {
        case overview, account(String?)
    }

    private struct Refresh: Equatable {
        var days = 7
        var revision = 0
    }

    @Environment(\.appLanguage) private var language
    @Environment(\.appearsActive) private var appearsActive
    @State private var refresh = Refresh()
    @State private var destination = Destination.overview
    @State private var report: AGYUsageReport?
    @State private var trackingEnabled = false
    @State private var loadError: String?
    @State private var trackingError: String?
    private let tracking = AGYUsageTracking()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let trackingError {
                    Label(trackingError, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let loadError {
                    ContentUnavailableView {
                        Label(language.text("无法读取用量"), systemImage: "exclamationmark.circle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(language.text("重试"), action: reload)
                    }
                } else if let report {
                    if case let .account(email) = destination {
                        if let account = report.accounts.first(where: { $0.email == email }) {
                            accountDetail(account)
                        } else {
                            emptyState
                        }
                    } else {
                        overview(report)
                    }
                    if report.skippedDatabases > 0 {
                        Label(language.text("部分 agy 会话暂时无法读取。"), systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    pricingNote
                } else {
                    ProgressView(language.text("正在读取本机用量…"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(22)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .id(destination)
        .task(id: refresh) { await load() }
        .onChange(of: appearsActive) { _, active in
            if active { reload() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if trackingEnabled {
                        Button(language.text("停用账号关联")) { setTracking(false) }
                    } else {
                        Button(language.text("启用账号关联")) { setTracking(true) }
                    }
                } label: {
                    Label(language.text("agy 账号关联"), systemImage: trackingEnabled ? "link" : "link.badge.plus")
                        .labelStyle(.iconOnly)
                }
                Button(language.text("刷新用量"), systemImage: "arrow.clockwise", action: reload)
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .account = destination {
                Button(language.text("所有账号"), systemImage: "chevron.left") { destination = .overview }
                    .buttonStyle(.borderless)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    headerTitle
                    Spacer(minLength: 0)
                    rangePicker
                }
                VStack(alignment: .leading, spacing: 10) {
                    headerTitle
                    rangePicker
                }
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch destination {
            case .overview:
                Text(language.text("本机 agy 用量")).font(.title2.weight(.semibold))
            case let .account(email):
                Text(verbatim: accountName(email))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(accountName(email))
            }
            if let days = report?.days, let first = days.first, let last = days.last {
                Text(date(first.date) + " – " + date(last.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rangePicker: some View {
        Picker(language.text("统计范围"), selection: $refresh.days) {
            Text(language.text("近 7 天")).tag(7)
            Text(language.text("近 30 天")).tag(30)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func overview(_ report: AGYUsageReport) -> some View {
        Group {
            if !trackingEnabled { trackingPrompt }
            metrics(report.totals)
            if report.accounts.isEmpty {
                emptyState
            } else {
                UsageTrend(days: report.days)
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("按账号查看")).font(.headline)
                    VStack(spacing: 0) {
                        ForEach(report.accounts) { account in
                            if account.email != report.accounts.first?.email { Divider().padding(.horizontal, 14) }
                            accountRow(account)
                        }
                    }
                    .usagePanel()
                }
            }
        }
    }

    private var trackingPrompt: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                trackingPromptText
                Spacer(minLength: 0)
                trackingButton
            }
            VStack(alignment: .leading, spacing: 10) {
                trackingPromptText
                trackingButton
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .usagePanel()
    }

    private var trackingPromptText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(language.text("关联 agy 登录账号"), systemImage: "link")
                .font(.subheadline.weight(.semibold))
            Text(language.text("启用后，新启动的交互式 agy 会话可按登录邮箱统计。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var trackingButton: some View {
        Button(language.text("启用账号关联")) { setTracking(true) }
            .buttonStyle(.glass)
            .fixedSize()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(language.text("这段时间暂无用量"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(language.text("用量来自本机 agy 保存的会话。"))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .usagePanel()
    }

    private func metrics(_ totals: AGYUsageTotals) -> some View {
        HStack(spacing: 8) {
            metric(language.text("输入 Token"), value: tokens(totals.input), symbol: "arrow.down.left", tint: .teal)
            metric(language.text("输出 Token"), value: tokens(totals.output), symbol: "arrow.up.right", tint: .indigo)
            metric(language.text("美元估值"), value: estimate(totals), symbol: "dollarsign.circle", tint: .orange)
        }
    }

    private func metric(_ label: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.18)) }
    }

    private func accountRow(_ account: AGYUsageAccount) -> some View {
        Button {
            destination = .account(account.email)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: account.email == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(account.email == nil ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: accountName(account.email)).fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(language.text("输入 \(tokens(account.totals.input)) · 输出 \(tokens(account.totals.output))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(verbatim: estimate(account.totals)).monospacedDigit().lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accountName(account.email))
    }

    private func accountDetail(_ account: AGYUsageAccount) -> some View {
        Group {
            metrics(account.totals)
            UsageTrend(days: account.days)
            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("每日明细")).font(.headline)
                VStack(spacing: 0) {
                    Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 9) {
                        GridRow {
                            Text(language.text("日期")).gridColumnAlignment(.leading)
                            Text(language.text("输入 Token"))
                            Text(language.text("输出 Token"))
                            Text(language.text("美元估值"))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(account.days.reversed()) { day in
                            GridRow {
                                Text(date(day.date)).foregroundStyle(.secondary)
                                Text(tokens(day.totals.input))
                                Text(tokens(day.totals.output))
                                Text(estimate(day.totals))
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .usagePanel()
            }
            if account.email == nil {
                Text(language.text("未关联包括启用前的用量，以及无法确认登录账号的会话。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pricingNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Link(language.text("Google Cloud 官方模型价格"), destination: AGYUsagePricing.source)
                Link("Claude", destination: AGYUsagePricing.partnerSource)
            }
            Text(language.text("美元估值按公开模型标价计算，仅供参考。部分模型暂无可用估价。"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func accountName(_ email: String?) -> String { email ?? language.text("未关联账号") }
    private func date(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day().locale(language.locale)) }
    private func tokens(_ total: Int64) -> String { total.formatted(.number.locale(language.locale)) }

    private func estimate(_ totals: AGYUsageTotals) -> String {
        guard let usd = totals.estimatedUSD else { return "—" }
        let amount = usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4)).locale(language.locale))
        return totals.unpricedModels.isEmpty ? amount : language.text("\(amount)（部分）")
    }

    private func reload() { refresh.revision += 1 }

    private func setTracking(_ enabled: Bool) {
        guard let binary = Bundle.main.executableURL else { return }
        do {
            try tracking.setEnabled(enabled, executable: binary)
            trackingEnabled = enabled
            trackingError = nil
            reload()
        } catch {
            trackingError = language.text("无法更新 agy 账号关联。\(error.localizedDescription)")
        }
    }

    private func load() async {
        let tracking = tracking
        let dayCount = refresh.days
        let task = Task.detached(priority: .userInitiated) {
            let reader = AGYUsageDatabase(directory: AGYUsageTracking.cliDirectory.appending(path: "conversations"))
            return try reader.report(observations: tracking.observations(), dayCount: dayCount)
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            report = result
            loadError = nil
            if let binary = Bundle.main.executableURL, let enabled = try? tracking.isEnabled(executable: binary) {
                trackingEnabled = enabled
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
}

private struct UsageTrend: View {
    private enum Metric: Hashable { case tokens, usd }

    let days: [AGYUsageDay]
    @Environment(\.appLanguage) private var language
    @State private var metric: Metric = .tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("每日趋势")).font(.headline)
                Spacer()
                Picker(language.text("图表指标"), selection: $metric) {
                    Text("Token").tag(Metric.tokens)
                    Text("USD").tag(Metric.usd)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if metric == .usd && !days.contains(where: { $0.totals.estimatedUSD != nil }) {
                Text(language.text("暂无可估价的用量"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 164)
            } else {
                chart.frame(height: 164)
            }
            if metric == .tokens {
                HStack(spacing: 14) {
                    legend(language.text("输入 Token"), color: .teal)
                    legend(language.text("输出 Token"), color: .indigo)
                }
            }
        }
        .padding(14)
        .usagePanel()
    }

    private var chart: some View {
        Chart(days) { day in
            if metric == .tokens {
                BarMark(x: .value(language.text("日期"), day.date, unit: .day),
                        y: .value(language.text("输入 Token"), day.totals.input))
                    .foregroundStyle(by: .value(language.text("图表指标"), language.text("输入 Token")))
                BarMark(x: .value(language.text("日期"), day.date, unit: .day),
                        y: .value(language.text("输出 Token"), day.totals.output))
                    .foregroundStyle(by: .value(language.text("图表指标"), language.text("输出 Token")))
            } else if let amount = day.totals.estimatedUSD {
                BarMark(x: .value(language.text("日期"), day.date, unit: .day),
                        y: .value(language.text("美元估值"), amount))
                    .foregroundStyle(Color.orange.gradient)
            }
        }
        .chartForegroundStyleScale([language.text("输入 Token"): Color.teal, language.text("输出 Token"): Color.indigo])
        .chartXScale(domain: dateDomain)
        .chartXAxis {
            AxisMarks(values: axisDates) {
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day().locale(language.locale))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if metric == .tokens, let count = value.as(Int64.self) {
                        Text(count.formatted(.number.notation(.compactName).locale(language.locale)))
                    } else if metric == .tokens, let count = value.as(Double.self) {
                        Text(count.formatted(.number.notation(.compactName).locale(language.locale)))
                    } else if metric == .usd, let usd = value.as(Double.self) {
                        Text(usd.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(language.locale)))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private var dateDomain: ClosedRange<Date> {
        let first = days.first?.date ?? .now
        let last = days.last?.date ?? first
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var axisDates: [Date] {
        let stride = days.count > 7 ? 5 : 1
        return days.enumerated().compactMap { index, day in
            guard index % stride == 0 else { return nil }
            return Calendar.current.date(byAdding: .hour, value: 12, to: day.date)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func usagePanel() -> some View {
        background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
    }
}
