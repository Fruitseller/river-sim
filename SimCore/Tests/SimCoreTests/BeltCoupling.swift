import XCTest
@testable import SimCore

/// Wächter der Kopplung Mäandergürtel ↔ D8-Entwässerung (Issue #187,
/// `Terrain.coupleBeltToDrainage`). Messreihe: docs/zielbild-measurements.md
/// § Gürtel und Entwässerung: Avulsion (#187).
final class BeltCouplingTests: XCTestCase {
    /// Kunstwelt: ein V-Tal entlang Zeile 30, nach Osten fallend. Jede Zelle
    /// entwässert ins Tal, das Tal nach Osten an den Rand — EIN Fluss.
    private func valleyWorld(_ configure: (inout SimConfig) -> Void = { _ in }) -> Terrain {
        var c = renderConfig(n: 64)
        c.meanderBeltMinCells = 100
        configure(&c)
        let t = Terrain(allocating: c, seed: 1)
        var s = t.state
        let n = c.n
        for j in 0..<n {
            for i in 0..<n {
                s.h[j * n + i] = 0.6 - 0.002 * Double(i) + 0.003 * abs(Double(j) - 30)
            }
        }
        s.hf = s.h
        s.waterLevel = s.h
        t.restore(s)
        t.computeFlow()
        return t
    }

    /// Eine Linie, die dem Tal bis x = 20 folgt, dann bis x = 50 auf Zeile 40
    /// ausweicht (zehn Zellen neben dem Fluss, länger als
    /// `meanderBeltAbandonMinWidths`) und danach zurückkehrt — mit einem
    /// geerbten, viel zu großen Abfluss.
    private func detourLine(_ t: Terrain) -> RiverChannel {
        var pts: [MeanderNode] = []
        for x in 4...20 { pts.append(MeanderNode(x: Double(x), z: 30)) }
        for z in 31...40 { pts.append(MeanderNode(x: 20.5, z: Double(z))) }
        for x in 21...50 { pts.append(MeanderNode(x: Double(x), z: 40)) }
        for z in stride(from: 39, through: 31, by: -1) { pts.append(MeanderNode(x: 50.5, z: Double(z))) }
        for x in 51...60 { pts.append(MeanderNode(x: Double(x), z: 30)) }
        return t.meander.resampled(RiverChannel(nodes: pts, discharge: Array(repeating: 50_000, count: pts.count)),
                                   config: t.cfg)
    }

    /// Avulsion: das abgekoppelte Stück wird durch den D8-Weg ersetzt, das
    /// verlassene Gerinne wird Altarm, und der Abfluss kommt aus dem D8-Netz,
    /// nicht aus dem geerbten Wert. Der gekoppelte Oberlauf bleibt, wo er war.
    func testDetachedStretchAvulsesIntoTheDrainage() {
        let t = valleyWorld { $0.meanderBeltAvulsionYears = 0 }
        let line = detourLine(t)
        t.meander.channels = [line]
        t.coupleBeltForTests(dt: 100)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        XCTAssertEqual(t.meander.avulsions, 1, "das Stück auf Zeile 40 muss springen")
        XCTAssertEqual(t.meander.oxbows.count, 1, "das verlassene Gerinne wird Altarm")
        XCTAssertTrue(t.meander.oxbows.first?.contains { $0.z > 39 } ?? false, "Altarm = altes Stück auf Zeile 40")
        guard let main = t.meander.channels.max(by: { ($0.discharge.last ?? 0) < ($1.discharge.last ?? 0) }) else {
            return XCTFail("kein Lauf")
        }
        // Im Tal heißt: innerhalb der Kopplungs-Reichweite (halbe Breite plus
        // Spielraum) — die Rampe am Absprung liegt darin und bleibt.
        let off = main.nodes.filter { $0.x > 6 && $0.x < 60 }.map { abs($0.z - 30) }.max() ?? .infinity
        let reach = 0.5 * MeanderState.beltWidthCells(discharge: main.discharge.max()!, config: t.cfg)
            + t.cfg.meanderBeltCouplingSlackCells
        XCTAssertLessThanOrEqual(off, reach, "Lauf liegt nicht im Tal (größter Abstand \(off) Zellen)")
        // Kein Erben: der Abfluss ist das Einzugsgebiet unter dem Lauf.
        let maxArea = t.area.max()! / cellArea
        XCTAssertLessThanOrEqual(main.discharge.max()!, maxArea * 1.0001, "Abfluss geerbt statt aus D8")
        // Der gekoppelte Oberlauf bleibt an seiner Stelle (bis auf das
        // Neu-Abtasten an der Ecke vor dem Absprung).
        let upper = main.nodes.filter { $0.x > 5 && $0.x < 17 }
        XCTAssertFalse(upper.isEmpty)
        XCTAssertTrue(upper.allSatisfy { abs($0.z - 30) < 1e-6 }, "gekoppelter Oberlauf verschoben: \(upper.filter { abs($0.z - 30) >= 1e-6 })")
    }

