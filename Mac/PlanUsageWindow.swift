import SwiftUI
import Charts

private struct PlanUsageRunoutForecast {
    let pace: UsagePace
    let depletionDate: Date?
    let remainingAtReset: Double

    var extendsPastReset: Bool {
        guard let depletionDate else { return false }
        return depletionDate > paceResetDate
    }

    // Filled by the factory below; kept as a separate date so callers cannot confuse ETA with reset.
    let paceResetDate: Date
}

/// One in-chart label in chart value space; resolved to points by the chart proxy.
/// The chart mark a label stands for, drawn at its start in the mark's exact colour.
private enum PlanUsageLabelIcon {
    case line
    case reset(filled: Bool)
    case runout(filled: Bool)
}

private struct PlanUsageChartLabel {
    let id: String
    let variants: [String]
    let x: Double
    var y: Double? = nil
    let band: PlanUsageAnnotationLayout.Band?
    let color: Color
    var icon: PlanUsageLabelIcon? = nil
    var iconColor: Color? = nil
}

/// Labels in priority order plus marker points floating labels must not cover.
private struct PlanUsageChartAnnotations {
    var labels: [PlanUsageChartLabel] = []
    var markers: [(x: Double, y: Double)] = []
    var dateAxis = false
}

private struct PlanUsageWindowGraph: Identifiable {
    let provider: String
    let window: String
    let graph: PlanUsageGraph
    var id: String { "\(provider):\(window)" }
}

struct PlanUsageWindow: View {
    @AppStorage("floatingMode") private var floating = false
    @State private var provider = "Combined"
    @State private var lane = "weekly"
    @State private var normalized = false
    @State private var histories: [String: [PlanUsageSeries]] = [:]
    @State private var accents: [String: String] = [:]
    private let fixture: [String: [PlanUsageSeries]]?

    init(fixture: [String: [PlanUsageSeries]]? = nil, provider: String = "Combined", normalized: Bool = false, lane: String = "weekly") {
        self.fixture = fixture
        self._provider = State(initialValue: provider)
        self._lane = State(initialValue: lane)
        self._normalized = State(initialValue: normalized)
        self._histories = State(initialValue: fixture ?? [:])
    }

    private var lanes: [String] {
        let providers = provider == "Combined" ? ["codex", "claude"] : [provider.lowercased()]
        let extra = providers.flatMap { histories[$0] ?? [] }.map(\.name)
            .filter { !["session", "weekly"].contains($0) }
        return ["session", "weekly", "both"] + Set(extra).sorted()
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Provider", selection: $provider) {
                        ForEach(["Codex", "Claude", "Combined"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Always on top", isOn: $floating).toggleStyle(.checkbox)
                }
                Picker("Quota window", selection: $lane) {
                    ForEach(lanes, id: \.self) { Text(laneTitle($0)).tag($0) }
                }.pickerStyle(.segmented)
                if provider == "Combined" {
                    Toggle("Normalized overlay comparison", isOn: $normalized)
                        .toggleStyle(.checkbox)
                    Text(normalized ? "Each quota window is aligned by elapsed progress (0–100%). Allowances are compared separately."
                         : "Each provider keeps its actual quota window and reset time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if provider == "Combined" {
                            if lane == "both" {
                                overlayBoth(now: context.date)
                            } else {
                                overlay(now: context.date, window: lane)
                            }
                        } else {
                            ForEach(provider == "Combined" ? ["codex", "claude"] : [provider.lowercased()], id: \.self) { id in
                                if lane == "both" {
                                    ForEach(["session", "weekly"], id: \.self) { window in
                                        providerGraph(id, window: window, now: context.date)
                                    }
                                } else {
                                    providerGraph(id, window: lane, now: context.date)
                                }
                            }
                        }
                    }.padding(2)
                }
                Text("Recorded locally by CodexBar · selected saved account per provider · \(ResetCountdown.localTimeZoneLabel())")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }
        .frame(minWidth: 580, minHeight: 450)
        .background(WindowFloatAccessor(floating: $floating))
        .task {
            guard fixture == nil else { return }
            while !Task.isCancelled {
                // Decode off the main actor; replace both selections atomically, clearing disappeared owners.
                let loaded = await Task.detached(priority: .utility) {
                    let reader = PlanUsageHistoryReader()
                    return (["codex": reader.read(provider: "codex"), "claude": reader.read(provider: "claude")], PlanUsageAccent.read())
                }.value
                histories = loaded.0
                accents = loaded.1
                if !lanes.contains(lane) { lane = "session" }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: provider) { _, _ in if !lanes.contains(lane) { lane = "session" } }
    }

    private func laneTitle(_ name: String) -> String {
        switch name {
        case "opus": return "Sonnet"
        case "both": return "Both"
        default: return name.capitalized
        }
    }
    private func graph(_ id: String, in window: String? = nil, now: Date) -> PlanUsageGraph? {
        guard let series = histories[id]?.first(where: { $0.name == (window ?? lane) }) else { return nil }
        return PlanUsageGraph(series: series, now: now)
    }
    /// The window before `current` (session or weekly), shown faintly while the current one is in
    /// its first half so a fresh or early reset still has recorded context. Display only.
    private func previousGraph(_ id: String, window: String, current: PlanUsageGraph, now: Date) -> PlanUsageGraph? {
        guard ["session", "weekly"].contains(window),
              let series = histories[id]?.first(where: { $0.name == window }) else { return nil }
        let duration = current.reset.timeIntervalSince(current.start)
        guard now.timeIntervalSince(current.start) < duration / 2,
              let previous = PlanUsageGraph.previous(series: series, before: current),
              previous.last.date >= current.start.addingTimeInterval(-duration) else { return nil }
        return previous
    }

