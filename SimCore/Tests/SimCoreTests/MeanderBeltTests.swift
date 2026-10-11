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

    /// Größte ÖRTLICHE Sinuosität eines Laufs: Bogenlänge / Sehne über Fenster
    /// von 20 Kanalbreiten Bogenlänge — dieselbe Skala wie die Sättigung im
    /// Kern (`meanderBeltSinuosityWidths` = ±10). Das ist das Knäuel-Kriterium;
    /// die Sinuosität des ganzen Laufs misst auf der unbegrenzten Ebene vor
    /// allem, wie weit die Linie seitlich auswandert (keine Talwand).
    static func maxLocalSinuosity(_ ch: RiverChannel, config c: SimConfig) -> Double {
        let nodes = ch.nodes
        guard nodes.count > 2 else { return 1 }
        let b = MeanderState.beltWidthCells(discharge: ch.discharge.max() ?? 0, config: c)
        let m = max(2, Int((c.meanderBeltSinuosityWidths * b / c.meanderNodeSpacing).rounded()))
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        var best = 1.0
        for i in stride(from: 0, to: nodes.count - 2 * m, by: max(1, m / 4)) {
            let chord = dist(nodes[i], nodes[i + 2 * m])
            if chord > 1e-9 { best = max(best, (cum[i + 2 * m] - cum[i]) / chord) }
        }
        return best
    }

    /// Taktet wie `Terrain.meanderBeltStep`: CFL-Teilschritte aus der größten Rate.
    private func run(_ m: MeanderState, years: Double, dt: Double, _ c: SimConfig) {
        var y = 0.0
        while y < years - 1e-9 {
            let step = min(dt, years - y)
            let rate = m.beltMaxRate(config: c, heightAt: flat, riparianAt: { _ in 0 })
            let nsub = max(1, min(256, Int((rate * step / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            for si in 0..<nsub { m.migrateBelt(dt: step / Double(nsub), time: y + Double(si) * step / Double(nsub), config: c, heightAt: flat, riparianAt: { _ in 0 }) }
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
            // Lineare Phase (3000 Jahre, Bögen unter ½ Breite hoch): jeder
            // Vorzeichenwechsel zählt, ohne den Amplituden-Filter der Gelände-Messung.
            let lam = ZielbildMetrics.bends(ch.nodes, curv: curv, width: b, minAmplitudeWidths: 0).wavelength
            guard lam > 0 else { continue }
            lams.append(lam / b)
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
    /// Die Störquelle (`meanderBeltNoise`) ist nur in VERTEILUNG
    /// schrittweiten-unabhängig: dt 50 und dt 1500 ziehen verschiedene
    /// Realisierungen. Gemessen über sechs Rausch-Seeds nach 3000 Jahren
    /// 0,33–0,59 Zellen Abstand bei 2–7 Zellen Auslenkung
    /// (`testBeltKernelSpreadDiagnostic`); ohne Störquelle nach 1500 Jahren 0,09.
    func testMigrationIsStepSizeInvariant() {
        let c = SimConfig.production
        let a = straightRuns(), b = straightRuns()
        run(a, years: 3000, dt: 50, c)
        run(b, years: 3000, dt: 1500, c)
        let w = MeanderState.beltWidthCells(discharge: q, config: c)
        var acc = 0.0, cnt = 0.0, moved = 0.0
        for (ca, cb) in zip(a.channels, b.channels) {
            for p in ca.nodes {
                acc += cb.nodes.map { dist($0, p) }.min()!; cnt += 1
                moved = max(moved, abs(p.z - (ca.nodes.first?.z ?? p.z)))
            }
        }
        let mean = acc / cnt
        print(String(format: "[BELT-DT] mittlerer Abstand dt 50 ↔ 1500 nach 3000 J.: %.3f Zellen (Breite %.1f, größte Auslenkung %.1f)", mean, w, moved))
        XCTAssertGreaterThan(moved, 1, "Testaufbau: nichts ist gewandert")
        XCTAssertLessThan(mean, 0.15 * w, "Gürtel-Migration hängt an der Schrittweite")
    }

    /// Lange Läufe bleiben beschränkt: endliche Knoten, örtliche Sinuosität
    /// unter dem Knäuel-Regime, und BEIDE Cutoff-Arten treten auf
    /// (Abnahmepunkt 15). 60.000 Jahre: nach 30.000 gab es über sechs
    /// Rausch-Seeds nur 1–5 Hals-Cutoffs (neben 51–66 Chute), nach 60.000
    /// 3–12. Örtliche Sinuosität dort 3,3–4,3; die des ganzen Laufs (bis 13)
    /// misst auf der Ebene ohne Talwand das seitliche Auswandern, nicht Knäuel.
    func testLongRunStaysBoundedWithBothCutoffs() {
        let c = SimConfig.production
        let m = straightRuns()
        run(m, years: 60_000, dt: 1000, c)
        for ch in m.channels {
            XCTAssertTrue(ch.nodes.allSatisfy { $0.x.isFinite && $0.z.isFinite }, "Knoten nicht endlich")
            let loc = Self.maxLocalSinuosity(ch, config: c)
            XCTAssertLessThan(loc, 6, "Lauf verknäult: örtliche Sinuosität \(loc)")
            // Die Störquelle hält den Kern mäandrierend: ohne sie lag jeder Lauf
            // ab Jahr ~62.000 gerade (Sinuosität 1,00), mit ihr örtlich 3–4.
            XCTAssertGreaterThan(loc, 1.5, "Lauf nach 60.000 Jahren gerade (örtliche Sinuosität \(loc))")
        }
        print("[BELT-LANG] Cutoffs Hals \(m.neckCutoffs), Chute \(m.chuteCutoffs), örtliche Sinuosität \(m.channels.map { String(format: "%.2f", Self.maxLocalSinuosity($0, config: c)) })")
        XCTAssertGreaterThan(m.neckCutoffs, 0, "kein Hals-Cutoff")
        XCTAssertGreaterThan(m.chuteCutoffs, 0, "kein Chute-Cutoff")
    }
}