    /// Avulsion ist ein Ereignis mit Rate 1/τ (`meanderBeltAvulsionYears`):
    /// eine Abkopplung, die nur einen kurzen Schritt besteht, springt bei sehr
    /// großem τ nicht — die Linie behält ihren Umweg, ihr Abfluss kommt
    /// trotzdem aus D8 und nicht aus dem geerbten Wert.
    func testAvulsionIsARateNotATrigger() {
        let t = valleyWorld { $0.meanderBeltAvulsionYears = 1e12 }
        t.meander.channels = [detourLine(t)]
        t.coupleBeltForTests(dt: 100)
        XCTAssertEqual(t.meander.avulsions, 0)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        guard let main = t.meander.channels.max(by: { $0.nodes.count < $1.nodes.count }) else { return XCTFail() }
        XCTAssertTrue(main.nodes.contains { $0.z > 39 }, "Umweg ohne Avulsion verschwunden")
        XCTAssertLessThanOrEqual(main.discharge.max()!, t.area.max()! / cellArea * 1.0001, "Abfluss geerbt")
    }

    /// Eine Linie ganz ohne D8-Wasser darunter verschwindet; der Fluss bekommt
    /// seine Linie aus dem D8-Netz (auch nach einem Pinselstrich, der die alte
    /// Linie löscht, Review #187).
    func testRiverWithoutLineIsRetraced() {
        let t = valleyWorld()
        t.meander.channels = [RiverChannel(nodes: (4...60).map { MeanderNode(x: Double($0), z: 50) },
                                           discharge: Array(repeating: 50_000, count: 57))]
        t.coupleBeltForTests(dt: 100)
        // (Am Ostrand läuft ein echter D8-Lauf den Gitterrand entlang zum Tal.)
        let stray = t.meander.channels.filter { $0.nodes.contains { $0.z > 45 && $0.x > 10 && $0.x < 55 } }
        XCTAssertTrue(stray.isEmpty, "Linie ohne Fluss überlebt: \(stray.map { "\($0.nodes.first!)…\($0.nodes.last!) Q \($0.discharge.last!)" })")
        XCTAssertTrue(t.meander.channels.contains { ch in
            ch.nodes.count > 20 && ch.nodes.allSatisfy { abs($0.z - 30) < 1.0 } }, "Talfluss ohne Linie")
    }

    /// Gürtel mit wandernden Läufen auf kleinem Gitter (`meanderBeltMinCells`
    /// = 100, wie `WorldSnapshotTests`): `testDeterminism` (n = 96) hat keinen
    /// wandernden Lauf und bewacht den Gürtel nicht (Review #187).
    private func beltConfig() -> SimConfig {
        var c = renderConfig(n: 128)
        c.meanderBeltMinCells = 100
        return c
    }

