import XCTest
@testable import SimCore
@testable import SimGame

/// Wächter des Mutter-Natur-Prototyps (Issue #223): Jahresregeln der
/// Siedlungen, Unabhängigkeit von der Schritt-Aufteilung, reproduzierbare
/// Versuchskarte und die dokumentierten Versuche A–D
/// (`docs/nature-prototype.md`). Alles headless; ob das Spiel SPASS macht,
/// prüft kein Test.
final class NatureGameTests: XCTestCase {
    // MARK: Jahresregeln (ohne Terrain)

    private func run(_ supplies: [Double]) -> SettlementState {
        var s = SettlementState()
        for (y, w) in supplies.enumerated() { s.closeYear(y + 1, supply: YearSupply(water: w)) }
        return s
    }

    func testOneTotalCropFailureDrivesNobodyAway() {
        let s = run([0])
        XCTAssertEqual(s.population, 1)
        XCTAssertEqual(s.status, .undersupplied)
        XCTAssertEqual(s.problem, .drought)
        XCTAssertGreaterThan(s.reserve, 0)
        // Danach erholt sie sich ohne Verlust.
        let after = run([0, 1, 1, 1])
        XCTAssertEqual(after.population, 1)
        XCTAssertEqual(after.status, .stable)
        XCTAssertEqual(after.badStreak, 0)
    }

    func testAboutFiveYearsOfFailureAbandonTheSettlement() {
        var s = SettlementState()
        var abandonedIn: Int?
        for y in 1...10 {
            s.closeYear(y, supply: YearSupply(water: 0))
            if y == 2 { XCTAssertEqual(s.status, .emigrating, "zweites Ausfalljahr: erste Abwanderung") }
            if s.isAbandoned { abandonedIn = y; break }
        }
        XCTAssertEqual(abandonedIn, 5, "Richtwert ~5 Ausfalljahre bis zur Aufgabe")
        // Halbe Ernte hält deutlich länger durch.
        var half = SettlementState(), halfYears = 0
        while !half.isAbandoned && halfYears < 50 {
            halfYears += 1
            half.closeYear(halfYears, supply: YearSupply(water: 0.5))
        }
        XCTAssertGreaterThan(halfYears, 8)
    }

    func testGoodYearsRebuildReservesAndPeople() {
        let hit = run([0, 0, 0])
        XCTAssertLessThan(hit.population, 0.6)
        var s = hit
        for y in 4...30 { s.closeYear(y, supply: YearSupply(water: 1)) }
        XCTAssertEqual(s.status, .stable)
        XCTAssertEqual(s.reserve, SettlementRules.maxReserve, accuracy: 1e-9)
        XCTAssertGreaterThan(s.population, hit.population + 0.3, "Erholung, kein Einbahn-Schadensbalken")
        XCTAssertLessThanOrEqual(s.history.count, SettlementRules.historyLength)
    }

    func testFloodedHousesCostReservesAndNameTheReason() {
        var s = SettlementState()
        s.closeYear(1, supply: YearSupply(water: 0.2, floodedFields: 0.8, floodedHouses: 0.5))
        XCTAssertEqual(s.problem, .flood)
        XCTAssertLessThan(s.reserve, SettlementRules.startReserve - 0.7)
    }

