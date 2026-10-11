import XCTest
@testable import SimCore

/// Wächter des Mäandergürtel-Kerns (Issue #174, Paket B) ohne Gelände: drei
/// gerade Läufe mit kleinem Rauschen auf einer Ebene. Prüft die Mechanik, die
/// das Gelände nicht verdecken darf — Wellenlängen-Wahl, Schrittweiten-
/// Unabhängigkeit, Beschränktheit. Kalibrier-Werkzeuge: `MeanderBeltCalibration`.
final class MeanderBeltTests: XCTestCase {
    private let q = 20_000.0

    private func straightRuns(_ seed: UInt32 = 7) -> MeanderState {
        let m = MeanderState()
        var rng = Mulberry32(seed: seed)
        for z0 in [150.0, 360, 570] {
            var nodes: [MeanderNode] = []
            for i in 0..<400 { nodes.append(MeanderNode(x: 60 + Double(i) * 1.5, z: z0 + (rng.next() - 0.5) * 0.4)) }
            m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: q, count: 400)))
        }
        return m
    }

    private let flat: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }

    /// Taktet wie `Terrain.meanderBeltStep`: CFL-Teilschritte aus der größten Rate.
    private func run(_ m: MeanderState, years: Double, dt: Double, _ c: SimConfig) {
        var y = 0.0
        while y < years - 1e-9 {
            let step = min(dt, years - y)
            let rate = m.beltMaxRate(config: c, heightAt: flat, riparianAt: { _ in 0 })
            let nsub = max(1, min(256, Int((rate * step / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            for _ in 0..<nsub { m.migrateBelt(dt: step / Double(nsub), config: c, heightAt: flat, riparianAt: { _ in 0 }) }
            y += step
        }
    }

    /// Der Kern wählt die Wellenlänge selbst: aus Rauschen wachsen Bögen von
    /// 10–14 Kanalbreiten (Leopold–Wolman), nicht Zacken in Bandbreite — der
    /// Befund vor Paket B war 1–4 Breiten. Breite hier 6,4 Zellen.
    func testKernelSelectsMeanderWavelength() {
        let c = SimConfig.production
        let m = straightRuns()
        run(m, years: 3000, dt: 1000, c)
        let b = MeanderState.beltWidthCells(discharge: q, config: c)
        var lams: [Double] = []
        for ch in m.channels {
            let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: max(2, Int((b / c.meanderNodeSpacing).rounded())))
            var infl: [Int] = []
            for i in 1..<ch.nodes.count where (curv[i - 1] < 0) != (curv[i] < 0) { infl.append(i) }
            guard infl.count >= 3 else { continue }
            var lam = 0.0
            for k in 0..<(infl.count - 2) { lam += dist(ch.nodes[infl[k]], ch.nodes[infl[k + 2]]) }
            lams.append(lam / Double(infl.count - 2) / b)
        }
        let mean = lams.reduce(0, +) / Double(max(1, lams.count))
        print(String(format: "[BELT-KERN] λ/b je Lauf %@ Mittel %.1f", lams.map { String(format: "%.1f", $0) }.joined(separator: " "), mean))
        XCTAssertEqual(lams.count, 3, "nicht jeder Lauf hat Bögen gebildet")
        XCTAssertGreaterThan(mean, 7, "Kern wählt zu kurze Wellen (Zacken statt Bögen)")
        XCTAssertLessThan(mean, 16, "Kern wählt zu lange Wellen")
    }

    /// Dieselbe Zeit in kleinen und großen Schritten → dieselbe Linie (bis auf
    /// einen Bruchteil der Kanalbreite). Der lokale Term läuft implizit, der
    /// Stromauf-Term CFL-getaktet; vor der impliziten Fassung zackte die Linie
    /// bei großen Teilschritten im Knotenabstand.
    func testMigrationIsStepSizeInvariant() {
        let c = SimConfig.production
        let a = straightRuns(), b = straightRuns()
        run(a, years: 1500, dt: 50, c)
        run(b, years: 1500, dt: 1500, c)
        let w = MeanderState.beltWidthCells(discharge: q, config: c)
        var acc = 0.0, cnt = 0.0, moved = 0.0
        for (ca, cb) in zip(a.channels, b.channels) {
            for p in ca.nodes {
                acc += cb.nodes.map { dist($0, p) }.min()!; cnt += 1
                moved = max(moved, abs(p.z - (ca.nodes.first?.z ?? p.z)))
            }
        }
        let mean = acc / cnt
        print(String(format: "[BELT-DT] mittlerer Abstand dt 50 ↔ 1500: %.3f Zellen (Breite %.1f, größte Auslenkung %.1f)", mean, w, moved))
        XCTAssertGreaterThan(moved, 1, "Testaufbau: nichts ist gewandert")
        XCTAssertLessThan(mean, 0.15 * w, "Gürtel-Migration hängt an der Schrittweite")
    }

    /// Lange Läufe bleiben beschränkt: endliche Knoten, Sinuosität unter dem
    /// Knäuel-Regime, und BEIDE Cutoff-Arten treten auf (Abnahmepunkt 15).
    func testLongRunStaysBoundedWithBothCutoffs() {
        let c = SimConfig.production
        let m = straightRuns()
        run(m, years: 30_000, dt: 1000, c)
        for ch in m.channels {
            XCTAssertTrue(ch.nodes.allSatisfy { $0.x.isFinite && $0.z.isFinite }, "Knoten nicht endlich")
            XCTAssertLessThan(ch.sinuosity, 8, "Lauf verknäult: Sinuosität \(ch.sinuosity)")
        }
        print("[BELT-LANG] Cutoffs Hals \(m.neckCutoffs), Chute \(m.chuteCutoffs), Sinuosität \(m.channels.map { String(format: "%.2f", $0.sinuosity) })")
        XCTAssertGreaterThan(m.neckCutoffs, 0, "kein Hals-Cutoff")
        XCTAssertGreaterThan(m.chuteCutoffs, 0, "kein Chute-Cutoff")
    }
}
