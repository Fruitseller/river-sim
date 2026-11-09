import XCTest
@testable import SimCore
@testable import SimGame

/// Messläufe zur Versuchskarte des Mutter-Natur-Prototyps (Issue #223) —
/// Karten-Ansicht, Versorgung je Siedlung, Laufzeit je Schritt. Nur mit
/// `RS_MEASURE=1`; die Tabellen stehen in `docs/nature-prototype.md`.
final class NatureScenarioDiagnosticTests: XCTestCase {
    /// ASCII-Karte: `~` Meer, `#` Fluss (area ≥ needArea), `+` Gerinne
    /// (≥ minSourceArea), `H` Haus, `f` Feld, `o` See (hf > h), sonst Höhe 0–9.
    static func asciiMap(_ t: Terrain, _ game: NatureGame) -> String {
        let n = t.cfg.n
        let cell2 = t.cfg.cellSize * t.cfg.cellSize
        var houses = Set<Int>(), fields = Set<Int>()
        for l in game.layouts { houses.formUnion(l.houses); fields.formUnion(l.fields) }
        var out = ""
        for j in stride(from: 0, to: n, by: 2) {
            for i in 0..<n {
                let k = j * n + i
                let c: Character
                if houses.contains(k) { c = "H" }
                else if fields.contains(k) { c = "f" }
                else if t.h[k] <= t.cfg.sea { c = "~" }
                else if t.hf[k] - t.h[k] > NatureGame.floodDepth { c = "o" }
                else if t.area[k] / cell2 >= NatureGame.needArea { c = "#" }
                else if t.area[k] / cell2 >= NatureGame.minSourceArea { c = "+" }
                else { c = Character(String(min(9, max(0, Int((t.h[k] - t.cfg.sea) * 12))))) }
                out.append(c)
            }
            out.append("\n")
        }
        return out
    }

    func testNatureScenarioMapDiagnostic() throws {
        try skipUnlessMeasuring()
        let t0 = Date()
        let t = Terrain(config: NatureScenario.config, seed: NatureScenario.seed,
                        relief: NatureScenario.relief(), settleYears: NatureScenario.settleYears)
        print("generate+settle s:", Date().timeIntervalSince(t0))
        let game = NatureGame()
        game.measure(t)
        let n = t.cfg.n
        print("max area", t.area.max()!, "land cells", t.h.filter { $0 > t.cfg.sea }.count)
        let fw = t.flowWeight
        print("flowWeight count", fw.count, "sum", fw.reduce(0, +), "min", fw.min() ?? -1, "max", fw.max() ?? -1,
              "rain min/max", t.rain.min()!, t.rain.max()!, "runoff empty", t.runoffWeight.isEmpty)
        for k in [40 * n + 70, 40 * n + 90, 60 * n + 100, 60 * n + 80] {
            print("cell", k % n, k / n, "h", t.h[k], "hf", t.hf[k], "recv", t.receiver[k] % Int32(n), t.receiver[k] / Int32(n), "w", fw.isEmpty ? -1 : fw[k], "area", t.area[k])
        }
        for j in stride(from: 0, to: n, by: 4) {
            var line = "j \(j):"
            for i in stride(from: 60, to: 90, by: 1) {
                line += " " + String(Int(t.area[j * n + i] / t.cfg.cellSize / t.cfg.cellSize))
            }
            line += " | basin " + String(t.endorheicBasin[j * n + 80].rawValue)
            print(line)
        }
        print(Self.asciiMap(t, game))
        for (s, l) in game.layouts.enumerated() {
            print(l.name, "supply", game.lastSupply[s])
        }
        let t1 = Date()
        for _ in 0..<50 { t.step(dtYears: 0.2); game.advance(t, years: 0.2) }
        print("50 × 0.2 J. s:", Date().timeIntervalSince(t1))
        let t2 = Date()
        for _ in 0..<60 { t.step(dtYears: 5); game.advance(t, years: 5) }
        print("60 × 5 J. s:", Date().timeIntervalSince(t2))
        print(Self.asciiMap(t, game))
        for (s, l) in game.layouts.enumerated() {
            print(l.name, game.settlements[s].status.label, "supply", game.lastSupply[s],
                  "pop", game.settlements[s].population)
        }
    }

    static func world(budget: Double = NatureGame.defaultBudget, repair: Bool = true) -> (Terrain, NatureGame) {
        let t = Terrain(config: NatureScenario.config, seed: NatureScenario.seed,
                        relief: NatureScenario.relief(), settleYears: NatureScenario.settleYears)
        let g = NatureGame(budget: budget, repairEnabled: repair)
        g.measure(t)
        return (t, g)
    }

    static func run(_ name: String, years: Int, _ t: Terrain, _ g: NatureGame) {
        for y in 1...years {
            t.step(dtYears: 1)
            g.advance(t, years: 1)
            if y % 2 == 0 || y < 12 {
                var line = "\(name) y\(y)"
                for (s, l) in g.layouts.enumerated() {
                    let st = g.settlements[s]
                    line += String(format: " | %@ %@ w%.2f fl%.2f pop%.2f res%.2f bad%d%@", l.name,
                                   st.status.label, g.lastSupply[s].water, g.lastSupply[s].floodedFields,
                                   st.population, st.reserve, st.badStreak, g.repairing[s] ? " REP" : "")
                }
                line += " edits \(g.edits.count)"
                print(line)
            }
            if g.outcome != .running { print(name, "outcome", g.outcome, "year", y); break }
        }
    }

    func testNatureExperimentsDiagnostic() throws {
        try skipUnlessMeasuring()
        for (name, hits) in [("low", NatureScenario.lowSaddleCut), ("high", NatureScenario.highSaddleCut)] {
            let (t, g) = Self.world()
            var applied = 0
            for (tool, x, z) in hits {
                let r = g.brush(tool, terrain: t, gx: x, gz: z, radiusWorld: 1, strength: 1)
                if r == .applied { applied += 1 } else { print(name, "hit", x, z, r) }
            }
            t.recomputeFlowAfterEdit()
            g.measure(t)
            print(name, "applied", applied, "budget used", g.budgetUsed)
            print(Self.asciiMap(t, g).split(separator: "\n")[18...40].joined(separator: "\n"))
            Self.run(name, years: 60, t, g)
            print(Self.asciiMap(t, g).split(separator: "\n")[18...40].joined(separator: "\n"))
        }
        for (label, budget, repair) in [("dam", NatureGame.defaultBudget, true), ("damBig", 100.0, false)] {
        let (t, g) = Self.world(budget: budget, repair: repair)
        for (tool, x, z) in NatureScenario.damBelowTalheim {
            let r = g.brush(tool, terrain: t, gx: x, gz: z, radiusWorld: 1, strength: 3)
            if r != .applied { print("dam", x, z, r) }
        }
        t.recomputeFlowAfterEdit()
        g.measure(t)
        print(label, "budget used", g.budgetUsed)
        print(Self.asciiMap(t, g).split(separator: "\n")[26...42].joined(separator: "\n"))
        Self.run(label, years: 40, t, g)
        }
    }
}