    func testBeltIsDeterministic() {
        let a = Terrain(config: beltConfig(), seed: 4242), b = Terrain(config: beltConfig(), seed: 4242)
        for _ in 0..<6 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertGreaterThan(a.meander.channels.filter { MeanderState.migrates($0, a.cfg) }.count, 0,
                             "Testaufbau: kein wandernder Lauf")
        XCTAssertGreaterThan(a.barAge.filter { $0 >= 0 }.count, 0, "Testaufbau: keine Bank")
        XCTAssertEqual(a.fingerprint(), b.fingerprint(), "Gürtel nicht deterministisch")
    }

    /// Alter je Teilschritt (Review #187): nach EINEM 1000-Jahr-Schritt tragen
    /// die neuen Bänke ihr Alter am Schrittende (0 … 1000), nicht alle 0 — und
    /// die Verteilung gleicht der aus zehn 100-Jahr-Schritten. Vorher lagen
    /// gemessen alle 9971 neuen Bankzellen bei exakt 0.
    func testBarAgesFollowTheSubsteps() {
        func youngAges(_ dt: Double) -> [Double] {
            let t = Terrain(config: beltConfig(), seed: 1337)
            for _ in 0..<4 { t.step(dtYears: 1000) }
            for _ in 0..<Int(1000 / dt) { t.step(dtYears: dt) }
            return t.barAge.filter { $0 >= 0 && $0 < 1000 }
        }
        let big = youngAges(1000), small = youngAges(100)
        XCTAssertGreaterThan(big.count, 50, "Testaufbau: kaum junge Bänke")
        let zeroShare = Double(big.filter { $0 == 0 }.count) / Double(big.count)
        let meanBig = big.reduce(0, +) / Double(big.count)
        let meanSmall = small.reduce(0, +) / Double(max(1, small.count))
        print(String(format: "[BELT-ALTER] junge Bänke dt 1000: %d (Alter 0: %.0f%%, Mittel %.0f J.) | dt 100: %d (Mittel %.0f J.)",
                     big.count, 100 * zeroShare, meanBig, small.count, meanSmall))
        XCTAssertLessThan(zeroShare, 0.5, "Bänke eines großen Schritts tragen alle Alter 0")
        XCTAssertGreaterThan(meanBig, 0.5 * meanSmall, "Altersverteilung hängt an der Schrittweite")
        XCTAssertLessThan(meanBig, 2.0 * meanSmall, "Altersverteilung hängt an der Schrittweite")
    }
}

