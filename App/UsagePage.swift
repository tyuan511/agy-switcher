import SwiftUI

struct UsagePage: View {
    private struct Refresh: Equatable {
        // 演示模式默认展示近 7 天，与 README 截图说明一致。
        var days = AppLaunch.isDemoUsage ? 7 : 1
        var revision = 0
    }

    @Environment(\.appLanguage) private var language
    @Environment(\.appearsActive) private var appearsActive
    @State private var refresh = Refresh()
    @State private var report: AGYUsageReport?
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let loadError {
                    ContentUnavailableView {
                        Label(language.text("无法读取用量"), systemImage: "exclamationmark.circle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button(language.text("重试"), action: reload)
                    }
                } else if let report {
                    overview(report)
                    if report.skippedDatabases > 0 {
                        MessageBar(
                            text: language.text("部分本地会话暂时无法读取。"),
                            symbol: "exclamationmark.triangle.fill",
                            tone: .warning
                        )
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
        .task(id: refresh) { await load() }
        .onChange(of: appearsActive) { _, active in
            if active { reload() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(language.text("刷新用量"), systemImage: "arrow.clockwise", action: reload)
                    .labelStyle(.iconOnly)
                    .disabled(loading)
                    .help(language.text("刷新用量"))
            }
        }
    }

    private var header: some View {
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

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text("本机用量")).font(.title2.weight(.semibold))
            if let days = report?.days, let first = days.first, let last = days.last {
                Text(first.date == last.date ? date(first.date) : date(first.date) + " – " + date(last.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rangePicker: some View {
        Picker(language.text("统计范围"), selection: $refresh.days) {
            Text(language.text("今天")).tag(1)
            Text(language.text("近 7 天")).tag(7)
            Text(language.text("近 30 天")).tag(30)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func overview(_ report: AGYUsageReport) -> some View {
        Group {
            metrics(report.totals)
            if report.totals.isEmpty {
                emptyState
            } else {
                UsageTrend(days: report.days)
                dailyBreakdown(report.days)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(language.text("这段时间暂无用量"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(language.text("用量来自本机 Antigravity 与 agy 保存的会话。"))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .usagePanel()
    }

    private func metrics(_ totals: AGYUsageTotals) -> some View {
        let cards = Group {
            metric(language.text("输入 Token"), value: tokens(totals.input), symbol: "arrow.down.left", tint: .teal)
            metric(language.text("输出 Token"), value: tokens(totals.output), symbol: "arrow.up.right", tint: .indigo)
            metric(language.text("美元估值"), value: estimate(totals), symbol: "dollarsign.circle", tint: .orange)
            metric(language.text("缓存命中率"), value: cacheRate(totals),
                   symbol: "gauge.with.dots.needle.50percent", tint: .purple)
                .help(language.text("从缓存读取的 Token 占全部输入 Token 的比例。"))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { cards }
                .frame(minWidth: 520)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                cards
            }
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.2))
                .allowsHitTesting(false)
        }
    }

    private func dailyBreakdown(_ days: [AGYUsageDay]) -> some View {
        let rows = Array(days.reversed())
        return VStack(alignment: .leading, spacing: 10) {
            Text(language.text("每日明细")).font(.headline)
            VStack(spacing: 0) {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(language.text("日期"))
                            .gridColumnAlignment(.leading)
                        Text(language.text("输入 Token"))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(language.text("输出 Token"))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(language.text("美元估值"))
                            .frame(minWidth: 128, maxWidth: .infinity, alignment: .trailing)
                        Text(language.text("缓存命中率"))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, day in
                        if index > 0 {
                            Divider()
                                .opacity(0.45)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                        GridRow {
                            Text(date(day.date))
                                .foregroundStyle(day.totals.isEmpty ? .tertiary : .secondary)
                            Text(tokens(day.totals.input))
                            Text(tokens(day.totals.output))
                            Text(estimate(day.totals))
                            Text(cacheRate(day.totals))
                        }
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(day.totals.isEmpty ? .tertiary : .primary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .usagePanel()
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

    private func date(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day().locale(language.locale)) }
    private func tokens(_ total: Int64) -> String { AGYUsageTokenFormat.format(Double(total), in: language) }

    private func cacheRate(_ totals: AGYUsageTotals) -> String {
        guard let rate = totals.cacheHitRate else { return "—" }
        return rate.formatted(.percent.precision(.fractionLength(0...1)).locale(language.locale))
    }

    private func estimate(_ totals: AGYUsageTotals) -> String {
        totals.formattedEstimate(in: language)
    }

    private func reload() { refresh.revision += 1 }

    private func load() async {
        loading = true
        defer { loading = false }
        if AppLaunch.isDemoUsage {
            report = AGYUsageDemo.report(dayCount: refresh.days)
            loadError = nil
            return
        }
        do {
            let result = try await AGYUsageDatabase.localReport(dayCount: refresh.days)
            guard !Task.isCancelled else { return }
            report = result
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
}

private extension View {
    func usagePanel() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
    }
}

extension AGYUsageTotals {
    func formattedEstimate(in language: AppLanguage, maximumFractionDigits: Int = 4) -> String {
        guard let estimatedUSD else { return "—" }
        let amount = estimatedUSD.formatted(
            .currency(code: "USD").precision(.fractionLength(2...maximumFractionDigits)).locale(language.locale)
        )
        return unpricedModels.isEmpty ? amount : language.text("\(amount)（部分）")
    }
}
