import Charts
import SwiftUI

struct UsageTrend: View {
    private enum Metric: Hashable { case tokens, usd }

    private enum Series: Hashable {
        case input, output, usd

        var title: String.LocalizationValue {
            switch self {
            case .input: "输入 Token"
            case .output: "输出 Token"
            case .usd: "美元估值"
            }
        }

        var tint: Color {
            switch self {
            case .input: .teal
            case .output: .indigo
            case .usd: .orange
            }
        }

        func amount(_ totals: AGYUsageTotals) -> Double? {
            switch self {
            case .input: Double(totals.input)
            case .output: Double(totals.output)
            case .usd: totals.estimatedUSD
            }
        }

        func formatted(_ totals: AGYUsageTotals, in language: AppLanguage) -> String {
            switch self {
            case .input: AGYUsageTokenFormat.format(Double(totals.input), in: language)
            case .output: AGYUsageTokenFormat.format(Double(totals.output), in: language)
            case .usd: totals.formattedEstimate(in: language, maximumFractionDigits: 9)
            }
        }
    }

    let days: [AGYUsageDay]
    @Environment(\.appLanguage) private var language
    @State private var metric: Metric = .tokens
    @State private var isolatedSeries: Series?
    @State private var hoveredDate: Date?
    @State private var pinnedDate: Date?

    private var visibleSeries: [Series] {
        if metric == .usd { return [.usd] }
        if let isolatedSeries { return [isolatedSeries] }
        return [.input, .output]
    }

