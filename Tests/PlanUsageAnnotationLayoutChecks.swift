import CoreGraphics
import Foundation

/// Deterministic checks for in-chart label lanes. Uses a fixed character-width measure,
/// so results do not depend on installed fonts.
@main enum PlanUsageAnnotationLayoutChecks {
    static func main() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 6.5 + 12 }
        let wide = CGRect(x: 40, y: 0, width: 560, height: 300)
        let narrow = CGRect(x: 40, y: 0, width: 220, height: 300)
        typealias Layout = PlanUsageAnnotationLayout

        func lane(_ id: String, _ variants: [String], _ x: CGFloat, _ band: Layout.Band = .top) -> Layout.Label {
            .init(id: id, variants: variants, anchorX: x, kind: .lane(band))
        }
        func assertClean(_ result: Layout.Result, in layout: Layout, _ labels: [Layout.Label], file: StaticString = #file, line: UInt = #line) {
            for (i, a) in result.placements.enumerated() {
                precondition(layout.plot.contains(a.frame), "\(a.id) leaves the plot", file: file, line: line)
                for b in result.placements[(i + 1)...] {
                    precondition(!a.frame.intersects(b.frame), "\(a.id) overlaps \(b.id)", file: file, line: line)
                }
                // A lane label must stay on its rule unless the plot edge forced a clamp.
                if a.lane != nil, let label = labels.first(where: { $0.id == a.id }),
                   a.frame.minX > layout.plot.minX, a.frame.maxX < layout.plot.maxX {
                    precondition(a.frame.minX <= label.anchorX && a.frame.maxX >= label.anchorX, "\(a.id) detached", file: file, line: line)
                }
            }
        }

        // Screenshot case: 7h session axis; Now 22:48, Claude reset 22:50, Codex reset 23:18.
        func x(_ minutes: Double, _ plot: CGRect) -> CGFloat { plot.minX + plot.width * CGFloat(minutes / 420) }
        func sessionLabels(_ plot: CGRect) -> [Layout.Label] {
            [lane("now", ["Now"], x(348, plot)),
             lane("codex-reset", ["Codex reset 23:18 · in 30m", "Codex 23:18 · in 30m", "23:18 · in 30m", "Codex 23:18", "23:18"], x(378, plot)),
             lane("claude-reset", ["Claude reset 22:50 · in 2m", "Claude 22:50 · in 2m", "22:50 · in 2m", "Claude 22:50", "22:50"], x(350, plot)),
             lane("codex-out", ["Codex out 22:56", "Out 22:56", "22:56"], x(356, plot), .bottom),
             lane("claude-out", ["Claude out 22:57", "Out 22:57", "22:57"], x(357, plot), .bottom)]
        }
        let wideLayout = Layout(plot: wide, topLanes: 3, bottomLanes: 2, measure: measure)
        let wideLabels = sessionLabels(wide)
        let wideResult = wideLayout.solve(wideLabels)
        precondition(wideResult.dropped.isEmpty)
        precondition(wideResult.placements.allSatisfy { $0.variant == 0 }, "wide plot keeps full text by stacking")
        precondition(Set(wideResult.placements.filter { $0.lane != nil && $0.frame.midY < 150 }.map(\.lane)).count == 3, "Now and both resets take separate top lanes")
        precondition(wideResult.placements.first { $0.id == "now" }?.lane == 0, "Now is nearest the data")
        assertClean(wideResult, in: wideLayout, wideLabels)

        // Same scene at the narrowest plot with the app's lane counts: nothing dropped, still clean.
        let tightLayout = Layout(plot: narrow, topLanes: 3, bottomLanes: 2, measure: measure)
        let tightLabels = sessionLabels(narrow)
        let tightResult = tightLayout.solve(tightLabels)
        precondition(tightResult.dropped.isEmpty)
        assertClean(tightResult, in: tightLayout, tightLabels)
        precondition(tightLayout.solve(tightLabels) == tightResult, "layout is deterministic")

        // One lane, labels spread out: the long reset text cannot sit beside Now, so it shortens.
        let spread = [lane("now", ["Now"], narrow.minX + 66), lane("reset", ["Codex reset 23:18 · in 30m", "Codex 23:18", "23:18"], narrow.minX + 176)]
        let oneLane = Layout(plot: narrow, topLanes: 1, bottomLanes: 0, measure: measure)
        let shortened = oneLane.solve(spread)
        precondition(shortened.dropped.isEmpty && shortened.placements.first { $0.id == "reset" }?.text == "Codex 23:18", "narrow plot shortens")
        assertClean(shortened, in: oneLane, spread)

        // Weekly variants keep the weekday even at their shortest.
        let weekly = lane("wk", ["Codex wk reset Fri 23:10", "Codex Fri 23:10", "Fri 23:10"], narrow.midX)
        let crowded = (0..<3).map { lane("filler\($0)", [String(repeating: "x", count: 30)], narrow.midX) }
        let weeklyResult = Layout(plot: narrow, topLanes: 3, bottomLanes: 0, measure: measure).solve(crowded + [weekly])
        precondition(weeklyResult.placements.first { $0.id == "wk" }.map { $0.text.contains("Fri") } ?? true)

        // Labels at the right edge are clamped inside the plot instead of being clipped.
        let edge = lane("edge", ["Claude wk reset Mon 10:59"], wide.maxX - 2)
        let edgeLayout = Layout(plot: wide, topLanes: 1, bottomLanes: 0, measure: measure)
        let edgeFrame = edgeLayout.solve([edge]).placements[0].frame
        precondition(edgeFrame.maxX <= wide.maxX && edgeFrame.minX >= wide.minX)

        // When lanes run out, the lowest-priority label is dropped, never an earlier one.
        let full = (0..<3).map { lane("p\($0)", ["Label number \($0)"], wide.midX) }
        let dropped = Layout(plot: wide, topLanes: 2, bottomLanes: 0, measure: measure).solve(full)
        precondition(dropped.dropped == ["p2"] && dropped.placements.map(\.id) == ["p0", "p1"])

        // Floating provider tags avoid markers and placed lane labels, and stay out of the bands.
        let point = CGPoint(x: wide.midX, y: 150)
        let marker = CGRect(x: point.x + 4, y: point.y - 30, width: 80, height: 30)
        let tagLayout = Layout(plot: wide, topLanes: 3, bottomLanes: 2, measure: measure)
        let tag = Layout.Label(id: "tag", variants: ["Codex · 5h"], anchorX: point.x, kind: .floating(point))
        let tagFrame = tagLayout.solve([tag], obstacles: [marker]).placements[0].frame
        precondition(!tagFrame.intersects(marker))
        precondition(tagFrame.minY >= tagLayout.laneRect(.top, 2).maxY && tagFrame.maxY <= tagLayout.laneRect(.bottom, 0).minY)

        // Bands sit outside the data: top lanes above 100%, bottom lanes below 0%.
        precondition(tagLayout.laneRect(.top, 0).minY > tagLayout.laneRect(.top, 2).minY)
        precondition(tagLayout.laneRect(.bottom, 1).maxY == wide.maxY)

        // Groups are independent: a crowded top lane must not shorten bottom-lane labels.
        let crowdedTop = (0..<3).map { lane("top\($0)", [String(repeating: "x", count: 40), "x"], wide.midX) }
        let roomyBottom = lane("bottom", ["Claude wk runs out Sat 12:48 · in 2d 14h", "wk 12:48"], wide.midX, .bottom)
        let mixed = Layout(plot: wide, topLanes: 1, bottomLanes: 1, measure: measure).solve(crowdedTop + [roomyBottom])
        precondition(mixed.placements.first { $0.id == "bottom" }?.variant == 0, "bottom keeps its full text")
        precondition(mixed.placements.map(\.id).first == "top0", "merged result keeps priority order")

        // Axis thinning keeps the first label and a minimum gap.
        precondition(Layout.thinned([0, 0.02, 0.05, 0.1, 0.12, 0.3], minimumGap: 0.085) == [0, 0.1, 0.3])

        print("Plan Usage annotation layout checks passed: lane stacking, shortening, determinism, weekday retention, edge clamping, priority drops, floating tag avoidance, independent groups, axis thinning")
    }
}