    /// Dieselbe Versorgungsgeschichte, in verschiedene Schritte zerlegt
    /// (Bruchteile, ganze Jahre, mehrjährige Sprünge), ergibt denselben
    /// Siedlungsverlauf: Jahre werden über verstrichene Sim-Zeit abgeschlossen,
    /// nicht je Aufruf.
    func testYearEvaluationIgnoresStepSplitting() {
        // Je Jahr die Versorgung (gleich für alle Siedlungen).
        let history: [Double] = [1, 1, 1, 0.2, 0.2, 0.2, 0.2, 0.2, 1, 1, 1, 1]
        func play(_ steps: [Double]) -> [SettlementState] {
            let g = NatureGame()
            var t = 0.0
            for dt in steps {
                let year = min(history.count - 1, Int((t + 1e-9).rounded(.down)))
                g.setSupplyForTests(g.layouts.map { _ in YearSupply(water: history[year]) })
                g.book(years: dt, terrain: nil)
                t += dt
            }
            XCTAssertEqual(g.yearsClosed, history.count)
            return g.settlements
        }
        let reference = play([Double](repeating: 1, count: 12))
        let splits: [[Double]] = [
            [Double](repeating: 0.2, count: 60),
            [Double](repeating: 0.25, count: 48),
            [Double](repeating: 1.0 / 60, count: 720), // 5 J./s bei 60 Bildern/s, ~12 s
            [3, 5, 4],                                 // mehrjährige Schritte über gleich versorgte Jahre
            [0.5, 2.5, 0.7, 0.3, 4, 0.4, 0.6, 3],
        ]
        for steps in splits {
            let got = play(steps)
            for (a, b) in zip(got, reference) {
                XCTAssertEqual(a.status, b.status, "\(steps.count) Schritte")
                XCTAssertEqual(a.badStreak, b.badStreak)
                XCTAssertEqual(a.history.map(\.problem), b.history.map(\.problem))
                XCTAssertEqual(a.population, b.population, accuracy: 1e-9)
                XCTAssertEqual(a.reserve, b.reserve, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(reference[0].status, .stable, "nach vier guten Jahren wieder stabil")
        XCTAssertLessThan(reference[0].population, 1)
    }

    /// Ein Jahr mit halbem Ausfall wird anteilig gemittelt, nicht vom letzten
    /// Schritt allein bestimmt.
    func testYearSupplyIsTimeWeighted() {
        let g = NatureGame()
        g.setSupplyForTests(g.layouts.map { _ in YearSupply(water: 1) })
        g.book(years: 0.5, terrain: nil)
        g.setSupplyForTests(g.layouts.map { _ in YearSupply(water: 0.5) })
        g.book(years: 0.5, terrain: nil)
        let h = g.settlements[0].history.last!
        XCTAssertEqual(h.harvest, 0.75 * SettlementRules.yieldPerCapita, accuracy: 1e-12)
    }

    // MARK: Versuchskarte

    static func world(budget: Double = NatureGame.defaultBudget,
                      repair: Bool = true) -> (Terrain, NatureGame) {
        let t = Terrain(config: NatureScenario.config, seed: NatureScenario.seed,
                        relief: NatureScenario.relief(), settleYears: NatureScenario.settleYears)
        let g = NatureGame(budget: budget, repairEnabled: repair)
        g.measure(t)
        return (t, g)
    }

    static func apply(_ hits: [(BrushTool, Double, Double)], strength: Double = 1,
                      _ t: Terrain, _ g: NatureGame) {
        for (tool, x, z) in hits {
            _ = g.brush(tool, terrain: t, gx: x, gz: z, radiusWorld: 1, strength: strength)
        }
        t.recomputeFlowAfterEdit()
        g.measure(t)
    }

    /// Läuft Jahr für Jahr; gibt das Jahr der Aufgabe der Zielsiedlung zurück.
    @discardableResult
    static func play(_ t: Terrain, _ g: NatureGame, years: Int, dt: Double = 1) -> Int? {
        var y = 0.0
        while y < Double(years) - 1e-9 {
            t.step(dtYears: dt)
            g.advance(t, years: dt)
            y += dt
            if g.outcome == .natureWins { return g.yearsClosed }
        }
        return nil
    }

    var talheim: Int { NatureScenario.settlements().firstIndex { $0.name == "Talheim" }! }
    var westfurt: Int { NatureScenario.settlements().firstIndex { $0.name == "Westfurt" }! }

    func testScenarioRestartsBitIdentical() {
        let (a, _) = Self.world()
        let (b, _) = Self.world()
        XCTAssertEqual(a.fingerprint(), b.fingerprint())
        XCTAssertEqual(a.cfg.cellSize, SimConfig().cellSize, accuracy: 1e-12,
                       "n und world zusammen: Produktions-Zellgröße")
    }

    func testAllSettlementsStartSupplied() {
        let (_, g) = Self.world()
        for (s, l) in g.layouts.enumerated() {
            XCTAssertGreaterThan(g.lastSupply[s].water * SettlementRules.yieldPerCapita, 1,
                                 "\(l.name) startet versorgt")
            XCTAssertEqual(g.lastSupply[s].floodedHouses, 0, l.name)
        }
    }

    /// Ohne Eingriff hält die Zielsiedlung den ganzen Versuchszeitraum.
    func testWithoutInterventionTheTargetHoldsTheTrial() {
        let (t, g) = Self.world()
        XCTAssertNil(Self.play(t, g, years: NatureGame.trialYears, dt: 2))
        XCTAssertEqual(g.outcome, .settlementHeld)
        for (s, l) in g.layouts.enumerated() {
            XCTAssertFalse(g.settlements[s].isAbandoned, l.name)
            XCTAssertGreaterThan(g.settlements[s].population, 0.9, l.name)
        }
    }

    /// Versuch A: Durchstich am niedrigen Sattel lenkt den Fluss nach Westen.
    /// Talheim trocknet aus — und die Talheimer schütten den Durchstich wieder
    /// zu (Gegenreaktion), worauf der Fluss zurückkehrt.
    func testLowSaddleCutDivertsTheRiverAndPeopleRepairIt() {
        let (t, g) = Self.world()
        let westBefore = g.lastSupply[westfurt].water
        Self.apply(NatureScenario.lowSaddleCut, t, g)
        XCTAssertLessThan(g.lastSupply[talheim].water, 0.4, "Umleitung trocknet Talheim aus")
        XCTAssertGreaterThanOrEqual(g.lastSupply[westfurt].water, westBefore - 0.01)
        XCTAssertLessThan(g.budgetLeft, g.budget)
        var sawRepair = false
        for _ in 0..<6 {
            Self.play(t, g, years: 1)
            sawRepair = sawRepair || g.repairing[talheim]
        }
        XCTAssertTrue(sawRepair, "Talheim baut den Durchstich zurück")
        XCTAssertGreaterThan(g.lastSupply[talheim].water, 0.8, "Fluss ist zurück")
        XCTAssertFalse(g.settlements[talheim].isAbandoned)
    }

    /// Versuch B: der hohe Sattel liegt außerhalb der Reichweite der
    /// Ausbesserer — Talheim verfällt über Jahre, nicht sofort.
    func testHighSaddleCutOutOfReachAbandonsTalheimOverYears() {
        let (t, g) = Self.world()
        Self.apply(NatureScenario.highSaddleCut, t, g)
        XCTAssertLessThan(g.lastSupply[talheim].water, 0.6)
        let end = Self.play(t, g, years: 40)
        XCTAssertNotNil(end)
        XCTAssertGreaterThanOrEqual(end ?? 0, 6, "keine Aufgabe nach einem einzelnen Ausfall")
        XCTAssertLessThanOrEqual(end ?? 99, 25)
        XCTAssertFalse(g.settlements[westfurt].isAbandoned, "Westfurt bekommt mehr Wasser, nicht weniger")
        XCTAssertFalse(g.repairing.contains(true), "niemand repariert außerhalb der Reichweite")
    }

    /// Ein wirkungsloser Eingriff (Graben auf der Ost-Abdachung, fern vom
    /// Fluss) erzeugt keinen künstlichen Schaden.
    func testIneffectiveEditCausesNoDamage() {
        let (t, g) = Self.world()
        // Vergleichsbasis auf frisch nachgezogener Entwässerung — dieselbe,
        // die nach dem Eingriff gilt (nach einem Schritt stammt `area` vom
        // Schrittanfang).
        t.recomputeFlowAfterEdit()
        g.measure(t)
        let before = g.lastSupply.map(\.water)
        let hits: [(BrushTool, Double, Double)] = (0..<6).map { (.pickaxe, 112 - Double($0) * 2, 70) }
        Self.apply(hits, t, g)
        XCTAssertGreaterThan(g.budgetUsed, 0)
        for (s, w) in before.enumerated() {
            XCTAssertEqual(g.lastSupply[s].water, w, accuracy: 0.02)
        }
        Self.play(t, g, years: 20)
        for s in g.layouts.indices {
            XCTAssertEqual(g.settlements[s].status, .stable)
            XCTAssertEqual(g.settlements[s].population, 1)
        }
    }

    /// Versuch C: Damm unterhalb Talheims staut den Fluss in die Felder.
    /// Ohne Gegenreaktion gibt Talheim auf; mit ihr graben die Talheimer den
    /// Damm ab. Überflutung = Füllstand der Priority-Flood (vereinfacht).
    func testDamFloodsTalheimFields() {
        let (t, g) = Self.world(budget: 100, repair: false)
        Self.apply(NatureScenario.damBelowTalheim, strength: 3, t, g)
        XCTAssertGreaterThan(g.lastSupply[talheim].floodedFields, 0.5)
        Self.play(t, g, years: 1)
        XCTAssertEqual(g.settlements[talheim].problem, .flood)
        XCTAssertNotNil(Self.play(t, g, years: 20))

        let (t2, g2) = Self.world(budget: 100, repair: true)
        Self.apply(NatureScenario.damBelowTalheim, strength: 3, t2, g2)
        XCTAssertNil(Self.play(t2, g2, years: 20), "die Talheimer graben den Damm ab")
    }

    // MARK: Eingriffsregeln

    func testBrushRulesProtectSettlementsAndSpendTheBudget() {
        let (t, g) = Self.world(budget: 0.3)
        let l = g.layouts[talheim]
        let field = l.fields[0]
        XCTAssertEqual(g.brush(.pickaxe, terrain: t, gx: Double(field % t.cfg.n),
                               gz: Double(field / t.cfg.n), radiusWorld: 1, strength: 1),
                       .tooCloseToSettlement)
        XCTAssertEqual(g.brush(.smooth, terrain: t, gx: 110, gz: 70, radiusWorld: 1, strength: 1),
                       .toolNotAllowed)
        XCTAssertEqual(g.budgetUsed, 0)
        let h0 = t.h
        var results: [NatureGame.BrushResult] = []
        for _ in 0..<20 {
            results.append(g.brush(.pickaxe, terrain: t, gx: 110, gz: 70, radiusWorld: 5, strength: 1))
        }
        XCTAssertTrue(results.contains(.budgetExhausted))
        XCTAssertEqual(g.budgetLeft, 0)
        // Radius gedeckelt: nichts außerhalb von maxBrushCells verändert.
        for k in 0..<t.cfg.count where t.h[k] != h0[k] {
            let di = Double(k % t.cfg.n) - 110, dj = Double(k / t.cfg.n) - 70
            XCTAssertLessThanOrEqual((di * di + dj * dj).squareRoot(), NatureGame.maxBrushCells + 0.5)
        }
        // Häuser und Felder unverändert.
        for k in l.houses + l.fields { XCTAssertEqual(t.h[k], h0[k]) }
    }

    /// Gleiche Strichdauer bewegt bei 30 und 60 FPS gleich viel Erde: Main.gd
    /// übergibt `Regler × delta × 60`, der Deckel darf das nicht abschneiden.
    func testStrokeEffectIsFramerateIndependent() {
        func earthMoved(fps: Int) -> Double {
            let (t, g) = Self.world(budget: 1e9)
            let slider = 3.0 // Reglermaximum
            for _ in 0..<fps {
                let frameStrength = slider * min(1.0 / Double(fps), 0.05) * 60
                XCTAssertEqual(g.brush(.raise, terrain: t, gx: 110, gz: 70,
                                       radiusWorld: 2 * t.cfg.cellSize,
                                       strength: frameStrength), .applied)
            }
            return g.budgetUsed
        }
        let at30 = earthMoved(fps: 30), at60 = earthMoved(fps: 60)
        XCTAssertGreaterThan(at60, 0)
        XCTAssertEqual(at30, at60, accuracy: at60 * 1e-6)
    }

    func testViewMirrorsTheGame() {
        let (t, g) = Self.world()
        Self.apply(NatureScenario.lowSaddleCut, t, g)
        let v = g.view()
        XCTAssertEqual(v.settlements.count, 3)
        XCTAssertEqual(v.settlements.filter(\.isTarget).map(\.name), ["Talheim"])
        XCTAssertFalse(v.editedCells.isEmpty)
        XCTAssertEqual(v.settlements[talheim].fieldWater.count, v.settlements[talheim].fields.count)
        XCTAssertEqual(v.outcome, .running)
    }
}
