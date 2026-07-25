import XCTest
@testable import SimCore

final class SimCoreTests: XCTestCase {

    private func makeConfig(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n
        return c
    }

    // MARK: - Determinismus

    /// Gleicher Seed → bit-identische Höhenfelder, auch nach Simulation.
    func testDeterminism() {
        let a = Terrain(config: makeConfig(), seed: 4242)
        let b = Terrain(config: makeConfig(), seed: 4242)
        XCTAssertEqual(a.h, b.h, "Generierung muss deterministisch sein")
        for _ in 0..<10 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "Simulation muss deterministisch sein")
        XCTAssertEqual(a.receiver, b.receiver)
    }

    /// Verschiedene Seeds → verschiedene Terrains.
    func testSeedsDiffer() {
        let a = Terrain(config: makeConfig(), seed: 1)
        let b = Terrain(config: makeConfig(), seed: 2)
        XCTAssertNotEqual(a.h, b.h)
    }

    // MARK: - Entwässerungs-Invariante

    /// Die Summe der Einzugsgebiete an allen Land-Auslässen muss der Landfläche
    /// entsprechen — jede Zelle trägt genau ihre eigene Fläche bei.
    func testDrainageAreaConservation() {
        let t = Terrain(config: makeConfig(), seed: 777)
        let outlet = t.totalOutletArea()
        let total = Double(t.cfg.count)
        XCTAssertEqual(outlet, total, accuracy: total * 1e-6,
                       "Summe der Senken-Einzugsgebiete muss = Gesamtzellzahl sein")
    }

    // MARK: - Beschränktes Relief / Fließgleichgewicht

    /// Über viele Zeitsprünge darf das Relief weder weglaufen (→ ∞) noch
    /// einebnen (→ 0). Ersetzt die Masse-Erhaltung des Droplet-Prototyps.
    func testReliefStaysBounded() {
        let t = Terrain(config: makeConfig(), seed: 2024)
        let start = t.landRelief()
        XCTAssertGreaterThan(start, 0.1, "Startterrain muss Relief haben")
        var reliefs: [Double] = []
        for _ in 0..<8 {
            t.step(dtYears: 10000)
            reliefs.append(t.landRelief())
        }
        for r in reliefs {
            XCTAssertGreaterThan(r, 0.05, "Landschaft ebnet unrealistisch ein: \(reliefs)")
            XCTAssertLessThan(r, 2.0, "Relief läuft weg: \(reliefs)")
        }
        // Höhen bleiben in physikalisch sinnvollen Grenzen.
        XCTAssertLessThanOrEqual(t.maxHeight(), 1.4)
        XCTAssertGreaterThanOrEqual(t.minHeight(), t.cfg.floor - 1e-9)
    }

    /// Kein NaN/Inf über lange Läufe (numerische Stabilität des Solvers).
    func testNoNaN() {
        let t = Terrain(config: makeConfig(n: 80), seed: 555)
        for _ in 0..<20 { t.step(dtYears: 5000) }
        for v in t.h { XCTAssertTrue(v.isFinite, "NaN/Inf im Höhenfeld") }
        for v in t.area { XCTAssertTrue(v.isFinite && v >= 0, "Ungültiges Einzugsgebiet") }
    }

    /// Über sehr lange Zeiträume (wie im Zeitraffer: viele gedeckelte Schritte)
    /// bleibt die Landschaft stabil und beschränkt — kein Weglaufen, kein NaN.
    func testLongRunStable() {
        let t = Terrain(config: makeConfig(n: 80), seed: 33)
        for _ in 0..<400 { t.step(dtYears: 250) } // 100k Jahre in realistischen Schritten
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(t.landRelief(), 0.1)
        XCTAssertLessThan(t.landRelief(), 1.6)
    }

    // MARK: - Konsistenz der Schichten

    /// h muss stets rock + sed entsprechen; Sediment nie negativ.
    func testLayerConsistency() {
        let t = Terrain(config: makeConfig(n: 80), seed: 9)
        for _ in 0..<5 { t.step(dtYears: 8000) }
        for k in 0..<t.cfg.count {
            XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-9,
                           "h == rock + sed verletzt bei \(k)")
            XCTAssertGreaterThanOrEqual(t.sed[k], -1e-9, "negatives Sediment bei \(k)")
        }
    }

    // MARK: - Fluss-Stabilität

    // MARK: - Sculpting

    /// Anheben erhöht das Terrain lokal; die Tektonik-Kopplung sorgt dafür, dass
    /// der Eingriff über lange Zeiträume erhalten bleibt (Prototyp-Invariante:
    /// gesculpteter Berg bleibt der höchste Punkt der Karte).
    func testSculptRaisesAndPersists() {
        let t = Terrain(config: makeConfig(), seed: 4)
        let n = t.cfg.n
        let center = Double(n / 2)
        let before = t.h[Int(center) * n + Int(center)]
        // Kräftig anheben.
        for _ in 0..<200 {
            t.sculpt(gx: center, gz: center, radiusWorld: 12, dir: 1)
        }
        let after = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(after, before + 0.2, "Anheben muss das Terrain erhöhen")
        t.computeFlow()
        // Über lange Zeit erodieren lassen — Kopplung soll den Berg halten.
        for _ in 0..<3 { t.step(dtYears: 10000) }
        let peak = t.maxHeight()
        let peakArea = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(peakArea, peak * 0.6,
                             "gesculptete Region muss nach Erosion prominent bleiben")
    }

    /// Zwischen aufeinanderfolgenden Schritten sollen die meisten Flusszellen
    /// ihren Lauf behalten (analog zur 71-%-Messung im Prototyp).
    func testRiverStability() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<3 { t.step(dtYears: 5000) } // einschwingen
        let before = t.snapshotReceivers()
        t.step(dtYears: 100)
        let agreement = t.receiverAgreement(with: before)
        XCTAssertGreaterThan(agreement, 0.6,
                             "Entwässerung springt zu stark um: \(agreement)")
    }

    // MARK: - Mäander-Migration (M1: entkoppelter Kernel)

    /// Ein leicht gewellter Startlauf als Saat (schnurgerade → keine Krümmung →
    /// keine Migration). Abfluss konstant hoch, damit Bewegung sichtbar wird.
    private func seededChannel() -> RiverChannel {
        var nodes: [MeanderNode] = []
        var dis: [Double] = []
        var x = 5.0
        while x <= 90 {
            nodes.append(MeanderNode(x: x, z: 48 + 1.5 * sin(x * 0.4)))
            dis.append(220)
            x += 1.5
        }
        return RiverChannel(nodes: nodes, discharge: dis)
    }

    private func migratedState(steps: Int, dt: Double = 500) -> (MeanderState, SimConfig) {
        let cfg = makeConfig()
        let s = MeanderState()
        s.channels = [seededChannel()]
        for _ in 0..<steps { s.migrate(dt: dt, config: cfg) }
        return (s, cfg)
    }

    func testMeanderDeterminism() {
        let (a, _) = migratedState(steps: 60)
        let (b, _) = migratedState(steps: 60)
        XCTAssertEqual(a.channels.count, b.channels.count)
        XCTAssertEqual(a.channels[0].nodes, b.channels[0].nodes,
                       "Mäander-Migration muss deterministisch sein")
        XCTAssertEqual(a.oxbows.count, b.oxbows.count)
    }

    /// Sinuosität wächst gegenüber dem geraden Start und läuft nicht weg
    /// (Cutoffs deckeln sie) — "wächst dann sättigt".
    func testMeanderSinuosityGrowsThenSaturates() {
        let cfg = makeConfig()
        let s = MeanderState()
        s.channels = [seededChannel()]
        let s0 = s.channels[0].sinuosity
        for _ in 0..<40 { s.migrate(dt: 500, config: cfg) }
        let s40 = s.channels[0].sinuosity
        for _ in 0..<200 { s.migrate(dt: 500, config: cfg) }
        let s240 = s.channels[0].sinuosity
        XCTAssertGreaterThan(s40, s0 + 0.01, "Sinuosität muss zunächst wachsen: \(s0)→\(s40)")
        XCTAssertGreaterThan(s240, 1.0, "Lauf bleibt gewunden")
        XCTAssertLessThan(s240, 6.0, "Sinuosität läuft weg (keine Sättigung): \(s240)")
    }

    /// Nach Migration+Cutoffs dürfen sich keine nicht-benachbarten Knoten näher
    /// als der Hals kommen (keine Selbst-Durchdringung).
    func testMeanderNoSelfIntersection() {
        let (s, cfg) = migratedState(steps: 300)
        let neck = cfg.meanderNeckDist
        let minSep = max(4, Int((neck / cfg.meanderNodeSpacing) * 3) + 2)
        for ch in s.channels {
            let nodes = ch.nodes
            for i in 0..<nodes.count {
                var j = i + minSep
                while j < nodes.count {
                    let d = (nodes[i].x - nodes[j].x) * (nodes[i].x - nodes[j].x)
                          + (nodes[i].z - nodes[j].z) * (nodes[i].z - nodes[j].z)
                    XCTAssertGreaterThanOrEqual(d.squareRoot(), neck * 0.999,
                        "Selbst-Durchdringung bei Knoten \(i),\(j)")
                    j += 1
                }
            }
        }
    }

    /// Nach dem Resample liegen die Knotenabstände im Zielband.
    func testMeanderResampleInvariant() {
        let (s, cfg) = migratedState(steps: 120)
        let sp = cfg.meanderNodeSpacing
        for ch in s.channels where ch.nodes.count >= 3 {
            for i in 1..<ch.nodes.count {
                let d = dist(ch.nodes[i - 1], ch.nodes[i])
                // Untergrenze locker: an frischen Cutoff-Ecken ist die Sehne < Bogen
                // (die Glättung rundet die Ecke erst in Folgeschritten aus).
                XCTAssertGreaterThan(d, sp * 0.4, "Knoten zu dicht: \(d)")
                XCTAssertLessThan(d, sp * 2.0, "Knoten zu weit: \(d)")
            }
            XCTAssertEqual(ch.nodes.count, ch.discharge.count, "Abfluss-Array inkonsistent")
        }
    }

    /// Trace aus der echten D8-Entwässerung liefert plausible Läufe.
    func testMeanderTraceFromDrainage() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<4 { t.step(dtYears: 5000) }
        let channels = MeanderState.traceChannels(config: t.cfg, h: t.h, hf: t.hf,
                                                   area: t.area, receiver: t.receiver)
        XCTAssertFalse(channels.isEmpty, "Kein Hauptfluss aus der Entwässerung getract")
        for ch in channels {
            XCTAssertGreaterThanOrEqual(ch.nodes.count, 2)
            XCTAssertEqual(ch.nodes.count, ch.discharge.count)
            XCTAssertTrue(ch.discharge.allSatisfy { $0 > 0 }, "Abfluss muss positiv sein")
        }
    }
}
