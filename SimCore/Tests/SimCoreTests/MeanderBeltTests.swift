import XCTest
@testable import SimCore

/// Wächter des Mäandergürtel-Kerns (Issue #174, Paket B) ohne Gelände: drei
/// gerade Läufe mit kleinem Rauschen auf einer Ebene. Prüft die Mechanik, die
/// das Gelände nicht verdecken darf — Wellenlängen-Wahl, Schrittweiten-
/// Unabhängigkeit, Beschränktheit. Kalibrier-Werkzeuge: `MeanderBeltCalibration`.
/// Kern-API nur für die Tests ohne Gelände: EINE Teilschrittzahl für alle
/// Läufe (die Produktion taktet je Lauf, `Terrain.meanderBeltStep`).
extension MeanderState {
    /// Größte Verschiebungsrate aller wandernden Läufe (Zellen/Jahr).
    func beltMaxRate(config: SimConfig, heightAt: (MeanderNode) -> Double) -> Double {
        var m = 0.0
        for ci in channels.indices { m = max(m, beltMaxRate(channel: ci, config: config, heightAt: heightAt)) }
        return m
    }

    /// Ein Teilschritt aller wandernden Läufe, mit Altarm-Alterung.
    func migrateBelt(dt: Double, time: Double, config: SimConfig, heightAt: (MeanderNode) -> Double) {
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices where Self.migrates(channels[ci], config) {
            migrateBeltChannel(ci, dt: dt, time: time, config: config, heightAt: heightAt)
        }
    }
}

final class MeanderBeltTests: XCTestCase {
    private let q = 20_000.0

