import SwiftUI
import Charts

struct PlanUsageWindow: View {
    @AppStorage("floatingMode") private var floating = false
    @State private var provider = "Codex"
    @State private var lane = "session"
    @State private var normalized = false
    @State private var histories: [String: [PlanUsageSeries]] = [:]
    @State private var accents: [String: String] = [:]
    private let fixture: [String: [PlanUsageSeries]]?

    init(fixture: [String: [PlanUsageSeries]]? = nil, provider: String = "Codex", normalized: Bool = false, lane: String = "session") {
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
        return ["session", "weekly"] + Set(extra).sorted()
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
                            overlay(now: context.date)
                        } else {
                            ForEach(provider == "Combined" ? ["codex", "claude"] : [provider.lowercased()], id: \.self) { id in
                                providerGraph(id, now: context.date)
                            }
                        }
                    }.padding(2)
                }
                Text("Recorded locally by CodexBar · selected saved account per provider · \(TimeZone.current.identifier)")
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
        name == "opus" ? "Sonnet" : name.capitalized
    }
    private func graph(_ id: String, now: Date) -> PlanUsageGraph? {
        guard let series = histories[id]?.first(where: { $0.name == lane }) else { return nil }
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
    private func providerGraph(_ id: String, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(id.capitalized + " · " + laneTitle(lane), systemImage: "chart.xyaxis.line")
                .font(.headline).foregroundStyle(color(id))
            if let graph = graph(id, now: now) {
                Chart {
                    ForEach([graph.start, graph.reset], id: \.self) { date in
                        LineMark(x: .value("Time", date), y: .value("Remaining", date == graph.start ? 100 : 0), series: .value("Series", "Even use"))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Remaining", point.remaining), series: .value("Series", "Recorded"))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Time", graph.last.date), y: .value("Remaining", graph.last.remaining))
                        .foregroundStyle(color(id)).symbolSize(35)
                }
                .chartXScale(domain: graph.start...graph.reset).chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis(.hidden).chartLegend(.hidden).frame(height: 160)
                .accessibilityLabel(id.capitalized + " recorded remaining quota")
                HStack {
                    endpoint(graph.start, graph: graph, alignment: .leading)
                    Spacer()
                    endpoint(graph.reset, graph: graph, alignment: .trailing)
                }.font(.caption).foregroundStyle(.secondary)
                capture(graph, id: id, now: now)
            } else { unavailable(id) }
        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func endpoint(_ date: Date, graph: PlanUsageGraph, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if graph.reset.timeIntervalSince(graph.start) >= 86400 {
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            }
            Text(date.formatted(.dateTime.hour().minute()))
        }
    }
    private func capture(_ graph: PlanUsageGraph, id: String, now: Date) -> some View {
        let age = max(0, now.timeIntervalSince(graph.last.date))
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(graph.last.remaining.formatted(.number.precision(.fractionLength(0))))% remaining")
            Text("Last capture \(graph.last.date.formatted(date: .abbreviated, time: .shortened))\(age >= 300 ? " · stale recorded data" : "")")
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func unavailable(_ id: String) -> some View {
        Text("\(id.capitalized) \(laneTitle(lane)): unavailable — no recorded, active quota window for the selected account.")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
    }

    private func position(_ date: Date, graph: PlanUsageGraph) -> Double {
        normalized ? graph.progress(date) : date.timeIntervalSince1970
    }
    private func combinedDomain(_ graphs: [(String, PlanUsageGraph)]) -> ClosedRange<Double> {
        if normalized { return 0...100 }
        let start = graphs.map { $0.1.start.timeIntervalSince1970 }.min() ?? 0
        let end = graphs.map { $0.1.reset.timeIntervalSince1970 }.max() ?? 1
        return start...max(start + 1, end)
    }
    private func timelineTicks(_ graphs: [(String, PlanUsageGraph)]) -> [Double] {
        let domain = combinedDomain(graphs)
        return [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2, domain.upperBound]
    }

    private func overlay(now: Date) -> some View {
        let graphs = ["codex", "claude"].compactMap { id in graph(id, now: now).map { (id, $0) } }
        return VStack(alignment: .leading, spacing: 12) {
            Text((normalized ? "Normalized · " : "Combined · ") + laneTitle(lane)).font(.headline)
            if !graphs.isEmpty {
            Chart {
                ForEach(graphs, id: \.0) { id, graph in
                    ForEach([graph.start, graph.reset], id: \.self) { date in
                        LineMark(x: .value("Window position", position(date, graph: graph)),
                                 y: .value("Remaining %", date == graph.start ? 100 : 0),
                                 series: .value("Series", id + " guide"))
                            .foregroundStyle(color(id).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                ForEach(graphs, id: \.0) { id, graph in
                    ForEach(graph.samples, id: \.date) { point in
                        LineMark(x: .value("Elapsed window %", position(point.date, graph: graph)), y: .value("Remaining %", point.remaining), series: .value("Provider", id))
                            .foregroundStyle(color(id)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Elapsed window %", position(graph.last.date, graph: graph)), y: .value("Remaining %", graph.last.remaining)).foregroundStyle(color(id)).symbolSize(35)
                }
            }.chartXScale(domain: combinedDomain(graphs)).chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                 .chartXAxis {
                    AxisMarks(values: normalized ? [0, 25, 50, 75, 100] : timelineTicks(graphs)) { value in
                        AxisGridLine()
                        AxisTick()
                        if let progress = value.as(Double.self) {
                            AxisValueLabel(anchor: progress == combinedDomain(graphs).upperBound ? .topTrailing : progress == combinedDomain(graphs).lowerBound ? .topLeading : .top,
                                           collisionResolution: .disabled) {
                                if normalized { Text("\(Int(progress))%") }
                                else { Text(Date(timeIntervalSince1970: progress).formatted(.dateTime.month(.abbreviated).day().hour().minute())) }
                            }
                        }
                    }
                }
                .chartLegend(.hidden).frame(height: 220)
            }
            Text(normalized ? "Elapsed quota-window progress (%)" : "Actual time · \(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ForEach(["codex", "claude"], id: \.self) { id in
                    Label(id.capitalized, systemImage: "circle.fill").foregroundStyle(color(id))
                }
                Label("Even-use guide", systemImage: "line.diagonal").foregroundStyle(.secondary)
            }.font(.caption)
            ForEach(["codex", "claude"], id: \.self) { id in
                if let graph = graph(id, now: now) {
                    Text("\(id.capitalized) resets \(graph.reset.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    capture(graph, id: id, now: now)
                } else { unavailable(id) }
            }
        }.padding(16)
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
