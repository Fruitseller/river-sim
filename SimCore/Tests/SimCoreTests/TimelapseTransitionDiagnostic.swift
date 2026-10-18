import Foundation
import XCTest
@testable import SimCore
import SimRender

/// Ausgelieferte Render-Änderungen bei 60 und 30 J/s, ohne Kamera/GPU.
/// Aufruf: RS_MEASURE=1 swift test -c release --package-path SimCore
/// -Xswiftc -swift-version -Xswiftc 5 --filter testTimelapseTransitionDiagnostic
final class TimelapseTransitionDiagnostics: XCTestCase {
    func testTimelapseTransitionDiagnostic() throws {
        try skipUnlessMeasuring()
        let world = Terrain(config: .production, seed: 1337,
                            settleYears: SimConfig.productionSettleYears)
        while world.years < 20_000 { world.step(dtYears: 1000) }
        // Main._ready ruft nach RS_STEP ebenfalls recomputeFlow auf.
        world.recomputeFlowAfterEdit()
        let initial = world.state
        // Feste Landmaske am Messbeginn: Uferwanderung ändert den Nenner nicht.
        let land = world.h.indices.filter { world.h[$0] > world.cfg.sea }
        print("TRANSITION seed=1337 n=\(world.cfg.n) world=\(world.cfg.world) land=\(land.count) settle=\(SimConfig.productionSettleYears) coupling=\(world.cfg.meanderBeltCouplingYears)")
        print("Schwellen: Höhe 0.02 Welt-Y / heightScale=\(0.02 / RenderContract.heightScale) Sim-Höhe; Band >=\(WaterRender.protectBandThreshold); Wald >0.25; Raster max(|ΔR|,|ΔG|)>32/255; Farbe RGB-MAE/255. B/A des Wassers kodieren Richtung, A der Farbe Sand, keine Farbkanäle.")
        print("Alle Flächen in % der festen Landmaske. hL1=Σ|Δh|*heightScale/Landzahl (Welt-Y je Landzelle), RGB in %. Gehaltene Ebenen zählen als 0; Bau/Upload zusätzlich markiert. Keine Höhen-Interpolation/Shader-Messung.")

        // Bestehende Pass-Marken belegen den tatsächlichen Kopplungs-Aufruf;
        // keine nachgebaute Taktformel und kein zusätzlicher Produktions-Haken.
        let wasEnabled = SimProfile.enabled
        let oldHook = SimProfile.onPassEnd
        SimProfile.enabled = true
        defer {
            SimProfile.enabled = wasEnabled
            SimProfile.onPassEnd = oldHook
        }
        for rate in [60.0, 30.0] {
            let t = Terrain(allocating: .production, seed: 1337)
            t.restore(initial)
            let render = RenderState(geometryMode: true)
            render.renderGrid = t.cfg.n // balanced/quality, wie Main.terrain_grid_for
            render.invalidate(t, .replaced)
            let start = render.frame(t, .settled, now: 0)
            var shown = try XCTUnwrap(start.overlays)
            var coverage = render.riverRibbonMesh.bandCoverage
            var heights = t.h
            var rows: [TransitionRow] = []
            var now = 0.0
            var coupled = false
            SimProfile.onPassEnd = { name in
                if name == "belt.couple" { coupled = true }
            }
            print("\nTRANSITION rate=\(rate) dt=\(rate * 0.25) tick=0.25 overlay=\(RenderState.overlayIntervalSeconds) ribbon=\(RenderState.ribbonRebuildSeconds)")
            print("Jahr | Kopplung-am-Anfang | Bau Upload | Avulsion neugetrasst eingesetzt Neck Chute | hZellen h% hSumSim hL1 | Band+% Band-% | Wald% Raster% RGB%")
            // Der letzte Schritt bleibt vollständig (22505 statt 22500), damit
            // auch am Ende derselbe 15-/7.5-Jahr-Takt gilt.
            while t.years < 22_500 {
                let yearBefore = t.years
                let avulsions = t.meander.avulsions, retraced = t.meander.retraced
                let inserted = t.meander.coupledInserted
                let neck = t.meander.neckCutoffs, chute = t.meander.chuteCutoffs
                coupled = false
                t.step(dtYears: rate * 0.25)
                render.invalidate(t, .advanced)
                now += 0.25
                let frame = render.frame(t, .timelapse, now: now)
                var row = TransitionRow(year: t.years,
                                        couplingYear: coupled ? yearBefore : nil,
                                        built: frame.ribbonsRebuilt,
                                        uploaded: frame.overlays != nil,
                                        avulsions: t.meander.avulsions - avulsions,
                                        retraced: t.meander.retraced - retraced,
                                        inserted: t.meander.coupledInserted - inserted,
                                        neck: t.meander.neckCutoffs - neck,
                                        chute: t.meander.chuteCutoffs - chute)
                var added = 0, removed = 0, forest = 0, water = 0, rgb = 0
                var bandMass = 0.0
                var split = [0.0, 0.0, 0.0, 0.0]   // neu+, bestehend+, bestehend−, weg−
                let freshCoverage = frame.ribbonsRebuilt ? render.riverRibbonMesh.bandCoverage : coverage
                for k in land {
                    let dh = abs(t.h[k] - heights[k])
                    if dh * RenderContract.heightScale > 0.02 { row.heightCells += 1 }
                    row.heightSum += dh
                    if frame.ribbonsRebuilt {
                        let old = coverage[k] >= WaterRender.protectBandThreshold
                        let new = freshCoverage[k] >= WaterRender.protectBandThreshold
                        if new && !old { added += 1 }
                        if old && !new { removed += 1 }
                        bandMass += abs(freshCoverage[k] - coverage[k])
                        let d = freshCoverage[k] - coverage[k]
                        if d > 0 { split[coverage[k] > 0 ? 1 : 0] += d }
                        else if d < 0 { split[freshCoverage[k] > 0 ? 2 : 3] -= d }
                    }
                    if let next = frame.overlays {
                        if Double(abs(Int(next.forestMask[k]) - Int(shown.forestMask[k]))) / 255 > 0.25 {
                            forest += 1
                        }
                        let o = k * 4
                        if max(abs(Int(next.water[o]) - Int(shown.water[o])),
                               abs(Int(next.water[o + 1]) - Int(shown.water[o + 1]))) > 32 {
                            water += 1
                        }
                        for c in 0..<3 { rgb += abs(Int(next.colors[o + c]) - Int(shown.colors[o + c])) }
                    }
                }
                let count = Double(land.count)
                row.metrics = [100 * Double(row.heightCells) / count,
                               row.heightSum * RenderContract.heightScale / count,
                               100 * Double(added) / count, 100 * Double(removed) / count,
                               100 * Double(forest) / count, 100 * Double(water) / count,
                               100 * Double(rgb) / (count * 3 * 255),
                               100 * bandMass / count]
                if frame.ribbonsRebuilt {
                    print(String(format: "BANDSPLIT %.1f neu+ %.4f bestehend+ %.4f bestehend- %.4f weg- %.4f (%% Land) Geister %d",
                                 t.years, 100 * split[0] / Double(land.count), 100 * split[1] / Double(land.count),
                                 100 * split[2] / Double(land.count), 100 * split[3] / Double(land.count),
                                 render.ribbonGhostCount))
                    let matureNow = render.ribbonMatureCoverage
                    var newMature = 0.0, newYoung = 0.0
                    if matureNow.count == freshCoverage.count {
                        for k in land where coverage[k] <= 0 && freshCoverage[k] > 0 {
                            if matureNow[k] > 0 { newMature += freshCoverage[k] } else { newYoung += freshCoverage[k] }
                        }
                    }
                    print(String(format: "GROWTH %.1f jung %d ausgenommen %d neu aus ausgewachsenen %.4f aus jungen %.4f (%% Land)",
                                 t.years, render.ribbonGrowthStats.young, render.ribbonGrowthStats.exempt,
                                 100 * newMature / Double(land.count), 100 * newYoung / Double(land.count)))
                }
                heights = t.h
                if frame.ribbonsRebuilt { coverage = freshCoverage }
                if let next = frame.overlays { shown = next }
                rows.append(row)
                print(row.line)
            }
            summarize(rows, rate: rate)
        }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let v = values.sorted(), m = v.count / 2
        return v.count % 2 == 0 ? (v[m - 1] + v[m]) / 2 : v[m]
    }

