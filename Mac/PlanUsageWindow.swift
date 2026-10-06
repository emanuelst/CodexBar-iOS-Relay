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

private struct PlanUsageWindowGraph: Identifiable {
    let provider: String
    let window: String
    let graph: PlanUsageGraph
    var id: String { "\(provider):\(window)" }
}

private struct PlanUsageChartEvent: Identifiable {
    let id: String
    let date: Date
    let title: String
    let value: String
    let color: Color
}

struct PlanUsageWindow: View {
    @AppStorage("floatingMode") private var floating = false
    @State private var provider = "Combined"
    @State private var lane = "weekly"
    @State private var normalized = false
    @State private var histories: [String: [PlanUsageSeries]] = [:]
    @State private var accents: [String: String] = [:]
    @State private var hoveredEventID: String?
    @State private var hoverLocation: CGPoint = .zero
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
    private func color(_ id: String) -> Color {
        // CodexBar shipped provider colours. Optional config overrides use the same RGB hex format.
        let defaults = id == "codex" ? "49A3B0" : "CC7C5E"
        let hex = accents[id] ?? defaults
        let value = UInt64(hex, radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    @ViewBuilder
    private func providerGraph(_ id: String, window: String, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(id.capitalized + " · " + laneTitle(window), systemImage: "chart.xyaxis.line")
                .font(.headline).foregroundStyle(color(id))
            if let graph = graph(id, in: window, now: now) {
                let timeZone = TimeZone.current
                let forecast = runoutForecast(graph)
                let axisEnd = max(graph.reset, forecast?.depletionDate ?? graph.reset)
                let axis = PlanUsageTimeAxis(start: graph.start, end: axisEnd, timeZone: timeZone)
                let events = chartEvents(id: id, window: window, graph: graph, forecast: forecast, now: now)
                Chart {
                    RuleMark(x: .value("Window start", graph.start))
                        .foregroundStyle(color(id).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
                        .accessibilityLabel("\(id.capitalized) window start")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                    PointMark(x: .value("Window start", graph.start), y: .value("Top", 100))
                        .symbol(.square).symbolSize(50).foregroundStyle(color(id))
                        .accessibilityHidden(true)
                    if let forecast {
                        let endpoint = forecast.depletionDate ?? graph.reset
                        let beforeReset = min(endpoint, graph.reset)
                        let beforeResetRemaining = forecast.pace.remainingPercent(at: beforeReset, observedAt: graph.last.date) ?? graph.last.remaining
                        LineMark(x: .value("Time", graph.last.date), y: .value("Remaining", graph.last.remaining), series: .value("Series", "Run-out projection"))
                            .foregroundStyle(color(id).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        LineMark(x: .value("Time", beforeReset), y: .value("Remaining", beforeResetRemaining), series: .value("Series", "Run-out projection"))
                            .foregroundStyle(color(id).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if let depletionDate = forecast.depletionDate, depletionDate > graph.reset {
                            LineMark(x: .value("Time", graph.reset), y: .value("Remaining", forecast.remainingAtReset), series: .value("Series", "Hypothetical after reset"))
                                .foregroundStyle(color(id).opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            LineMark(x: .value("Time", depletionDate), y: .value("Remaining", 0), series: .value("Series", "Hypothetical after reset"))
                                .foregroundStyle(color(id).opacity(0.25))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            PointMark(x: .value("Projected depletion", depletionDate), y: .value("Remaining", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .accessibilityLabel("Projected depletion if pace continues beyond reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletionDate, now: now))
                        } else if let depletionDate = forecast.depletionDate {
                            PointMark(x: .value("Projected depletion", depletionDate), y: .value("Remaining", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .accessibilityLabel("Projected depletion")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletionDate, now: now))
                        }
                    }
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "Recorded"))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Time", graph.last.date), y: .value("Remaining", graph.last.remaining))
                        .foregroundStyle(color(id)).symbolSize(35)
                    RuleMark(x: .value("Reset", graph.reset))
                        .foregroundStyle(color(id))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .accessibilityLabel("\(id.capitalized) reset")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                    PointMark(x: .value("Reset", graph.reset), y: .value("Top", 100))
                        .symbol(.diamond).symbolSize(64).foregroundStyle(color(id))
                        .accessibilityHidden(true)
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .accessibilityLabel("Current time")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                    PointMark(x: .value("Now label", now), y: .value("Top", 100))
                        .symbolSize(0)
                        .annotation(position: .bottom, alignment: .center, spacing: 3) {
                            Text("Now")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .accessibilityHidden(true)
                }
                .chartXScale(domain: axis.plotStart...axis.plotEnd).chartYScale(domain: 0...100)
                .chartOverlay { proxy in
                    hoverOverlay(proxy: proxy, events: events, axisStart: axis.plotStart, axisEnd: axis.plotEnd, epochSeconds: false)
                }
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
                .chartLegend(.hidden).frame(height: 188)
                .accessibilityLabel(id.capitalized + " recorded remaining quota")
                Label("Window start · \(ResetCountdown.absoluteDateTime(graph.start, now: now))", systemImage: "square.fill")
                    .font(.caption2)
                    .foregroundStyle(color(id))
                Label("Reset · \(ResetCountdown.absoluteDateTime(graph.reset, now: now))", systemImage: "diamond.fill")
                    .font(.caption2)
                    .foregroundStyle(color(id))
                    .accessibilityLabel("\(id.capitalized) reset at \(ResetCountdown.absoluteDateTime(graph.reset, now: now))")
                forecastDetail(forecast, graph: graph, id: id, now: now)
                capture(graph, id: id, now: now)
            } else { unavailable(id, window: window) }
        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    private func capture(_ graph: PlanUsageGraph, id: String, now: Date) -> some View {
        let age = max(0, now.timeIntervalSince(graph.last.date))
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(graph.last.remaining.formatted(.number.precision(.fractionLength(0))))% remaining")
            Text("Last capture \(graph.last.date.formatted(date: .abbreviated, time: .shortened))\(age >= 300 ? " · stale recorded data" : "")")
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func unavailable(_ id: String, window: String) -> some View {
        Text("\(id.capitalized) \(laneTitle(window)): unavailable — no recorded, active quota window for the selected account.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
    }

    private func timePill(_ date: Date, color: Color) -> some View {
        Text(date.formatted(.dateTime.hour().minute()))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    private func eventPill(_ title: String, at date: Date, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text(date.formatted(.dateTime.hour().minute())).monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
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
            .foregroundStyle(color(id).opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func runoutPoint(id: String, window: String, date: Date, now: Date, plotPosition: Double? = nil) -> some ChartContent {
        let time = ResetCountdown.absoluteDateTime(date, now: now)
        let xValue: PlottableValue<Double> = .value("Run-out", plotPosition ?? date.timeIntervalSince1970)
        let yValue: PlottableValue<Double> = .value("Remaining", 0.0)
        return PointMark(x: xValue, y: yValue)
            .symbol(.circle).symbolSize(60).foregroundStyle(color(id))
            .accessibilityLabel(id.capitalized + " " + window + " projected run-out")
            .accessibilityValue(time)
    }

    private func chartEvents(id: String, window: String, graph: PlanUsageGraph, forecast: PlanUsageRunoutForecast?, now: Date) -> [PlanUsageChartEvent] {
        var events = [
            PlanUsageChartEvent(id: "\(id)-\(window)-start", date: graph.start, title: "\(id.capitalized) · \(laneTitle(window)) starts", value: ResetCountdown.absoluteDateTime(graph.start, now: now), color: color(id)),
            PlanUsageChartEvent(id: "\(id)-\(window)-reset", date: graph.reset, title: "\(id.capitalized) · \(laneTitle(window)) reset", value: ResetCountdown.absoluteDateTime(graph.reset, now: now), color: color(id)),
            PlanUsageChartEvent(id: "now", date: now, title: "Now", value: ResetCountdown.absoluteDateTime(now, now: now), color: .secondary)
        ]
        if let depletion = forecast?.depletionDate {
            events.append(PlanUsageChartEvent(id: "\(id)-\(window)-runout", date: depletion, title: "\(id.capitalized) · \(laneTitle(window)) forecast", value: "Out · " + ResetCountdown.absoluteDateTime(depletion, now: now), color: color(id)))
        }
        return events
    }

    private func hoverOverlay(proxy: ChartProxy, events: [PlanUsageChartEvent], axisStart: Date, axisEnd: Date, epochSeconds: Bool, focusAxis: PlanUsageFocusAxis? = nil) -> some View {
        let uniqueEvents = events.reduce(into: [PlanUsageChartEvent]()) { result, event in
            if !result.contains(where: { $0.id == event.id }) { result.append(event) }
        }
        return GeometryReader { geometry in
            let plotRect = proxy.plotFrame.map { geometry[$0] } ?? .zero
            let eventPosition: (PlanUsageChartEvent) -> CGFloat? = { event in
                if let focusAxis { return proxy.position(forX: focusAxis.position(event.date)) }
                return epochSeconds ? proxy.position(forX: event.date.timeIntervalSince1970) : proxy.position(forX: event.date)
            }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotX = location.x - plotRect.minX
                            guard plotX >= 0, plotX <= plotRect.width else { hoveredEventID = nil; return }
                            let nearby = uniqueEvents.compactMap { event -> (PlanUsageChartEvent, CGFloat)? in
                                guard let x = eventPosition(event), abs(x - plotX) <= 12 else { return nil }
                                return (event, abs(x - plotX))
                            }.sorted { $0.1 < $1.1 }
                            hoveredEventID = nearby.first?.0.id
                            hoverLocation = location
                        case .ended:
                            hoveredEventID = nil
                        }
                    }
                if let event = uniqueEvents.first(where: { $0.id == hoveredEventID }), let selectedX = eventPosition(event) {
                    let nearby = uniqueEvents.filter { abs((eventPosition($0) ?? -.infinity) - selectedX) <= 6 }
                    let cardWidth = min(330.0, max(200.0, Double(geometry.size.width) - 20))
                    let cardHeight = Double(nearby.count) * 44 + 14
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(nearby) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.caption.weight(.semibold))
                                Text(item.value).font(.caption.monospacedDigit())
                            }.foregroundStyle(item.color)
                        }
                    }
                    .frame(width: cardWidth - 18, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(event.color.opacity(0.25)))
                    .shadow(radius: 4, y: 2)
                    .position(x: min(max(Double(hoverLocation.x), cardWidth / 2 + 10), Double(geometry.size.width) - cardWidth / 2 - 10),
                              y: min(max(Double(hoverLocation.y) - 40, cardHeight / 2 + 8), Double(geometry.size.height) - cardHeight / 2 - 8))
                    .allowsHitTesting(false)
                }
            }
        }
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

    @ViewBuilder
    private func forecastDetail(_ forecast: PlanUsageRunoutForecast?, graph: PlanUsageGraph, id: String, now: Date) -> some View {
        if let forecast, let depletion = forecast.depletionDate {
            Label("Forecast · out \(ResetCountdown.absoluteDateTime(depletion, now: now))", systemImage: "circle")
                .font(.caption2).foregroundStyle(color(id))
                if forecast.extendsPastReset {
                    Text("After reset: hypothetical if this pace continues")
                        .font(.caption2).foregroundStyle(.secondary)
                }
        } else if forecast != nil {
            Label("At this pace, usage lasts through reset", systemImage: "line.diagonal")
                .font(.caption2).foregroundStyle(color(id))
        } else {
            Text("Run-out estimate hidden · waiting for enough usage (3% expected)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func combinedDomain(_ graphs: [(String, PlanUsageGraph)]) -> ClosedRange<Double> {
        if normalized { return 0...100 }
        let start = graphs.map { $0.1.start.timeIntervalSince1970 }.min() ?? 0
        let reset = graphs.map { $0.1.reset }.max() ?? Date(timeIntervalSince1970: start + 1)
        let projected = graphs.compactMap { runoutForecast($0.1)?.depletionDate }.max() ?? reset
        let axis = PlanUsageTimeAxis(start: Date(timeIntervalSince1970: start), end: max(reset, projected), timeZone: .current)
        return axis.plotStart.timeIntervalSince1970...max(start + 1, axis.plotEnd.timeIntervalSince1970)
    }
    private func timelineAxis(_ graphs: [(String, PlanUsageGraph)]) -> PlanUsageTimeAxis {
        let start = graphs.map { $0.1.start }.min() ?? .now
        let reset = graphs.map { $0.1.reset }.max() ?? start.addingTimeInterval(1)
        let projected = graphs.compactMap { runoutForecast($0.1)?.depletionDate }.max() ?? reset
        let end = max(reset, projected)
        return PlanUsageTimeAxis(start: start, end: end, timeZone: .current)
    }

    private func overlayBoth(now: Date) -> some View {
        let entries = [("codex", "session"), ("claude", "session"), ("codex", "weekly"), ("claude", "weekly")]
            .compactMap { id, window in graph(id, in: window, now: now).map { PlanUsageWindowGraph(provider: id, window: window, graph: $0) } }
        let earliest = entries.map { $0.graph.start }.min() ?? now.addingTimeInterval(-1)
        let latestReset = entries.map { $0.graph.reset }.max() ?? now.addingTimeInterval(1)
        let latestDepletion = entries.compactMap { runoutForecast($0.graph)?.depletionDate }.max() ?? latestReset
        let axis = PlanUsageTimeAxis(start: earliest, end: max(latestReset, latestDepletion), timeZone: .current)
        let sessions = entries.filter { $0.window == "session" }
        let sessionStart = min(sessions.map { $0.graph.start }.min() ?? now, now.addingTimeInterval(-3 * 3600))
        let sessionEnd = max(sessions.map { $0.graph.reset }.max() ?? now, now.addingTimeInterval(3 * 3600))
        let sessionAxis = PlanUsageTimeAxis(start: sessionStart, end: sessionEnd, timeZone: .current)
        let focus = PlanUsageFocusAxis(start: axis.plotStart, end: axis.plotEnd, focusStart: sessionAxis.plotStart, focusEnd: sessionAxis.plotEnd)
        let ticks = Array(Set(axis.dayBoundaries.filter { $0 < focus.focusStart || $0 > focus.focusEnd } + sessionAxis.hourBoundaries.filter { $0 >= focus.focusStart && $0 <= focus.focusEnd })).sorted()
        let events = entries.flatMap { item in
            chartEvents(id: item.provider, window: item.window, graph: item.graph, forecast: runoutForecast(item.graph), now: now)
        } + focus.breakDates.enumerated().map { index, date in
            PlanUsageChartEvent(id: "focus-\(index)", date: date, title: date == focus.focusStart ? "Expanded hours begin" : "Expanded hours end", value: ResetCountdown.absoluteDateTime(date, now: now), color: .secondary)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text(normalized ? "Combined · Session + Weekly · Normalized" : "Combined · Session + Weekly")
                .font(.headline)
            if !entries.isEmpty {
                Chart {
                    if !normalized, !focus.breakDates.isEmpty {
                        RectangleMark(xStart: .value("Expanded hours", focus.position(focus.focusStart)), xEnd: .value("Expanded hours", focus.position(focus.focusEnd)), yStart: .value("Bottom", 0.0), yEnd: .value("Top", 100.0))
                            .foregroundStyle(.secondary.opacity(0.045)).accessibilityHidden(true)
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
                        let lineStyle = StrokeStyle(lineWidth: quotaWindow == "session" ? 2.4 : 2, dash: quotaWindow == "session" ? [] : [5, 3])

                        if normalized {
                            evenUseGuide(series: item.id)
                        } else if let forecast = runoutForecast(graph) {
                            let end = min(forecast.depletionDate ?? graph.reset, graph.reset)
                            let remaining = forecast.pace.remainingPercent(at: end, observedAt: graph.last.date) ?? graph.last.remaining
                            focusedLine([graph.last, .init(date: end, remaining: remaining)], series: "Forecast " + item.id, axis: focus, tint: color(id).opacity(0.62), stroke: StrokeStyle(lineWidth: 1.2, dash: quotaWindow == "session" ? [4, 3] : [2, 3]))
                            if let depletion = forecast.depletionDate {
                                let depletionRemaining = forecast.pace.remainingPercent(at: depletion, observedAt: graph.last.date) ?? 0
                                if depletion > graph.reset {
                                    focusedLine([.init(date: graph.reset, remaining: forecast.remainingAtReset), .init(date: depletion, remaining: depletionRemaining)], series: "After reset " + item.id, axis: focus, tint: color(id).opacity(0.28), stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                                }
                                runoutPoint(id: id, window: quotaWindow, date: depletion, now: now, plotPosition: focus.position(depletion))
                            }
                        }

                        ForEach(normalized ? graph.samples : focus.vertices(graph.samples), id: \.date) { point in
                            LineMark(x: .value("Time", normalized ? graph.progress(point.date) : focus.position(point.date)), y: .value("Remaining", point.remaining), series: .value("Quota", item.id))
                                .foregroundStyle(color(id))
                                .lineStyle(lineStyle)
                        }
                        PointMark(x: .value("Latest capture", normalized ? graph.progress(graph.last.date) : focus.position(graph.last.date)), y: .value("Remaining", graph.last.remaining))
                            .foregroundStyle(color(id)).symbolSize(38)
                            .annotation(position: seriesTagPosition(item), alignment: quotaWindow == "session" ? (id == "codex" ? .trailing : .leading) : .center, spacing: 3) {
                                Text("\(id.capitalized) · \(quotaWindow == "session" ? "5h" : "Weekly")")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(color(id))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.regularMaterial, in: Capsule())
                            }

                        if !normalized {
                            RuleMark(x: .value("\(id.capitalized) \(quotaWindow) start", focus.position(graph.start)))
                                .foregroundStyle(color(id).opacity(0.42))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
                                .accessibilityLabel("\(id.capitalized) \(quotaWindow) window start")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                            PointMark(x: .value("\(id.capitalized) \(quotaWindow) start", focus.position(graph.start)), y: .value("Top", 100))
                                .symbol(.square).symbolSize(48).foregroundStyle(color(id))
                                .accessibilityHidden(true)
                            RuleMark(x: .value("\(id.capitalized) \(quotaWindow) reset", focus.position(graph.reset)))
                                .foregroundStyle(color(id))
                                .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
                                .accessibilityLabel("\(id.capitalized) \(quotaWindow) reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                            PointMark(x: .value("\(id.capitalized) \(quotaWindow) reset", focus.position(graph.reset)), y: .value("Top", 100))
                                .symbol(.diamond).symbolSize(60).foregroundStyle(color(id))
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
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .accessibilityLabel("Current time")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                        PointMark(x: .value("Now label", focus.position(now)), y: .value("Top", 110))
                            .symbolSize(0)
                            .annotation(position: .bottom, alignment: .center, spacing: 3) {
                                Text("Now").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(.regularMaterial, in: Capsule())
                            }
                    }
                }
                .chartXScale(domain: normalized ? 0...100 : 0...1)
                .chartYScale(domain: 0...112)
                .chartOverlay { proxy in
                    if normalized {
                        Rectangle().fill(.clear)
                    } else {
                        hoverOverlay(proxy: proxy, events: events, axisStart: axis.plotStart, axisEnd: axis.plotEnd, epochSeconds: true, focusAxis: focus)
                    }
                }
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis {
                    AxisMarks(values: normalized ? [0, 25, 50, 75, 100] : ticks.map { focus.position($0) }) { value in
                        if normalized {
                            AxisGridLine(); AxisTick()
                            if let progress = value.as(Double.self) { AxisValueLabel("\(Int(progress))%") }
                        } else if let position = value.as(Double.self) {
                            let date = focus.date(at: position)
                            let isFocused = date >= focus.focusStart.addingTimeInterval(-1) && date <= focus.focusEnd.addingTimeInterval(1)
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(isFocused ? 0.1 : 0.18))
                            AxisTick()
                            AxisValueLabel(collisionResolution: .greedy) {
                                Text(isFocused ? sessionAxis.label(for: date, timeZone: .current) : axis.label(for: date, timeZone: .current))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 280)
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

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(entries, id: \.id) { item in
                    if normalized {
                        Label("\(item.provider.capitalized) · \(item.window == "session" ? "5h" : "Weekly")", systemImage: "circle.fill")
                            .font(.caption2).foregroundStyle(color(item.provider))
                    } else {
                        bothForecastLegend(item, now: now)
                    }
                }
            }
            if normalized {
                Label("Even-use guide", systemImage: "line.diagonal").font(.caption2).foregroundStyle(.secondary)
            }
            if !normalized {
                Label("Squares: window starts · diamonds: resets", systemImage: "square.dashed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(item.provider.capitalized) \(item.window == "session" ? "5-hour" : "weekly") start · \(ResetCountdown.absoluteDateTime(item.graph.start, now: now))", systemImage: "square.fill")
                        .font(.caption2).foregroundStyle(color(item.provider))
                    Label("\(item.provider.capitalized) reset · \(ResetCountdown.absoluteDateTime(item.graph.reset, now: now))", systemImage: "diamond.fill")
                        .font(.caption2).foregroundStyle(color(item.provider))
                    capture(item.graph, id: item.provider, now: now)
                }
            }
        }
        .padding(16)
    }

    private func seriesTagPosition(_ item: PlanUsageWindowGraph) -> AnnotationPosition {
        switch (item.provider, item.window) {
        case ("codex", "session"): return .top
        case ("claude", "session"): return .bottom
        case ("codex", "weekly"): return .leading
        default: return .trailing
        }
    }

    private func resetTagPosition(_ item: PlanUsageWindowGraph) -> AnnotationPosition {
        item.window == "session" ? (item.provider == "codex" ? .bottom : .top) : (item.provider == "codex" ? .leading : .trailing)
    }

    private func bothForecastLegend(_ item: PlanUsageWindowGraph, now: Date) -> some View {
        let forecast = runoutForecast(item.graph)
        let detail: String
        if let forecast, let date = forecast.depletionDate {
            detail = "Out · " + ResetCountdown.absoluteDateTime(date, now: now)
        } else if forecast != nil {
            detail = "Lasts through reset"
        } else {
            detail = "Waiting for enough usage to estimate"
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "line.diagonal")
                Image(systemName: "circle")
                Text("\(item.provider.capitalized) · \(item.window == "session" ? "5h" : laneTitle(item.window)) forecast")
                    .fontWeight(.semibold)
            }
            Text(detail).monospacedDigit()
            if forecast?.extendsPastReset == true {
                Text("After reset · hypothetical continuation").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(color(item.provider).opacity(forecast == nil ? 0.55 : 1))
        .accessibilityElement(children: .combine)
        .help("Dashed line and hollow circle show this quota's forecast and projected run-out. Exact time: \(forecast?.depletionDate.map { ResetCountdown.absoluteDateTime($0, now: now) } ?? "unavailable")")
    }

    private func overlay(now: Date, window: String) -> some View {
        let graphs = ["codex", "claude"].compactMap { id in graph(id, in: window, now: now).map { (id, $0) } }
        let timeZone = TimeZone.current
        let axis = timelineAxis(graphs)
        let events = graphs.flatMap { id, graph in
            chartEvents(id: id, window: window, graph: graph, forecast: runoutForecast(graph), now: now)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text((normalized ? "Normalized · " : "Combined · ") + laneTitle(window)).font(.headline)
            if !graphs.isEmpty {
            Chart {
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
                    } else if let forecast = runoutForecast(graph) {
                        let endpoint = forecast.depletionDate ?? graph.reset
                        let preResetEnd = min(endpoint, graph.reset)
                        let preResetRemaining = forecast.pace.remainingPercent(at: preResetEnd, observedAt: graph.last.date) ?? graph.last.remaining
                        LineMark(x: .value("Time", graph.last.date.timeIntervalSince1970), y: .value("Remaining %", graph.last.remaining), series: .value("Series", id + " run-out projection"))
                            .foregroundStyle(color(id).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        LineMark(x: .value("Time", preResetEnd.timeIntervalSince1970), y: .value("Remaining %", preResetRemaining), series: .value("Series", id + " run-out projection"))
                            .foregroundStyle(color(id).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if let depletion = forecast.depletionDate, depletion > graph.reset {
                            LineMark(x: .value("Time", graph.reset.timeIntervalSince1970), y: .value("Remaining %", forecast.remainingAtReset), series: .value("Series", id + " hypothetical after reset"))
                                .foregroundStyle(color(id).opacity(0.24))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            LineMark(x: .value("Time", depletion.timeIntervalSince1970), y: .value("Remaining %", 0), series: .value("Series", id + " hypothetical after reset"))
                                .foregroundStyle(color(id).opacity(0.24))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                            PointMark(x: .value("Projected depletion", depletion.timeIntervalSince1970), y: .value("Remaining %", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .annotation(position: .top, alignment: id == "codex" ? .leading : .trailing, spacing: 3) { eventPill("\(id.capitalized) out", at: depletion, color: color(id)) }
                                .accessibilityLabel("\(id.capitalized) projected depletion if pace continues beyond reset")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletion, now: now))
                        } else if let depletion = forecast.depletionDate {
                            PointMark(x: .value("Projected depletion", depletion.timeIntervalSince1970), y: .value("Remaining %", 0))
                                .symbol(.circle).symbolSize(64).foregroundStyle(color(id))
                                .annotation(position: .top, alignment: id == "codex" ? .leading : .trailing, spacing: 3) { eventPill("\(id.capitalized) out", at: depletion, color: color(id)) }
                                .accessibilityLabel("\(id.capitalized) projected depletion")
                                .accessibilityValue(ResetCountdown.absoluteDateTime(depletion, now: now))
                        }
                    }
                }
                if !normalized {
                    ForEach(graphs, id: \.0) { id, graph in
                        RuleMark(x: .value("\(id.capitalized) window start", graph.start.timeIntervalSince1970))
                            .foregroundStyle(color(id).opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
                            .accessibilityLabel("\(id.capitalized) window start")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(graph.start, now: now))
                        PointMark(x: .value("\(id.capitalized) window start", graph.start.timeIntervalSince1970), y: .value("Top", 100))
                            .symbol(.square).symbolSize(50).foregroundStyle(color(id))
                            .accessibilityHidden(true)
                    }
                    RuleMark(x: .value("Now", now.timeIntervalSince1970))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .accessibilityLabel("Current time")
                        .accessibilityValue(ResetCountdown.absoluteDateTime(now, now: now))
                    PointMark(x: .value("Now label", now.timeIntervalSince1970), y: .value("Top", 100))
                        .symbolSize(0)
                        .annotation(position: .bottom, alignment: .center, spacing: 3) {
                            Text("Now")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .accessibilityHidden(true)
                    ForEach(graphs, id: \.0) { id, graph in
                        RuleMark(x: .value("\(id.capitalized) reset", graph.reset.timeIntervalSince1970))
                            .foregroundStyle(color(id))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .accessibilityLabel("\(id.capitalized) reset")
                            .accessibilityValue(ResetCountdown.absoluteDateTime(graph.reset, now: now))
                        PointMark(x: .value("\(id.capitalized) reset", graph.reset.timeIntervalSince1970), y: .value("Top", 100))
                            .symbol(.diamond).symbolSize(64).foregroundStyle(color(id))
                            .annotation(position: id == "codex" ? .bottom : .top, alignment: .center, spacing: 2) { eventPill("\(id.capitalized) reset", at: graph.reset, color: color(id)) }
                            .accessibilityHidden(true)
                    }
                }
                ForEach(graphs, id: \.0) { id, graph in
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Elapsed window %", position(point.date, graph: graph)), y: .value("Remaining %", point.remaining), series: .value("Provider", id))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Elapsed window %", position(graph.last.date, graph: graph)), y: .value("Remaining %", graph.last.remaining))
                        .foregroundStyle(color(id)).symbolSize(35)
                        .annotation(position: id == "codex" ? .top : .bottom, alignment: id == "codex" ? .leading : .trailing, spacing: 3) {
                            Text(id.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(color(id))
                                .padding(.horizontal, 5).padding(.vertical, 2).background(.regularMaterial, in: Capsule())
                        }
                }
            }.chartXScale(domain: combinedDomain(graphs)).chartYScale(domain: 0...100)
                .chartOverlay { proxy in
                    if normalized {
                        Rectangle().fill(.clear)
                    } else {
                        hoverOverlay(proxy: proxy, events: events, axisStart: axis.plotStart, axisEnd: axis.plotEnd, epochSeconds: true)
                    }
                }
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
                .chartLegend(.hidden).frame(height: 220)
            }
            Text(normalized
                ? "Elapsed quota-window progress (%) · provider resets align at 100%."
                : "Actual time · \(ResetCountdown.localTimeZoneLabel())")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                ForEach(["codex", "claude"], id: \.self) { id in
                    Label(id.capitalized, systemImage: "circle.fill").foregroundStyle(color(id))
                }
                Label("Reset", systemImage: "diamond.fill").foregroundStyle(.secondary)
                }
                if normalized {
                    Label("Even-use guide", systemImage: "line.diagonal").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(["codex", "claude"], id: \.self) { id in
                            if let graph = graph(id, in: window, now: now) {
                                bothForecastLegend(.init(provider: id, window: window, graph: graph), now: now)
                            }
                        }
                    }
                }
                if !normalized {
                    HStack(spacing: 14) {
                        ForEach(["codex", "claude"], id: \.self) { id in
                            Label("\(id.capitalized) start", systemImage: "square.fill").foregroundStyle(color(id))
                        }
                    }
                }
            }.font(.caption2)
            ForEach(["codex", "claude"], id: \.self) { id in
                if let graph = graph(id, in: window, now: now) {
                    Label("\(id.capitalized) window start · \(ResetCountdown.absoluteDateTime(graph.start, now: now))", systemImage: "square.fill")
                        .font(.caption2)
                        .foregroundStyle(color(id))
                    Label("\(id.capitalized) reset · \(ResetCountdown.absoluteDateTime(graph.reset, now: now))", systemImage: "diamond.fill")
                        .font(.caption2)
                        .foregroundStyle(color(id))
                        .accessibilityLabel("\(id.capitalized) reset at \(ResetCountdown.absoluteDateTime(graph.reset, now: now))")
                    capture(graph, id: id, now: now)
                } else { unavailable(id, window: window) }
            }
        }.padding(16)
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