    /// Rule where an early reset cut the previous window short; it sits at the current start.
    @ChartContentBuilder
    private func earlyResetRule<X: Plottable>(_ id: String, at x: X, previous: PlanUsageGraph, now: Date) -> some ChartContent {
        RuleMark(x: .value("Reset early", x))
            .foregroundStyle(Self.receded(baseColor(id), by: 0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .accessibilityLabel("\(id.capitalized) reset early; was due \(ResetCountdown.absoluteDateTime(previous.reset, now: now))")
    }

    private func percentLeft(_ graph: PlanUsageGraph) -> String {
        graph.last.remaining.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    /// Nothing used yet: the "lasts through reset" projection would sit on the 100% gridline.
    private func isUnused(_ graph: PlanUsageGraph) -> Bool { graph.last.remaining >= 99.95 }

    @ChartContentBuilder
    private func previousWindowMarks<X: Plottable>(_ id: String, _ previous: PlanUsageGraph, x: @escaping (Date) -> X, yLabel: String) -> some ChartContent {
        ForEach(previous.samples, id: \.date) { point in
            LineMark(x: .value("Time", x(point.date)), y: .value(yLabel, point.remaining), series: .value("Series", id + " previous window"))
                .foregroundStyle(Self.receded(baseColor(id), by: 0.75)).lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .accessibilityLabel("\(id.capitalized) previous window")
    }

    /// Every window starts at 100% left, but the first capture can come up to an hour later.
    /// A dotted segment joins the start marker to it: known start, path in between not recorded.
    @ChartContentBuilder
    private func startConnector<X: Plottable>(_ id: String, _ graph: PlanUsageGraph, x: @escaping (Date) -> X, yLabel: String) -> some ChartContent {
        if let first = graph.samples.first, first.date.timeIntervalSince(graph.start) > 60 {
            ForEach([PlanUsageGraph.Sample(date: graph.start, remaining: 100), first], id: \.date) { point in
                LineMark(x: .value("Time", x(point.date)), y: .value(yLabel, point.remaining), series: .value("Series", id + " start connector"))
                    .foregroundStyle(Self.receded(baseColor(id), by: 0.45)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [1, 3]))
            }
            .accessibilityHidden(true)
        }
    }

    // One visual language for quota windows, in every view: 5h session marks are filled with
    // short-dash reset rules; weekly (and other long windows) are outlined with long, lighter dashes.
    private func isSession(_ window: String) -> Bool { window == "session" }

    private func startMark(_ tint: Color, session: Bool) -> some View {
        Rectangle().fill(session ? tint : Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().strokeBorder(tint, lineWidth: session ? 0 : 1.5))
            .frame(width: 8, height: 8)
    }

    private func resetMark(_ tint: Color, session: Bool) -> some View {
        Rectangle().fill(session ? tint : Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().strokeBorder(tint, lineWidth: session ? 0 : 1.5))
            .frame(width: 7, height: 7).rotationEffect(.degrees(45))
    }

    /// Resets are known times, so their rules are solid; dashes are reserved for predictions.
    private func resetRuleStyle(_ window: String) -> StrokeStyle { StrokeStyle(lineWidth: 1.2) }

    private func resetRuleOpacity(_ window: String) -> Double { 1 }

    /// In Both, weekly is an opaque receding shade of the provider colour, so 5h and weekly separate by colour.
    private func bothTint(_ id: String, _ window: String) -> Color {
        isSession(window) ? color(id) : Self.receded(baseColor(id))
    }

    private func color(_ id: String) -> Color { Color(nsColor: baseColor(id)) }

    private func baseColor(_ id: String) -> NSColor {
        // CodexBar shipped provider colours. Optional config overrides use the same RGB hex format.
        let defaults = id == "codex" ? "49A3B0" : "CC7C5E"
        let hex = accents[id] ?? defaults
        let value = UInt64(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    /// An opaque, receding shade: the colour mixed halfway toward the window background, so it is
    /// lighter in light mode and darker in dark mode, and nothing shows through it.
    private static func receded(_ base: NSColor, by fraction: CGFloat = 0.5) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let background = dark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1) : NSColor.white
            return base.usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: background) ?? base
        })
    }