    private var selectedIndex: Int? {
        if let date = pinnedDate ?? hoveredDate, let index = days.firstIndex(where: { $0.date == date }) {
            return index
        }
        let series = visibleSeries
        return days.lastIndex { day in
            series.contains { item in
                item == .usd ? item.amount(day.totals) != nil : (item.amount(day.totals) ?? 0) > 0
            }
        } ?? days.indices.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if metric == .usd && !days.contains(where: { $0.totals.estimatedUSD != nil }) {
                Text(language.text("暂无可估价的用量"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 172)
            } else if let selectedIndex {
                chart(selectedIndex: selectedIndex)
                    .frame(height: 172)
                    .animation(.snappy(duration: 0.2), value: metric)
                    .animation(.snappy(duration: 0.2), value: isolatedSeries)
                details(for: selectedIndex)
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .onChange(of: days.map(\.date)) { _, dates in
            hoveredDate = nil
            if let pinnedDate, !dates.contains(pinnedDate) { self.pinnedDate = nil }
        }
        .onChange(of: metric) { _, _ in hoveredDate = nil }
    }

    private var header: some View {
        let title = Text(language.text("每日趋势")).font(.headline)
        let picker = Picker(language.text("图表指标"), selection: $metric) {
            Text("Token").tag(Metric.tokens)
            Text("USD").tag(Metric.usd)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        let filters = HStack(spacing: 6) {
            seriesButton(.input)
            seriesButton(.output)
        }
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 0)
                if metric == .tokens { filters }
                picker
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    title
                    Spacer()
                    picker
                }
                if metric == .tokens { filters }
            }
        }
    }

    private func seriesButton(_ series: Series) -> some View {
        let isVisible = isolatedSeries == nil || isolatedSeries == series
        let hint = language.text(isolatedSeries == series ? "显示全部 Token" : "仅显示此序列")
        return Button {
            isolatedSeries = isolatedSeries == series ? nil : series
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(series.tint.opacity(isVisible ? 1 : 0.35))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(language.text(series.title))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isVisible ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isVisible ? series.tint.opacity(0.12) : Color.primary.opacity(0.04), in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(isVisible ? series.tint.opacity(0.28) : .clear)
                    .allowsHitTesting(false)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isVisible ? .isSelected : [])
    }

    private func chart(selectedIndex: Int) -> some View {
        let series = visibleSeries
        let peak = days.lazy.flatMap { day in series.compactMap { $0.amount(day.totals) } }.max() ?? 0
        let dateLabel = language.text("日期")
        let isGrouped = series.count > 1
        let halfWidth = isGrouped ? 0.13 : 0.21
        return Chart {
            RectangleMark(
                xStart: .value(dateLabel, Double(selectedIndex) - 0.5),
                xEnd: .value(dateLabel, Double(selectedIndex) + 0.5),
                yStart: nil,
                yEnd: nil
            )
            .foregroundStyle(Color.accentColor.opacity(pinnedDate == nil ? 0.07 : 0.13))
            .accessibilityHidden(true)

            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                ForEach(series, id: \.self) { item in
                    if let amount = item.amount(day.totals), amount > 0 {
                        let label = language.text(item.title)
                        let offset = item == .input ? -0.16 : 0.16
                        let center = Double(index) + (isGrouped ? offset : 0)
                        RectangleMark(
                            xStart: .value(dateLabel, center - halfWidth),
                            xEnd: .value(dateLabel, center + halfWidth),
                            yStart: .value(label, 0.0),
                            yEnd: .value(label, amount)
                        )
                        .cornerRadius(3)
                        .foregroundStyle(item.tint.gradient)
                        .accessibilityLabel(dayLabel(day.date))
                        .accessibilityValue("\(label) \(item.formatted(day.totals, in: language))")
                    }
                }
            }
        }
        .chartXScale(domain: -0.5...(Double(days.count) - 0.5), range: .plotDimension)
        .chartYScale(domain: 0...(peak > 0 ? peak * 1.16 : 1), range: .plotDimension)
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 8))
                .clipShape(.rect(cornerRadius: 8))
        }
        .chartXAxis {
            AxisMarks(values: axisIndices) { tick in
                if let index = tick.as(Double.self).map(Int.init), days.indices.contains(index) {
                    AxisValueLabel(centered: false) {
                        Text(days[index].date, format: .dateTime.month(.defaultDigits).day().locale(language.locale))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { tick in
                if let value = tick.as(Double.self) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.primary.opacity(value == 0 ? 0.15 : 0.07))
                    AxisValueLabel {
                        Text(axisLabel(value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                let date = date(at: location.x, in: proxy)
                                if hoveredDate != date { hoveredDate = date }
                            case .ended:
                                hoveredDate = nil
                            }
                        }
                        .onTapGesture { location in
                            if let date = date(at: location.x, in: proxy) { togglePin(date) }
                        }
                        .help(language.text("悬停预览，点击固定日期"))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var axisIndices: [Double] {
        let interval = days.count > 7 ? 5 : 1
        return days.indices.filter { $0.isMultiple(of: interval) || $0 == days.count - 1 }.map(Double.init)
    }

    private func axisLabel(_ value: Double) -> String {
        if metric == .usd {
            return value.formatted(.currency(code: "USD").precision(.significantDigits(1...3)).locale(language.locale))
        }
        return AGYUsageTokenFormat.format(value, in: language)
    }

    private func date(at x: CGFloat, in proxy: ChartProxy) -> Date? {
        guard let position = proxy.value(atX: x, as: Double.self), let last = days.indices.last else { return nil }
        let index = min(max(Int(position.rounded()), 0), last)
        return days[index].date
    }

    private func details(for index: Int) -> some View {
        let day = days[index]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                dayControls(for: index)
                Spacer(minLength: 0)
                dayValues(day)
            }
            VStack(alignment: .leading, spacing: 8) {
                dayControls(for: index)
                dayValues(day)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 8))
    }

    private func dayControls(for index: Int) -> some View {
        let date = days[index].date
        let isPinned = pinnedDate == date
        let pinTitle = language.text(isPinned ? "取消固定日期" : "固定日期")
        return HStack(spacing: 7) {
            Text(dayLabel(date))
                .font(.callout.weight(.semibold))
            Button(pinTitle, systemImage: isPinned ? "pin.fill" : "pin") { togglePin(date) }
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .help(pinTitle)
            dayButton(-1, from: index, title: language.text("前一天"), symbol: "chevron.left")
            dayButton(1, from: index, title: language.text("后一天"), symbol: "chevron.right")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }

    private func dayButton(_ offset: Int, from index: Int, title: String, symbol: String) -> some View {
        let target = index + offset
        let isInRange = days.indices.contains(target)
        return Button(title, systemImage: symbol) {
            if isInRange { pinnedDate = days[target].date }
        }
        .disabled(!isInRange)
        .help(title)
    }

    private func dayValues(_ day: AGYUsageDay) -> some View {
        HStack(spacing: 14) {
            ForEach(visibleSeries, id: \.self) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.tint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(language.text(item.title))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.formatted(day.totals, in: language))
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated).locale(language.locale))
    }

    private func togglePin(_ date: Date) {
        pinnedDate = pinnedDate == date ? nil : date
    }
}