// Kopplung Mäandergürtel ↔ D8-Entwässerung (Issue #187). Messläufe hinter
// RS_MEASURE; Befunde: docs/zielbild-measurements.md § Gürtel und
// Entwässerung: Avulsion (#187).
final class BeltCouplingDiagnostics: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// `TerrainAging.testAgingTrajectoryOver100k` (n = 160, Großform vor #174)
    /// mit Varianten (`RS_VARIANT`, Schlüssel wie `MeanderBeltCalibration`,
    /// `RS_SEED`): robustes Relief in Jahr 0 / 50.000 / 100.000 und jeder neue
    /// Höchststand des Gipfels mit Ort (so fand sich der Schutthügel am Ende
    /// gesperrter Gürtelbetten, docs/zielbild-measurements.md § Avulsion).
    func testAgingTrajectoryVariantsDiagnostic() throws {
        try skipUnlessMeasuring()
        let c = MeanderBeltCalibration.variantConfig()
        // Nur die Varianten-Schlüssel übernehmen, Basis wie der Wächter.
        var base = SimConfig(); base.n = 160; base.world = calibrationWorld
        base.rangeLandform = calibrationRangeLandform
        base.meanderBeltCoupling = c.meanderBeltCoupling
        base.meanderBeltCouplingSlackCells = c.meanderBeltCouplingSlackCells
        base.meanderBeltRate = c.meanderBeltRate
        base.meanderBeltKernelWidths = c.meanderBeltKernelWidths
        base.meanderBeltMinCells = c.meanderBeltMinCells
        base.meanderBeltAvulsionYears = c.meanderBeltAvulsionYears
        base.meanderBeltAvulsionDepths = c.meanderBeltAvulsionDepths
        base.meanderBeltAbandonMinWidths = c.meanderBeltAbandonMinWidths
        base.hydraulicPerYear = c.hydraulicPerYear
        let t = Terrain(config: base, seed: UInt32(env["RS_SEED"] ?? "1337")!)
        let r0 = t.landReliefRobust()
        var r50 = 0.0
        let m0 = t.maxHeight()
        var peak = m0
        while t.years < 100_000 {
            let before = t.h
            t.step(dtYears: 500)
            if t.years == 50_000 { r50 = t.landReliefRobust() }
            let m = t.maxHeight()
            if m > peak {
                peak = m
                let k = t.h.indices.max { t.h[$0] < t.h[$1] }!, n = t.cfg.n
                print(String(format: "  PEAK J%.0f %.4f @(%d,%d) vorher %.4f, Bank %.0f, Kanal %d, Gürtel %d, Linie in 3 Zellen %d",
                             t.years, m, k % n, k / n, before[k], t.barAge[k], t.isChannel[k] ? 1 : 0, t.beltBedLockedForTests(k) ? 1 : 0,
                             t.meander.channels.contains { $0.nodes.contains { abs($0.x - Double(k % n)) < 3 && abs($0.z - Double(k / n)) < 3 } } ? 1 : 0))
            }
        }
        print(String(format: "AGING s\(env["RS_SEED"] ?? "1337") %@ robust %.4f → %.4f (50k) → %.4f (100k), Verhältnis %.3f, Läufe %d wandernd %d",
                     env["RS_VARIANT"] ?? "Standard", r0, r50, t.landReliefRobust(), t.landReliefRobust() / r50,
                     t.meander.channels.count, t.meander.channels.filter { MeanderState.migrates($0, t.cfg) }.count))
    }

    /// Verlauf je Schritt: Zahl der Läufe, Knoten, wandernde Läufe, Ereignisse
    /// der Kopplung. RS_SEED, RS_YEARS (Standard 20.000), RS_DT (1000),
    /// RS_EVERY (Druck-Abstand, 1000), RS_VARIANT; RS_SEGLOG=<Jahr> druckt ab
    /// diesem Jahr den Aufbau der Läufe wandernder Größe (`beltCouplingLog`).
    func testBeltCouplingHistoryDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(env["RS_SEED"] ?? "1337")!
        let years = Double(env["RS_YEARS"] ?? "20000")!
        let dt = Double(env["RS_DT"] ?? "1000")!
        let every = Double(env["RS_EVERY"] ?? "1000")!
        let t = Terrain(config: MeanderBeltCalibration.variantConfig(), seed: seed,
                        settleYears: SimConfig.productionSettleYears)
        func line() -> String {
            let chs = t.meander.channels
            let mobile = chs.filter { MeanderState.migrates($0, t.cfg) }
            let big = chs.filter { ($0.discharge.last ?? 0) >= t.cfg.renderMinCells }
            return String(format: "HIST s%d J%.0f Läufe %d (≥render %d, wandernd %d, Knoten wandernd %d) Knoten %d | Avulsionen %d neu getrasst %d | wandernd übernommen %d ersetzt %d %@ | Cutoffs %d/%d sinu %@",
                          seed, t.years, chs.count, big.count, mobile.count, mobile.reduce(0) { $0 + $1.nodes.count },
                          chs.reduce(0) { $0 + $1.nodes.count }, t.meander.avulsions, t.meander.retraced,
                          t.meander.coupledKept, t.meander.coupledInserted, "\(t.meander.insertedByPlace)",
                          t.meander.neckCutoffs, t.meander.chuteCutoffs,
                          mobile.filter { $0.nodes.count >= 40 }.map { String(format: "%d:%.2f", $0.nodes.count, $0.sinuosity) }.joined(separator: " "))
        }
        print(line())
        if let from = env["RS_SEGLOG"].flatMap(Double.init) { t.beltCouplingLog = { if t.years >= from { print($0) } } }
        var next = every
        while t.years < years - 1e-6 {
            t.step(dtYears: min(dt, years - t.years))
            if t.years >= next - 1e-6 { print(line()); next += every }
        }
    }
}