    @ViewBuilder
    private func providerGraph(_ id: String, window: String, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(id.capitalized + " · " + laneTitle(window), systemImage: "chart.xyaxis.line")
                .font(.headline).foregroundStyle(color(id))
            if let graph = graph(id, in: window, now: now) {
                let timeZone = TimeZone.current
                let forecast = runoutForecast(graph)
                // A run-out after reset never happens, so it must not stretch the axis.
                let axisEnd = graph.reset
                let previous = previousGraph(id, window: window, current: graph, now: now)
                let axis = PlanUsageTimeAxis(start: min(graph.start, previous?.start ?? graph.start), end: axisEnd, timeZone: timeZone)
                Chart {
                    if let previous {
                        previousWindowMarks(id, previous, x: { $0 }, yLabel: "Remaining")
                        if previous.resetEarly(before: graph) {
                            earlyResetRule(id, at: graph.start, previous: previous, now: now)
                        }
                    }
                    PointMark(x: .value("Window start", graph.start), y: .value("Top", 100))
                        .symbol { startMark(color(id), session: isSession(window)) }
                        .accessibilityLabel("\(id.capitalized) window start")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                    if let forecast, !isUnused(graph) {
                        let endpoint = forecast.depletionDate ?? graph.reset
                        let beforeReset = min(endpoint, graph.reset)
                        let beforeResetRemaining = forecast.pace.remainingPercent(at: beforeReset, observedAt: graph.last.date) ?? graph.last.remaining
                        LineMark(x: .value("Time", graph.last.date), y: .value("Remaining", graph.last.remaining), series: .value("Series", "Run-out projection"))
                            .foregroundStyle(color(id))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        LineMark(x: .value("Time", beforeReset), y: .value("Remaining", beforeResetRemaining), series: .value("Series", "Run-out projection"))
                            .foregroundStyle(color(id))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if let depletionDate = forecast.depletionDate, depletionDate > graph.reset {
                            PointMark(x: .value("Lasts to reset", graph.reset), y: .value("Remaining", forecast.remainingAtReset))
                                .symbol { afterResetSymbol(color(id)) }
                                .accessibilityLabel("Lasts to reset; projected run-out if pace continued beyond reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletionDate, now: now))
                        } else if let depletionDate = forecast.depletionDate {
                            PointMark(x: .value("Projected depletion", depletionDate), y: .value("Remaining", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .accessibilityLabel("Projected depletion")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletionDate, now: now))
                        }
                    }
                    startConnector(id, graph, x: { $0 }, yLabel: "Remaining")
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "Recorded"))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Time", graph.last.date), y: .value("Remaining", graph.last.remaining))
                        .foregroundStyle(color(id)).symbolSize(60)
                    RuleMark(x: .value("Reset", graph.reset))
                        .foregroundStyle(color(id).opacity(resetRuleOpacity(window)))
                        .lineStyle(resetRuleStyle(window))
                        .accessibilityLabel("\(id.capitalized) reset")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                    PointMark(x: .value("Reset", graph.reset), y: .value("Top", 100))
                        .symbol { resetMark(color(id), session: isSession(window)) }
                        .accessibilityHidden(true)
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityLabel("Current time")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                }
                .chartXScale(domain: axis.plotStart...axis.plotEnd)
                .chartYScale(domain: 0...100, range: annotationRange(top: 2, bottom: 1))
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis {
                    AxisMarks(values: axis.markDates) { value in
                        if let date = value.as(Date.self) {
                            if axis.isDayBoundary(date) {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                                    .foregroundStyle(.secondary.opacity(0.18))
                            } else if axis.isHourBoundary(date) {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                    .foregroundStyle(.secondary.opacity(0.10))
                            }
                            if axis.isHourBoundary(date) {
                                AxisTick()
                            }
                            if axis.isLabelDate(date) {
                                AxisValueLabel(collisionResolution: .greedy) {
                                    Text(axis.label(for: date, timeZone: timeZone))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    annotationOverlay(singleLabels(id: id, window: window, graph: graph, previous: previous, forecast: forecast, now: now), proxy: proxy, topLanes: 2, bottomLanes: 1)
                }
                .chartLegend(.hidden).frame(height: 222)
                .accessibilityLabel(id.capitalized + " recorded remaining quota")
                chartKey(previous: previous != nil, windows: [window])
                summaryRow(id, window: window, graph: graph, title: id.capitalized, now: now)
            } else { unavailable(id, window: window) }
        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    private func unavailable(_ id: String, window: String) -> some View {
        Text("\(id.capitalized) \(laneTitle(window)): unavailable — no recorded, active quota window for the selected account.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private func resetPlotTime(_ date: Date, window: String) -> String {
        window == "weekly"
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : shortTime(date)
    }

    @ChartContentBuilder
    private func evenUseGuide(series: String) -> some ChartContent {
        LineMark(x: .value("Elapsed progress", 0.0), y: .value("Even-use guide", 100.0), series: .value("Guide", series))
            .foregroundStyle(.secondary.opacity(0.24)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
        LineMark(x: .value("Elapsed progress", 100.0), y: .value("Even-use guide", 0.0), series: .value("Guide", series))
            .foregroundStyle(.secondary.opacity(0.24)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    private func normalizedGuidePoint(id: String, x: Double, y: Double) -> some ChartContent {
        LineMark(x: .value("Window position", x), y: .value("Remaining %", y), series: .value("Series", id + " guide"))
            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    @ChartContentBuilder
    private func runoutPoint(id: String, window: String, date: Date, now: Date, plotPosition: Double? = nil, remaining: Double = 0, afterReset: Bool = false) -> some ChartContent {
        let time = ResetCountdown.absoluteDateTime(date, now: now)
        let xValue: PlottableValue<Double> = .value("Run-out", plotPosition ?? date.timeIntervalSince1970)
        let yValue: PlottableValue<Double> = .value("Remaining", remaining)
        if afterReset {
            PointMark(x: xValue, y: yValue)
                .symbol { afterResetSymbol(color(id)) }
                .accessibilityLabel(id.capitalized + " " + window + " projected run-out if pace continues beyond reset")
                .accessibilityValue(time)
        } else {
            PointMark(x: xValue, y: yValue)
                .symbol(.circle).symbolSize(60).foregroundStyle(color(id))
                .accessibilityLabel(id.capitalized + " " + window + " projected run-out")
                .accessibilityValue(time)
        }
    }

    /// Hollow, dimmed: the quota resets before this point, so it is not a real run-out.
    private func afterResetSymbol(_ tint: Color) -> some View {
        Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1.5).frame(width: 8, height: 8)
    }

    @ChartContentBuilder
    private func focusedLine(_ points: [PlanUsageGraph.Sample], series: String, axis: PlanUsageFocusAxis, tint: Color, stroke: StrokeStyle) -> some ChartContent {
        ForEach(axis.vertices(points), id: \.date) { point in
            LineMark(x: .value("Time", axis.position(point.date)), y: .value("Remaining", point.remaining), series: .value("Series", series))
                .foregroundStyle(tint).lineStyle(stroke)
        }
    }

    private func position(_ date: Date, graph: PlanUsageGraph) -> Double {
        normalized ? graph.progress(date) : date.timeIntervalSince1970
    }

    private func runoutForecast(_ graph: PlanUsageGraph) -> PlanUsageRunoutForecast? {
        let used = 100 - graph.last.remaining
        let resetsAt = ISO8601DateFormatter().string(from: graph.reset)
        guard let pace = UsagePaceText.visiblePace(
            usedPercent: used,
            windowMinutes: Int(graph.reset.timeIntervalSince(graph.start) / 60),
            resetsAt: resetsAt,
            now: graph.last.date
        ) else { return nil }
        guard let remainingAtReset = pace.remainingPercent(at: graph.reset, observedAt: graph.last.date) else { return nil }
        let depletionDate = pace.depletionSeconds.map { graph.last.date.addingTimeInterval($0) }
        return PlanUsageRunoutForecast(pace: pace, depletionDate: depletionDate, remainingAtReset: remainingAtReset, paceResetDate: graph.reset)
    }

    private func forecastLegendText(_ id: String, graph: PlanUsageGraph?) -> String {
        guard let graph else { return "\(id.capitalized) · no active data" }
        if let forecast = runoutForecast(graph) {
            guard let depletion = forecast.depletionDate else { return "\(id.capitalized) · lasts to reset" }
            return forecast.extendsPastReset
                ? "\(id.capitalized) forecast · hypothetical after reset"
                : "\(id.capitalized) forecast · out \(depletion.formatted(.dateTime.hour().minute()))"
        }
        let expected = graph.last.date.timeIntervalSince(graph.start) / graph.reset.timeIntervalSince(graph.start) * 100
        if 100 - graph.last.remaining <= 0 || expected < UsagePaceText.minimumExpectedPercent {
            return "\(id.capitalized) forecast · waiting for signal (<3% expected)"
        }
        return "\(id.capitalized) forecast · unavailable"
    }

    private func combinedDomain(_ graphs: [(String, PlanUsageGraph)], earliest: Date? = nil) -> ClosedRange<Double> {
        if normalized { return 0...100 }
        let axis = timelineAxis(graphs, earliest: earliest)
        let start = axis.plotStart.timeIntervalSince1970
        return start...max(start + 1, axis.plotEnd.timeIntervalSince1970)
    }
    /// `earliest` widens the axis for display-only context such as a previous window.
    private func timelineAxis(_ graphs: [(String, PlanUsageGraph)], earliest: Date? = nil) -> PlanUsageTimeAxis {
        let start = (graphs.map { $0.1.start } + [earliest].compactMap { $0 }).min() ?? .now
        // Run-outs before reset fall inside the window; ones after reset never happen.
        let end = graphs.map { $0.1.reset }.max() ?? start.addingTimeInterval(1)
        return PlanUsageTimeAxis(start: start, end: end, timeZone: .current)
    }

    private func overlayBoth(now: Date) -> some View {
        let entries = [("codex", "session"), ("claude", "session"), ("codex", "weekly"), ("claude", "weekly")]
            .compactMap { id, window in graph(id, in: window, now: now).map { PlanUsageWindowGraph(provider: id, window: window, graph: $0) } }
        let earliest = entries.map { $0.graph.start }.min() ?? now.addingTimeInterval(-1)
        let latestReset = entries.map { $0.graph.reset }.max() ?? now.addingTimeInterval(1)
        let axis = PlanUsageTimeAxis(start: earliest, end: latestReset, timeZone: .current)
        let sessions = entries.filter { $0.window == "session" }
        let sessionStart = min(sessions.map { $0.graph.start }.min() ?? now, now.addingTimeInterval(-3 * 3600))
        let sessionEnd = max(sessions.map { $0.graph.reset }.max() ?? now, now.addingTimeInterval(3 * 3600))
        let sessionAxis = PlanUsageTimeAxis(start: sessionStart, end: sessionEnd, timeZone: .current)
        let focus = PlanUsageFocusAxis(start: axis.plotStart, end: axis.plotEnd, focusStart: sessionAxis.plotStart, focusEnd: sessionAxis.plotEnd)
        let ticks = Array(Set(axis.dayBoundaries.filter { $0 < focus.focusStart || $0 > focus.focusEnd } + sessionAxis.hourBoundaries.filter { $0 >= focus.focusStart && $0 <= focus.focusEnd })).sorted()
        // Compressed days can crowd; keep labels ~40pt apart at the 580pt minimum width.
        let labelledTicks = PlanUsageAnnotationLayout.thinned(ticks.map { focus.position($0) }, minimumGap: 0.085)
        return VStack(alignment: .leading, spacing: 12) {
            Text(normalized ? "Combined · Session + Weekly · Normalized" : "Combined · Session + Weekly")
                .font(.headline)
            if !entries.isEmpty {
                Chart {
                    if !normalized, !focus.breakDates.isEmpty {
                        RectangleMark(xStart: .value("Expanded hours", focus.position(focus.focusStart)), xEnd: .value("Expanded hours", focus.position(focus.focusEnd)), yStart: .value("Bottom", 0.0), yEnd: .value("Top", 100.0))
                            .foregroundStyle(.secondary.opacity(0.06)).accessibilityHidden(true)
                    }
                    if normalized {
                        RuleMark(x: .value("Shared reset boundary", 100))
                            .foregroundStyle(.secondary.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .accessibilityLabel("Normalized reset boundary at 100 percent")
                        PointMark(x: .value("Shared reset boundary", 100), y: .value("Midpoint", 50))
                            .symbol(.diamond).symbolSize(64).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    ForEach(entries, id: \.id) { item in
                        let id = item.provider
                        let quotaWindow = item.window
                        let graph = item.graph
                        // 5h solid and full colour; weekly long-dashed and lighter, so it reads as the background budget.
                        let lineStyle = StrokeStyle(lineWidth: isSession(quotaWindow) ? 2.4 : 2.2)

                        if normalized {
                            evenUseGuide(series: item.id)
                        } else if let forecast = runoutForecast(graph), !isUnused(graph) {
                            let end = min(forecast.depletionDate ?? graph.reset, graph.reset)
                            let remaining = forecast.pace.remainingPercent(at: end, observedAt: graph.last.date) ?? graph.last.remaining
                            focusedLine([graph.last, .init(date: end, remaining: remaining)], series: "Forecast " + item.id, axis: focus, tint: bothTint(id, quotaWindow), stroke: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            if let depletion = forecast.depletionDate {
                                let afterReset = depletion > graph.reset
                                runoutPoint(id: id, window: quotaWindow, date: depletion, now: now,
                                            plotPosition: focus.position(afterReset ? graph.reset : depletion),
                                            remaining: afterReset ? forecast.remainingAtReset : 0, afterReset: afterReset)
                            }
                        }

                        if !normalized, let first = graph.samples.first, first.date.timeIntervalSince(graph.start) > 60 {
                            focusedLine([.init(date: graph.start, remaining: 100), first], series: "Start " + item.id, axis: focus,
                                        tint: bothTint(id, quotaWindow), stroke: StrokeStyle(lineWidth: 1.2, dash: [1, 3]))
                        }
                        ForEach(normalized ? graph.samples : focus.vertices(graph.samples), id: \.date) { point in
                            LineMark(x: .value("Time", normalized ? graph.progress(point.date) : focus.position(point.date)), y: .value("Remaining", point.remaining), series: .value("Quota", item.id))
                                .foregroundStyle(bothTint(id, quotaWindow))
                                .lineStyle(lineStyle)
                        }
                        PointMark(x: .value("Latest capture", normalized ? graph.progress(graph.last.date) : focus.position(graph.last.date)), y: .value("Remaining", graph.last.remaining))
                            .foregroundStyle(bothTint(id, quotaWindow)).symbolSize(38)
                            .accessibilityLabel("\(id.capitalized) \(quotaWindow == "session" ? "5-hour" : "weekly") latest capture")

                        if !normalized {
                            PointMark(x: .value("\(id.capitalized) \(quotaWindow) start", focus.position(graph.start)), y: .value("Top", 100))
                                .symbol { startMark(bothTint(id, quotaWindow), session: isSession(quotaWindow)) }
                                .accessibilityLabel("\(id.capitalized) \(quotaWindow) window start")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                            RuleMark(x: .value("\(id.capitalized) \(quotaWindow) reset", focus.position(graph.reset)))
                                .foregroundStyle(bothTint(id, quotaWindow).opacity(resetRuleOpacity(quotaWindow)))
                                .lineStyle(resetRuleStyle(quotaWindow))
                                .accessibilityLabel("\(id.capitalized) \(quotaWindow) reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                            PointMark(x: .value("\(id.capitalized) \(quotaWindow) reset", focus.position(graph.reset)), y: .value("Top", 100))
                                .symbol { resetMark(bothTint(id, quotaWindow), session: isSession(quotaWindow)) }
                                .accessibilityHidden(true)
                        }
                    }

                    if !normalized {
                        ForEach(focus.breakDates, id: \.self) { date in
                            RuleMark(x: .value("Time scale changes", focus.position(date)))
                                .foregroundStyle(.secondary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 0.7))
                            PointMark(x: .value("Time scale changes", focus.position(date)), y: .value("Bottom", 0))
                                .symbolSize(0)
                                .annotation(position: .top, spacing: 2) {
                                    Text("//").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).background(Color(nsColor: .windowBackgroundColor))
                                }
                        }
                        RuleMark(x: .value("Now", focus.position(now)))
                            .foregroundStyle(Color.primary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .accessibilityLabel("Current time")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                    }
                }
                .chartXScale(domain: normalized ? 0...100 : 0...1)
                .chartYScale(domain: 0...100, range: annotationRange(top: normalized ? 0 : 4, bottom: normalized ? 0 : 3))
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis {
                    AxisMarks(values: normalized ? [0, 25, 50, 75, 100] : ticks.map { focus.position($0) }) { value in
                        if normalized {
                            AxisGridLine(); AxisTick()
                            if let progress = value.as(Double.self) { AxisValueLabel("\(Int(progress))%") }
                        } else if let position = value.as(Double.self) {
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(focus.isFocused(position) ? 0.1 : 0.18))
                            AxisTick()
                        }
                    }
                    // Labels get their own marks so Charts sizes each one by labelled neighbours, not every tick.
                    if !normalized {
                        AxisMarks(values: labelledTicks) { value in
                            if let position = value.as(Double.self) {
                                let date = focus.date(at: position)
                                AxisValueLabel(collisionResolution: .disabled) {
                                    Text(focus.isFocused(position) ? sessionAxis.label(for: date, timeZone: .current) : axis.label(for: date, timeZone: .current))
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    annotationOverlay(bothLabels(entries, focus: focus, now: now), proxy: proxy, topLanes: normalized ? 0 : 4, bottomLanes: normalized ? 0 : 3)
                }
                .chartLegend(.hidden)
                .frame(height: normalized ? 300 : 398)
            } else {
                Text("Combined history is unavailable for the selected saved account.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            }

            Text(normalized
                ? "Elapsed progress within each quota window · session and weekly histories are aligned separately."
                : (focus.breakDates.isEmpty ? "Actual time" : "Hours expanded near Now · outer days compressed") + " · \(ResetCountdown.localTimeZoneLabel())")
                .font(.caption).foregroundStyle(.secondary)
            if !normalized, !focus.breakDates.isEmpty {
                Text("// marks a change of time scale; all time is retained. Forecast slopes change at these joins.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if normalized {
                Label("Even-use guide", systemImage: "line.diagonal").font(.caption2).foregroundStyle(.secondary)
            } else {
                chartKey(previous: false, windows: ["session", "weekly"], expanded: !focus.breakDates.isEmpty)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries, id: \.id) { item in
                    summaryRow(item.provider, window: item.window, graph: item.graph,
                               title: "\(item.provider.capitalized) · \(item.window == "session" ? "5h" : laneTitle(item.window))", now: now)
                }
            }
        }
        .padding(16)
    }

    private func overlay(now: Date, window: String) -> some View {
        let graphs = ["codex", "claude"].compactMap { id in graph(id, in: window, now: now).map { (id, $0) } }
        let timeZone = TimeZone.current
        let previous: [(String, PlanUsageGraph)] = normalized ? [] : graphs.compactMap { id, graph in previousGraph(id, window: window, current: graph, now: now).map { (id, $0) } }
        let earliest = previous.map { $0.1.start }.min()
        let axis = timelineAxis(graphs, earliest: earliest)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text((normalized ? "Normalized · " : "Combined · ") + laneTitle(window)).font(.headline)
                Spacer(minLength: 8)
                ForEach(graphs, id: \.0) { id, _ in
                    Label { Text(id.capitalized) } icon: { Circle().fill(color(id)).frame(width: 8, height: 8) }
                        .font(.caption.weight(.semibold)).foregroundStyle(color(id))
                }
            }
            if !graphs.isEmpty {
            Chart {
                if !normalized {
                    ForEach(previous, id: \.0) { id, prior in
                        previousWindowMarks(id, prior, x: { $0.timeIntervalSince1970 }, yLabel: "Remaining %")
                        if let current = graphs.first(where: { $0.0 == id })?.1, prior.resetEarly(before: current) {
                            earlyResetRule(id, at: current.start.timeIntervalSince1970, previous: prior, now: now)
                        }
                    }
                }
                if normalized {
                    RuleMark(x: .value("Shared reset boundary", 100.0))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    PointMark(x: .value("Shared reset boundary", 100.0), y: .value("Midpoint", 50.0))
                        .symbol(.diamond).symbolSize(64).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ForEach(graphs, id: \.0) { id, graph in
                    if normalized {
                        ForEach([graph.start, graph.reset], id: \.self) { date in
                            let xValue = position(date, graph: graph)
                            let yValue = date == graph.start ? 100.0 : 0.0
                            normalizedGuidePoint(id: id, x: xValue, y: yValue)
                        }
                    } else if let forecast = runoutForecast(graph), !isUnused(graph) {
                        let endpoint = forecast.depletionDate ?? graph.reset
                        let preResetEnd = min(endpoint, graph.reset)
                        let preResetRemaining = forecast.pace.remainingPercent(at: preResetEnd, observedAt: graph.last.date) ?? graph.last.remaining
                        LineMark(x: .value("Time", graph.last.date.timeIntervalSince1970), y: .value("Remaining %", graph.last.remaining), series: .value("Series", id + " run-out projection"))
                            .foregroundStyle(color(id))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        LineMark(x: .value("Time", preResetEnd.timeIntervalSince1970), y: .value("Remaining %", preResetRemaining), series: .value("Series", id + " run-out projection"))
                            .foregroundStyle(color(id))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if let depletion = forecast.depletionDate, depletion > graph.reset {
                            PointMark(x: .value("Lasts to reset", graph.reset.timeIntervalSince1970), y: .value("Remaining %", forecast.remainingAtReset))
                                .symbol { afterResetSymbol(color(id)) }
                                .accessibilityLabel("\(id.capitalized) lasts to reset; projected run-out if pace continued beyond reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletion, now: now))
                        } else if let depletion = forecast.depletionDate {
                            PointMark(x: .value("Projected depletion", depletion.timeIntervalSince1970), y: .value("Remaining %", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .accessibilityLabel("\(id.capitalized) projected depletion")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletion, now: now))
                        }
                    }
                }
                if !normalized {
                    ForEach(graphs, id: \.0) { id, graph in
                        PointMark(x: .value("\(id.capitalized) window start", graph.start.timeIntervalSince1970), y: .value("Top", 100))
                            .symbol { startMark(color(id), session: isSession(window)) }
                            .accessibilityLabel("\(id.capitalized) window start")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                    }
                    RuleMark(x: .value("Now", now.timeIntervalSince1970))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityLabel("Current time")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                    ForEach(graphs, id: \.0) { id, graph in
                        RuleMark(x: .value("\(id.capitalized) reset", graph.reset.timeIntervalSince1970))
                            .foregroundStyle(color(id).opacity(resetRuleOpacity(window)))
                            .lineStyle(resetRuleStyle(window))
                            .accessibilityLabel("\(id.capitalized) reset")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                        PointMark(x: .value("\(id.capitalized) reset", graph.reset.timeIntervalSince1970), y: .value("Top", 100))
                            .symbol { resetMark(color(id), session: isSession(window)) }
                            .accessibilityHidden(true)
                    }
                }
                ForEach(graphs, id: \.0) { id, graph in
                    if !normalized {
                        startConnector(id, graph, x: { $0.timeIntervalSince1970 }, yLabel: "Remaining %")
                    }
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Elapsed window %", position(point.date, graph: graph)), y: .value("Remaining %", point.remaining), series: .value("Provider", id))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                        PointMark(x: .value("Elapsed window %", position(graph.last.date, graph: graph)), y: .value("Remaining %", graph.last.remaining))
                            .foregroundStyle(color(id)).symbolSize(35)
                            .accessibilityLabel("\(id.capitalized) latest capture")
                }
            }.chartXScale(domain: combinedDomain(graphs, earliest: earliest))
                .chartYScale(domain: 0...100, range: annotationRange(top: normalized ? 0 : 3, bottom: normalized ? 0 : 2))
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis {
                    AxisMarks(values: normalized
                        ? [0, 25, 50, 75, 100]
                        : axis.markDates.map(\.timeIntervalSince1970)) { value in
                        if normalized {
                            AxisGridLine()
                            AxisTick()
                            if let progress = value.as(Double.self) {
                                AxisValueLabel(collisionResolution: .greedy) {
                                    Text("\(Int(progress))%")
                                }
                            }
                        } else if let seconds = value.as(Double.self) {
                            let date = Date(timeIntervalSince1970: seconds)
                            if axis.isDayBoundary(date) {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                                    .foregroundStyle(.secondary.opacity(0.18))
                            } else if axis.isHourBoundary(date) {
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                    .foregroundStyle(.secondary.opacity(0.10))
                            }
                            if axis.isHourBoundary(date) {
                                AxisTick()
                            }
                            if axis.isLabelDate(date) {
                                AxisValueLabel(collisionResolution: .greedy) {
                                    Text(axis.label(for: date, timeZone: timeZone))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    annotationOverlay(overlayLabels(graphs, window: window, now: now), proxy: proxy, topLanes: normalized ? 0 : 3, bottomLanes: normalized ? 0 : 2)
                }
                .chartLegend(.hidden).frame(height: normalized ? 250 : 300)
            }
            Text(normalized
                ? "Elapsed quota-window progress (%) · provider resets align at 100%."
                : "Actual time · \(ResetCountdown.localTimeZoneLabel())")
                .font(.caption).foregroundStyle(.secondary)
            if normalized {
                Label("Even-use guide", systemImage: "line.diagonal").font(.caption2).foregroundStyle(.secondary)
            } else {
                chartKey(previous: !previous.isEmpty, windows: [window])
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["codex", "claude"], id: \.self) { id in
                    if let graph = graph(id, in: window, now: now) {
                        summaryRow(id, window: window, graph: graph, title: id.capitalized, now: now)
                    } else { unavailable(id, window: window) }
                }
            }
        }.padding(16)
    }

    // MARK: - Below the chart

    /// One shared key for the marks; provider colours are carried by the summary rows.
    private func chartKey(previous: Bool, windows: [String], expanded: Bool = false) -> some View {
        HStack(spacing: 14) {
            ForEach(windows, id: \.self) { window in
                Label {
                    Text(windows.count > 1 ? (isSession(window) ? "5h start · reset" : "Weekly start · reset") : "Start · reset")
                } icon: {
                    HStack(spacing: 3) {
                        let tint = windows.count > 1 && !isSession(window) ? Self.receded(.secondaryLabelColor) : Color.secondary
                        if windows.count > 1 { lineSwatch(tint, dashed: false) }
                        startMark(tint, session: isSession(window))
                        resetMark(tint, session: isSession(window))
                    }
                }
            }
            Label("Now", systemImage: "poweron")
            Label { Text("Forecast") } icon: { lineSwatch(Color.secondary, dashed: true) }
            if expanded { Label("Expanded hours (shaded)", systemImage: "rectangle.fill") }
            if previous { Label("Previous window (faint)", systemImage: "line.diagonal") }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func lineSwatch(_ tint: Color, dashed: Bool) -> some View {
        Path { path in path.move(to: CGPoint(x: 0, y: 4)); path.addLine(to: CGPoint(x: 14, y: 4)) }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 2] : []))
            .frame(width: 14, height: 8)
    }

    /// What happens next for one quota window, in words.
    private func outlook(_ forecast: PlanUsageRunoutForecast?, graph: PlanUsageGraph, window: String, now: Date) -> (text: String, known: Bool) {
        let time: (Date) -> String = { runoutTime($0, window: window, now: now) }
        if isUnused(graph) { return (forecast == nil ? "No usage yet" : "No usage yet · lasts through reset", forecast != nil) }
        guard let forecast else { return ("Waiting for enough usage to estimate", false) }
        guard let depletion = forecast.depletionDate else { return ("Lasts through reset", true) }
        if forecast.extendsPastReset { return ("Lasts to reset · would run out \(time(depletion)) at this pace", true) }
        return ("Out \(ResetCountdown.absoluteDateTime(depletion, now: now)) · \(ResetCountdown.countdown(to: depletion, now: now)) at this pace", true)
    }

    /// One provider window: what is left and what happens next, then its exact times.
    private func summaryRow(_ id: String, window: String, graph: PlanUsageGraph, title: String, now: Date) -> some View {
        let next = outlook(runoutForecast(graph), graph: graph, window: window, now: now)
        let stale = now.timeIntervalSince(graph.last.date) >= 300 ? " · stale recorded data" : ""
        let capture = Calendar.current.isDate(graph.last.date, inSameDayAs: now)
            ? shortTime(graph.last.date) : graph.last.date.formatted(date: .abbreviated, time: .shortened)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color(id)).frame(width: 7, height: 7)
                Text(title).fontWeight(.semibold).foregroundStyle(color(id))
                Text("\(graph.last.remaining.formatted(.number.precision(.fractionLength(0))))% left").monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(next.text).monospacedDigit().foregroundStyle(next.known ? AnyShapeStyle(color(id)) : AnyShapeStyle(.secondary))
            }
            .font(.caption)
            Group {
                Text("Resets \(ResetCountdown.absoluteDateTime(graph.reset, now: now)) · \(ResetCountdown.countdown(to: graph.reset, now: now))")
                Text("Started \(ResetCountdown.absoluteDateTime(graph.start, now: now)) · last capture \(capture)\(stale)")
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary).padding(.leading, 13)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Annotation lanes

    private static let labelFontSize = NSFont.preferredFont(forTextStyle: .caption2).pointSize
    private static let labelFont = NSFont.systemFont(ofSize: labelFontSize, weight: .semibold)

    /// Pill width for a label: measured text plus the horizontal padding drawn below.
    static func labelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: labelFont]).width) + 12
    }

    /// Reserves fixed point bands above 100% and below 0% so labels never sit on the data.
    private func annotationRange(top: Int, bottom: Int) -> PlotDimensionScaleRange {
        .plotDimension(startPadding: CGFloat(bottom) * PlanUsageAnnotationLayout.laneHeight + (bottom > 0 ? 4 : 6),
                       endPadding: CGFloat(top) * PlanUsageAnnotationLayout.laneHeight + (top > 0 ? 6 : 6))
    }

    private func annotationOverlay(_ annotations: PlanUsageChartAnnotations, proxy: ChartProxy, topLanes: Int, bottomLanes: Int) -> some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            let placed = Self.placements(annotations, proxy: proxy, plot: plot, topLanes: topLanes, bottomLanes: bottomLanes)
            ZStack(alignment: .topLeading) {
                ForEach(placed, id: \.placement.id) { item in
                    HStack(spacing: Self.iconSpacing) {
                        if let icon = item.icon { labelIcon(icon, tint: item.iconColor ?? item.color) }
                        Text(item.placement.text)
                            .font(.system(size: Self.labelFontSize, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(item.color)
                    }
                        .frame(width: item.placement.frame.width, height: item.placement.frame.height)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
                        .overlay(Capsule().strokeBorder(item.color.opacity(0.35), lineWidth: 0.5))
                        .position(x: item.placement.frame.midX, y: item.placement.frame.midY)
                        .accessibilityLabel(item.fullText)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static let iconSize: CGFloat = 8
    private static let iconSpacing: CGFloat = 4

    @ViewBuilder
    private func labelIcon(_ icon: PlanUsageLabelIcon, tint: Color) -> some View {
        switch icon {
        case .line: Capsule().fill(tint).frame(width: Self.iconSize + 2, height: 2.5)
        case .reset(let filled): resetMark(tint, session: filled).frame(width: Self.iconSize, height: Self.iconSize)
        case .runout(let filled):
            if filled { Circle().fill(tint).frame(width: Self.iconSize - 1, height: Self.iconSize - 1) }
            else { Circle().strokeBorder(tint, lineWidth: 1.5).frame(width: Self.iconSize, height: Self.iconSize) }
        }
    }

    private static func placements(_ annotations: PlanUsageChartAnnotations, proxy: ChartProxy, plot: CGRect, topLanes: Int, bottomLanes: Int) -> [(placement: PlanUsageAnnotationLayout.Placement, color: Color, fullText: String, icon: PlanUsageLabelIcon?, iconColor: Color?)] {
        guard plot.width > 0 else { return [] }
        func x(_ value: Double) -> CGFloat? {
            let position = annotations.dateAxis ? proxy.position(forX: Date(timeIntervalSince1970: value)) : proxy.position(forX: value)
            guard let position, position >= -0.5, position <= plot.width + 0.5 else { return nil }
            return plot.minX + position
        }
        func y(_ value: Double) -> CGFloat? { proxy.position(forY: value).map { plot.minY + $0 } }
        var labels: [PlanUsageAnnotationLayout.Label] = []
        for label in annotations.labels {
            guard let anchorX = x(label.x) else { continue }
            if let band = label.band {
                labels.append(.init(id: label.id, variants: label.variants, anchorX: anchorX, kind: .lane(band)))
            } else if let value = label.y, let anchorY = y(value) {
                labels.append(.init(id: label.id, variants: label.variants, anchorX: anchorX, kind: .floating(CGPoint(x: anchorX, y: anchorY))))
            }
        }
        let obstacles = annotations.markers.compactMap { marker -> CGRect? in
            guard let px = x(marker.x), let py = y(marker.y) else { return nil }
            return CGRect(x: px - 6, y: py - 6, width: 12, height: 12)
        }
        // Labels with a leading mark need room for it; the layout measures text only.
        let iconTexts = Set(annotations.labels.filter { $0.icon != nil }.flatMap(\.variants))
        let iconWidth = iconSize + 2 + iconSpacing
        let layout = PlanUsageAnnotationLayout(plot: plot, topLanes: topLanes, bottomLanes: bottomLanes,
                                               measure: { labelWidth($0) + (iconTexts.contains($0) ? iconWidth : 0) })
        let byID = Dictionary(uniqueKeysWithValues: annotations.labels.map { ($0.id, $0) })
        return layout.solve(labels, obstacles: obstacles).placements.compactMap { placement in
            byID[placement.id].map { (placement, $0.color, $0.variants[0], $0.icon, $0.iconColor) }
        }
    }

    private static func dedupe(_ values: [String]) -> [String] {
        values.reduce(into: []) { output, value in if !output.contains(value) { output.append(value) } }
    }

    /// Longest to shortest. Weekly times keep the weekday; session labels keep the countdown longest.
    /// `marker` prefixes even the shortest variants ("5h ", "wk ") where windows share a chart.
    private func resetVariants(_ heads: [String], reset: Date, window: String, now: Date, marker: String = "") -> [String] {
        let time = resetPlotTime(reset, window: window)
        let countdown = window == "session" ? " · " + ResetCountdown.countdown(to: reset, now: now) : ""
        let named = heads.map { "\($0) \(time)" }
        return Self.dedupe(named.map { $0 + countdown } + [marker + time + countdown] + named.suffix(1) + [marker + time])
    }

    /// `names` run from most to least specific; "" means no provider prefix.
    /// A run-out after reset is presented as lasting to reset, with its time only while it fits.
    /// Longest first. The countdown is the first thing dropped, so the provider name survives longest.
    private func runoutVariants(_ names: [String], depletion: Date, reset: Date, window: String, now: Date, marker: String = "") -> [String] {
        let time = runoutTime(depletion, window: window, now: now)
        let countdown = " · " + ResetCountdown.countdown(to: depletion, now: now)
        func phrase(_ name: String, _ text: String) -> String {
            name.isEmpty ? text.prefix(1).uppercased() + text.dropFirst() : "\(name) \(text)"
        }
        guard depletion > reset else {
            return Self.dedupe([phrase(names[0], "runs out \(time)\(countdown)"), phrase(names[0], "runs out \(time)")]
                               + names.map { phrase($0, "out \(time)") } + [marker + time])
        }
        // The hypothetical run-out date lives in the summary row, not on the chart.
        return Self.dedupe(names.map { phrase($0, "lasts to reset") })
    }

    /// Time for a run-out label; far-off hypothetical run-outs carry their date, not just a weekday.
    private func runoutTime(_ date: Date, window: String, now: Date) -> String {
        if date.timeIntervalSince(now) > 6 * 86400 { return date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
        return window == "session" ? shortTime(date) : resetPlotTime(date, window: "weekly")
    }

    /// `x` should be the reset's position when the run-out falls after it.
    private func runoutLabel(id: String, names: [String], depletion: Date, reset: Date, window: String, now: Date, x: Double, tint: Color, iconTint: Color, marker: String = "") -> PlanUsageChartLabel {
        .init(id: id, variants: runoutVariants(names, depletion: depletion, reset: reset, window: window, now: now, marker: marker), x: x, band: .bottom,
              color: tint, icon: .runout(filled: depletion <= reset), iconColor: iconTint)
    }

    /// Label text in Both follows its line: weekly a little lighter (light) / darker (dark), still readable.
    private func bothLabelTint(_ id: String, _ window: String) -> Color {
        isSession(window) ? color(id) : Self.receded(baseColor(id), by: 0.2)
    }

    private func nowLabel(_ x: Double) -> PlanUsageChartLabel {
        PlanUsageChartLabel(id: "now", variants: ["Now"], x: x, band: .top, color: .secondary)
    }

    /// "no usage yet" for 0% used, otherwise "new window" for a single capture; longest first.
    private func tagVariants(_ base: [String], graph: PlanUsageGraph) -> [String] {
        let extras = isUnused(graph) ? ["no usage yet"] : graph.samples.count == 1 ? ["new window"] : []
        guard let head = base.first, !extras.isEmpty else { return base }
        func join(_ parts: [String]) -> String {
            let text = ([head] + parts).filter { !$0.isEmpty }.joined(separator: " · ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return Self.dedupe([join(extras)] + base.filter { !$0.isEmpty })
    }

    private func singleLabels(id: String, window: String, graph: PlanUsageGraph, previous: PlanUsageGraph?, forecast: PlanUsageRunoutForecast?, now: Date) -> PlanUsageChartAnnotations {
        var output = PlanUsageChartAnnotations(dateAxis: true)
        output.labels.append(nowLabel(now.timeIntervalSince1970))
        output.labels.append(.init(id: "reset", variants: resetVariants(["Resets"], reset: graph.reset, window: window, now: now), x: graph.reset.timeIntervalSince1970, band: .top, color: color(id),
                                   icon: .reset(filled: isSession(window)), iconColor: color(id)))
        if let depletion = forecast?.depletionDate {
            output.labels.append(runoutLabel(id: "out", names: [""], depletion: depletion, reset: graph.reset, window: window, now: now, x: min(depletion, graph.reset).timeIntervalSince1970, tint: color(id), iconTint: color(id)))
        }
        let tags = tagVariants([""], graph: graph)
        if tags != [""] {
            output.labels.append(.init(id: "tag", variants: tags, x: graph.last.date.timeIntervalSince1970, y: graph.last.remaining, band: nil, color: color(id), icon: .line, iconColor: color(id)))
            output.markers.append((graph.last.date.timeIntervalSince1970, graph.last.remaining))
        }
        return output
    }

    private func overlayLabels(_ graphs: [(String, PlanUsageGraph)], window: String, now: Date) -> PlanUsageChartAnnotations {
        var output = PlanUsageChartAnnotations()
        if !normalized {
            output.labels.append(nowLabel(now.timeIntervalSince1970))
            for (id, graph) in graphs {
                let name = id.capitalized
                output.labels.append(.init(id: id + "-reset", variants: resetVariants(["\(name) resets", name], reset: graph.reset, window: window, now: now), x: graph.reset.timeIntervalSince1970, band: .top, color: color(id),
                                           icon: .reset(filled: isSession(window)), iconColor: color(id)))
                output.markers += [(graph.reset.timeIntervalSince1970, 100), (graph.start.timeIntervalSince1970, 100)]
            }
            for (id, graph) in graphs {
                guard let depletion = runoutForecast(graph)?.depletionDate else { continue }
                output.labels.append(runoutLabel(id: id + "-out", names: [id.capitalized, ""], depletion: depletion, reset: graph.reset, window: window, now: now, x: min(depletion, graph.reset).timeIntervalSince1970, tint: color(id), iconTint: color(id)))
                output.markers.append((min(depletion, graph.reset).timeIntervalSince1970, 0))
            }
        }
        for (id, graph) in graphs {
            let x = position(graph.last.date, graph: graph)
            // The leading mark ties the label to its line; name first, then the value.
            output.labels.append(.init(id: id + "-tag", variants: tagVariants(["\(id.capitalized) \(percentLeft(graph))", percentLeft(graph)], graph: graph), x: x, y: graph.last.remaining, band: nil, color: color(id), icon: .line, iconColor: color(id)))
            output.markers.append((x, graph.last.remaining))
        }
        return output
    }

    private func bothLabels(_ entries: [PlanUsageWindowGraph], focus: PlanUsageFocusAxis, now: Date) -> PlanUsageChartAnnotations {
        var output = PlanUsageChartAnnotations()
        func short(_ window: String) -> String { window == "session" ? "5h" : "wk" }
        if !normalized {
            output.labels.append(nowLabel(focus.position(now)))
            for item in entries {
                let name = item.provider.capitalized
                output.labels.append(.init(id: item.id + "-reset", variants: resetVariants(["\(name) \(short(item.window)) resets", "\(name) \(short(item.window))"], reset: item.graph.reset, window: item.window, now: now, marker: short(item.window) + " "), x: focus.position(item.graph.reset), band: .top,
                                           color: bothLabelTint(item.provider, item.window), icon: .reset(filled: isSession(item.window)), iconColor: bothTint(item.provider, item.window)))
                output.markers += [(focus.position(item.graph.reset), 100), (focus.position(item.graph.start), 100)]
            }
            for item in entries {
                guard let depletion = runoutForecast(item.graph)?.depletionDate else { continue }
                let name = item.provider.capitalized
                output.labels.append(runoutLabel(id: item.id + "-out", names: ["\(name) \(short(item.window))", short(item.window)], depletion: depletion, reset: item.graph.reset, window: item.window, now: now, x: focus.position(min(depletion, item.graph.reset)),
                                                 tint: bothLabelTint(item.provider, item.window), iconTint: bothTint(item.provider, item.window), marker: short(item.window) + " "))
                output.markers.append((focus.position(min(depletion, item.graph.reset)), 0))
            }
        }
        for item in entries {
            let x = normalized ? item.graph.progress(item.graph.last.date) : focus.position(item.graph.last.date)
            let name = item.provider.capitalized
            let base = item.window == "session" ? ["\(name) · 5h", "\(name) 5h"] : ["\(name) · Weekly", "\(name) wk"]
            let variants = tagVariants(base, graph: item.graph)
            output.labels.append(.init(id: item.id + "-tag", variants: variants, x: x, y: item.graph.last.remaining, band: nil,
                                       color: bothLabelTint(item.provider, item.window), icon: .line, iconColor: bothTint(item.provider, item.window)))
            output.markers.append((x, item.graph.last.remaining))
        }
        return output
    }

    private func forecastLegend(_ id: String, text: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.diagonal").foregroundStyle(color.opacity(active ? 0.75 : 0.45))
            Image(systemName: "circle").foregroundStyle(color.opacity(active ? 1 : 0.45))
            Text(text).foregroundStyle(color.opacity(active ? 1 : 0.55))
        }
        .accessibilityElement(children: .combine)
    }
}

private enum PlanUsageAccent {
    static func read() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else { return [:] }
        return providers.reduce(into: [:]) { output, provider in
            guard let id = provider["id"] as? String, ["codex", "claude"].contains(id),
                  let hex = provider["accentColor"] as? String else { return }
            let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if clean.count == 6 && UInt64(clean, radix: 16) != nil { output[id] = clean }
        }
    }
}