    private func summarize(_ rows: [TransitionRow], rate: Double) {
        let events = rows.indices.filter { rows[$0].couplingYear != nil }
        let windows = Set(events.flatMap { Array($0...min($0 + 3, rows.count - 1)) })
        let normal = rows.indices.filter { !windows.contains($0) }
        // BandΣ% = Σ|Δ Deckung| (gewichtet: ein dünnes, einwachsendes Band
        // zählt mit seiner Deckkraft, nicht als voll gedeckte Zelle).
        let names = ["h%", "hL1", "Band+%", "Band-%", "Wald%", "Raster%", "RGB%", "BandΣ%"]
        let allMedian = names.indices.map { j in median(normal.map { rows[$0].metrics[j] }) }
        let uncoupled = rows.filter { $0.couplingYear == nil }
        let activeMedian = names.indices.map { j in
            median(normal.filter { rows[$0].active(j) }.map { rows[$0].metrics[j] })
        }
        func values(_ v: [Double]) -> String {
            v.map { String(format: "%.6f", $0) }.joined(separator: " | ")
        }
        print("\nSUMMARY rate=\(rate): \(names.joined(separator: " | "))")
        print("Median aller Nicht-Kopplungsschritte n=\(uncoupled.count): \(values(names.indices.map { j in median(uncoupled.map { $0.metrics[j] }) }))")
        print("Normal schließt Kopplung UND die 3 Folgeschritte aus; aktiver Median berücksichtigt nur tatsächliche Uploads/Bauten.")
        print("Median normal, alle Takte n=\(normal.count): \(values(allMedian))")
        print("Median normal, nur Upload/Bau: \(values(activeMedian))")
        let builds = rows.indices.filter { rows[$0].built }
        let cadence = zip(builds, builds.dropFirst()).reduce(into: [String: Int]()) { counts, pair in
            let seconds = (rows[pair.1].year - rows[pair.0].year) / rate
            counts[String(format: "%.2f s", seconds), default: 0] += 1
        }
        print("BAND-TAKT: " + cadence.keys.sorted().map { "\($0): \(cadence[$0]!) Abstände" }.joined(separator: ", "))
        let bandMedian = median(normal.filter { rows[$0].built }.map { rows[$0].metrics[2] + rows[$0].metrics[3] })
        print(String(format: "Bandwechsel + und - zusammen, aktiver Normal-Median: %.6f %%", bandMedian))
        for event in events {
            print("KOPPLUNG rate=\(rate) Sim-Anfang=\(rows[event].couplingYear!) ausgegeben=\(rows[event].year)")
            for i in max(0, event - 1)...min(event + 3, rows.count - 1) { print(rows[i].line) }
            let window = Array(rows[event...min(event + 3, rows.count - 1)])
            let peaks = names.indices.map { j in window.map { $0.metrics[j] }.max()! }
            print("Maximum Kopplung + 3: \(values(peaks))")
            print("Faktor gegen aktiven Normal-Median: \(values(names.indices.map { peaks[$0] / activeMedian[$0] }))")
        }
        // Ausreißer außerhalb der Kopplungsfenster je Ebene; bei Null-Median
        // liefert die absolute Unterkante sinnvolle, explizite Kandidaten.
        for j in names.indices {
            let floor = j == 1 ? 0.0001 : 0.01
            let limit = max(floor, 5 * activeMedian[j])
            let spikes = normal.filter { rows[$0].active(j) && rows[$0].metrics[j] > limit }
            print("WEITERE \(names[j]) >max(5*Median,\(floor)): " + spikes.map {
                String(format: "%.1f=%.6f(B%d,N%d,C%d)", rows[$0].year, rows[$0].metrics[j],
                       rows[$0].built ? 1 : 0, rows[$0].neck, rows[$0].chute)
            }.joined(separator: ", "))
            let top = normal.filter { rows[$0].active(j) }.sorted { rows[$0].metrics[j] > rows[$1].metrics[j] }.prefix(3)
            print("TOP normal \(names[j]): " + top.map {
                String(format: "%.1f=%.6f", rows[$0].year, rows[$0].metrics[j])
            }.joined(separator: ", "))
        }
        for label in ["Neck", "Chute"] {
            let cutoffs = rows.indices.filter { label == "Neck" ? rows[$0].neck > 0 : rows[$0].chute > 0 }
            print("CUTOFF \(label) Jahre: " + cutoffs.map { String(format: "%.1f", rows[$0].year) }.joined(separator: ", "))
            for i in cutoffs where !windows.contains(i) {
                if let next = (i..<rows.count).first(where: { rows[$0].built }) {
                    print(String(format: "CUTOFF-NACHLAUF %@ %.1f: nächster Bau %.1f, Bandwechsel %.6f %% = %.3f * Normal-Median",
                                 label, rows[i].year, rows[next].year,
                                 rows[next].metrics[2] + rows[next].metrics[3],
                                 (rows[next].metrics[2] + rows[next].metrics[3]) / bandMedian))
                }
            }
        }
    }
}

private struct TransitionRow {
    let year: Double
    let couplingYear: Double?
    let built: Bool
    let uploaded: Bool
    let avulsions: Int
    let retraced: Int
    let inserted: Int
    let neck: Int
    let chute: Int
    var heightCells = 0
    var heightSum = 0.0
    var metrics = [Double](repeating: 0, count: 7)

    func active(_ metric: Int) -> Bool {
        if metric < 2 { return true }
        if metric == 7 { return built }
        return metric < 4 ? built : uploaded
    }

    var line: String {
        let coupling = couplingYear.map { String(format: "%.1f", $0) } ?? "-"
        return String(format: "%.1f | %@ | %d %d | %d %d %d %d %d | %d %.6f %.8f %.8f | %.6f %.6f | %.6f %.6f %.6f",
                      year, coupling, built ? 1 : 0, uploaded ? 1 : 0,
                      avulsions, retraced, inserted, neck, chute, heightCells,
                      metrics[0], heightSum, metrics[1], metrics[2], metrics[3],
                      metrics[4], metrics[5], metrics[6])
    }
}