    /// Drei gerade Läufe mit Rauschen; `discharges` je Lauf (Standard: alle `q`).
    private func straightRuns(_ seed: UInt32 = 7, discharges: [Double]? = nil) -> MeanderState {
        let m = MeanderState()
        var rng = Mulberry32(seed: seed)
        for (ri, z0) in [150.0, 360, 570].enumerated() {
            var nodes: [MeanderNode] = []
            for i in 0..<400 { nodes.append(MeanderNode(x: 60 + Double(i) * 1.5, z: z0 + (rng.next() - 0.5) * 0.4)) }
            m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: discharges?[ri] ?? q, count: 400)))
        }
        return m
    }

    private let flat: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }

    /// Größte ÖRTLICHE Sinuosität eines Laufs: Bogenlänge / Sehne über Fenster
    /// von 20 Kanalbreiten Bogenlänge — dieselbe Skala wie die Sättigung im
    /// Kern (`meanderBeltSinuosityWidths` = ±10). Grobe Schranke neben dem
    /// Knäuel-Kriterium `selfCrossings`: ein Omega-Bogen kurz vor dem
    /// Hals-Cutoff erreicht hier allein schon 7–8. Die Sinuosität des ganzen
    /// Laufs misst auf der unbegrenzten Ebene vor allem, wie weit die Linie
    /// seitlich auswandert (keine Talwand).
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

    /// Zahl der Selbstkreuzungen der Zentrumslinie (Paare nicht benachbarter
    /// Segmente, die sich schneiden). Ein Knäuel („Schlingen durch Schlingen")
    /// kreuzt sich; ein noch so enger Omega-Bogen vor dem Hals-Cutoff nicht.
    static func selfCrossings(_ ch: RiverChannel) -> Int {
        let p = ch.nodes
        guard p.count > 3 else { return 0 }
        func cross(_ a: MeanderNode, _ b: MeanderNode, _ c: MeanderNode) -> Double {
            (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
        }
        var n = 0
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            let (lo, hi) = (min(a.x, b.x), max(a.x, b.x)), (zl, zh) = (min(a.z, b.z), max(a.z, b.z))
            for j in stride(from: i + 2, to: p.count - 1, by: 1) {
                let c = p[j], d = p[j + 1]
                if max(c.x, d.x) < lo || min(c.x, d.x) > hi || max(c.z, d.z) < zl || min(c.z, d.z) > zh { continue }
                if cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0 { n += 1 }
            }
        }
        return n
    }

    /// Taktet wie `Terrain.meanderBeltStep`: CFL-Teilschritte aus der größten Rate.
    private func run(_ m: MeanderState, years: Double, dt: Double, _ c: SimConfig) {
        var y = 0.0
        while y < years - 1e-9 {
            let step = min(dt, years - y)
            let rate = m.beltMaxRate(config: c, heightAt: flat)
            let nsub = max(1, min(256, Int((rate * step / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            for si in 0..<nsub { m.migrateBelt(dt: step / Double(nsub), time: y + Double(si) * step / Double(nsub), config: c, heightAt: flat) }
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
        // Wachstum vor der Neukalibrierung #187 (Rate 0,02, Kern 1,5): der
        // Wächter misst die Numerik des Schemas (CFL-Teilschritte, implizite
        // Diffusion), nicht die Kalibrierung. Mit 0,04 / 1,0 wachsen die Bögen
        // rund 4,5-mal schneller (∝ Rate/L²); nach 3000 Jahren liegen dt 50
        // und 1500 dann im Mittel 5,0 Zellen auseinander, ohne Störquelle 3,55
        // Zellen bei 27,8 Zellen größter Auslenkung (13 %): der zeitliche
        // Fehler erster Ordnung wird vom exponentiellen Wachstum verstärkt.
        var c = SimConfig.production
        c.meanderBeltRate = 0.02
        c.meanderBeltKernelWidths = 1.5
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

    /// Lange Läufe bleiben beschränkt: endliche Knoten, keine Selbstkreuzung
    /// (kein Knäuel), örtliche Sinuosität unter einer groben Schranke, und
    /// BEIDE Cutoff-Arten treten auf (Abnahmepunkt 15). 60.000 Jahre. Ein Lauf
    /// liegt unter der Chute-Schwelle (`meanderChuteMinCells`): seit der
    /// Sättigung 3/4 (Zeitmittel-Kalibrierung) wachsen die Bögen der großen
    /// Läufe auf der unbegrenzten Ebene bis zum Chute-Cutoff, bevor ein Hals
    /// zugeht (drei Läufe à 20.000 Zellen: 0–2 Hals- neben 323–501
    /// Chute-Cutoffs über acht Rausch-Seeds).
    /// Seit der Kern-Kalibrierung von #187 (Rate 0,03, Kern 1,0 Breiten),
    /// 24 Rausch-Seeds (`testBeltKernelSpreadDiagnostic`, RS_LONG=60000,
    /// M4 Max): 131–169 Hals, 610–772 Chute, örtliche Sinuosität 4,6–8,1
    /// (Median 6,1), Selbstkreuzungen 0 auf allen. Vor #187 waren es 3,3–5,1;
    /// die alte Schranke 6 lag damit mitten in der Verteilung und kippte auf
    /// Linux (System-libm, andere Realisierung: 7,66). Die Sinuosität des ganzen
    /// Laufs (bis 14) misst auf der Ebene ohne Talwand das seitliche
    /// Auswandern, nicht Knäuel.
    /// Gegenprobe des Knäuel-Kriteriums: eine Schlinge, die über ihren eigenen
    /// Lauf zurückführt, zählt; ein enger Omega-Bogen mit offenem Hals nicht.
    func testSelfCrossingsSeparatesKnotFromOmega() {
        func ch(_ pts: [(Double, Double)]) -> RiverChannel {
            RiverChannel(nodes: pts.map { MeanderNode(x: $0.0, z: $0.1) }, discharge: Array(repeating: q, count: pts.count))
        }
        // Omega: Hals zwischen (−1, 0) und (1, 0), Bogen darüber.
        let omega = ch([(-5, 0), (-1, 0), (-2, 1), (-2, 3), (0, 4), (2, 3), (2, 1), (1, 0), (5, 0)])
        // Dieselbe Schlinge, die quer durch ihren Anfang zurückläuft.
        let knot = ch([(-5, 0), (-1, 0), (-2, 1), (-2, 3), (0, 4), (2, 3), (2, 1), (-3, 0.5), (-6, 0.5)])
        XCTAssertEqual(Self.selfCrossings(omega), 0)
        XCTAssertEqual(Self.selfCrossings(knot), 1)
    }

    func testLongRunStaysBoundedWithBothCutoffs() {
        let c = SimConfig.production
        let m = straightRuns(discharges: [q, q, 0.75 * c.meanderChuteMinCells])
        run(m, years: 60_000, dt: 1000, c)
        for ch in m.channels {
            XCTAssertTrue(ch.nodes.allSatisfy { $0.x.isFinite && $0.z.isFinite }, "Knoten nicht endlich")
            let loc = Self.maxLocalSinuosity(ch, config: c)
            XCTAssertEqual(Self.selfCrossings(ch), 0, "Lauf verknäult: Zentrumslinie kreuzt sich selbst")
            XCTAssertLessThan(loc, 10, "Lauf verknäult: örtliche Sinuosität \(loc)")
            // Die Störquelle hält den Kern mäandrierend: ohne sie lag jeder Lauf
            // ab Jahr ~62.000 gerade (Sinuosität 1,00), mit ihr örtlich 3–4.
            XCTAssertGreaterThan(loc, 1.5, "Lauf nach 60.000 Jahren gerade (örtliche Sinuosität \(loc))")
        }
        print("[BELT-LANG] Cutoffs Hals \(m.neckCutoffs), Chute \(m.chuteCutoffs), örtliche Sinuosität \(m.channels.map { String(format: "%.2f", Self.maxLocalSinuosity($0, config: c)) })")
        XCTAssertGreaterThan(m.neckCutoffs, 0, "kein Hals-Cutoff")
        XCTAssertGreaterThan(m.chuteCutoffs, 0, "kein Chute-Cutoff")
    }
}
