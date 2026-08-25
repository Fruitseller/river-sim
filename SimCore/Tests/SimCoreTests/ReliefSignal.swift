import XCTest
@testable import SimCore

/// Wächter für das Regelsignal des Relief-Servos (Issue #3). Bis dahin regelte er
/// auf `landRelief()` = max − min über Land; da das Minimum per Definition knapp
/// über `sea` liegt, WAR das Signal die Höhe der höchsten Zelle — eine einzelne
/// Nadel (oder ein Sculpt-Strich) steuerte damit die Hebung der ganzen Insel.
final class ReliefSignal: XCTestCase {

    private func maxMinusMin(_ heights: [Double], sea: Double) -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for v in heights where v > sea { lo = min(lo, v); hi = max(hi, v) }
        return hi < lo ? 0 : hi - lo
    }

    /// Kernaussage: ein künstlich hochgezogener Einzelgipfel verschiebt das
    /// Regelsignal nur marginal, max − min dagegen voll.
    func testSinglePeakBarelyMovesSignal() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<40 { t.step(dtYears: 500) } // gealtertes, eingeschwungenes Terrain

        let base = t.h
        let spanBefore = maxMinusMin(base, sea: c.sea)
        let signalBefore = Terrain.landReliefRobust(heights: base, sea: c.sea)
        XCTAssertGreaterThan(signalBefore, 0.05, "Testterrain muss überhaupt Relief haben")

        // Eine einzelne Landzelle auf Maximalhöhe ziehen (die „Nadel").
        var spiked = base
        let peak = spiked.indices.first { spiked[$0] > c.sea }!
        spiked[peak] = 1.4

        let spanAfter = maxMinusMin(spiked, sea: c.sea)
        let signalAfter = Terrain.landReliefRobust(heights: spiked, sea: c.sea)

        // max − min springt voll mit (gemessen 0.5097 → 1.2500, +145 %) …
        XCTAssertGreaterThan(spanAfter, spanBefore * 1.5,
                             "max − min müsste durch die Nadel voll ausschlagen (\(spanBefore) → \(spanAfter))")
        // … das Regelsignal gar nicht: gemessen bleibt es bei 0.16211, weil die
        // exakte Verschiebung (+0.019 %, sortiert gerechnet 0.161965 → 0.161995)
        // unter der Bin-Breite 0.000488 der Histogramm-Auswertung liegt. Die
        // Schranke steht trotzdem bei 1 %, damit der Test nicht an der
        // Quantisierung klebt, sondern die Aussage prüft.
        let drift = abs(signalAfter - signalBefore) / signalBefore
        XCTAssertLessThan(drift, 0.01,
                          "Nadel verschiebt das Regelsignal um \(drift * 100) % (\(signalBefore) → \(signalAfter))")
    }

    /// Gegenprobe: das Signal ist nicht einfach stur, sondern folgt ECHTER
    /// Einebnung — sonst könnte der Servo nie anspringen.
    func testSignalFollowsRealFlattening() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let base = t.h
        let signal0 = Terrain.landReliefRobust(heights: base, sea: c.sea)

        // Alle Landhöhen zur Hälfte auf ihr Mittel ziehen = halbes Relief.
        let land = base.filter { $0 > c.sea }
        let mean = land.reduce(0, +) / Double(land.count)
        let flattened = base.map { $0 > c.sea ? mean + ($0 - mean) * 0.5 : $0 }
        let signal1 = Terrain.landReliefRobust(heights: flattened, sea: c.sea)

        XCTAssertEqual(signal1, signal0 * 0.5, accuracy: signal0 * 0.05,
                       "Halbiertes Relief muss das Signal halbieren (\(signal0) → \(signal1))")
    }

    /// Der Servo liest genau dieses Signal und rampt linear über `reliefServoBand`.
    /// `cfg` ist unveränderlich → je Betriebspunkt ein eigenes (identisch
    /// generiertes) Terrain, das sich nur im `reliefTarget` unterscheidet.
    func testServoRateFollowsSignal() {
        var base = SimConfig(); base.n = 96
        let signal = Terrain(config: base, seed: 4242).landReliefRobust()
        func servo(target: Double) -> Double {
            var c = base; c.reliefTarget = target
            return Terrain(config: c, seed: 4242).reliefServoRate()
        }
        // Ziel unter dem Ist-Signal → Servo aus.
        XCTAssertEqual(servo(target: signal - 0.01), 0, "Über Ziel darf der Servo nicht heben")
        // Ziel eine halbe Bandbreite über dem Ist-Signal → halbe Rate.
        XCTAssertEqual(servo(target: signal + base.reliefServoBand * 0.5),
                       base.reliefServoPer100y * 0.5,
                       accuracy: base.reliefServoPer100y * 0.02,
                       "Servo muss linear über das Band rampen")
        // Weit unter Ziel → gedeckelt bei reliefServoPer100y.
        XCTAssertEqual(servo(target: signal + base.reliefServoBand * 10),
                       base.reliefServoPer100y,
                       "Servo muss bei reliefServoPer100y deckeln")
    }

    /// Gegenstück zum Einstieg mit SCHON GEMESSENEM Regelsignal: die
    /// Diagnose-Anzeige zieht Regelsignal, Talseite und Servo aus EINEM
    /// Histogramm-Pass und reicht das Signal durch. Fällt die Delegation der
    /// parameterlosen Variante auseinander, zeigt das Panel etwas anderes, als
    /// in `step()` wirkt — genau der Duplikat-Fehler, den `reliefServoRate` als
    /// einzige Quelle der Formel verhindern soll.
    func testServoRateOnMeasuredSignalMatchesSelfMeasured() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 4242)

        // Der Punkt, an dem beide Wege übereinstimmen MÜSSEN: das Ist-Signal.
        // Bit-Gleichheit (accuracy 0), nicht „ungefähr" — die Anzeige rechnet
        // nichts nach, sie reicht denselben Wert durch.
        XCTAssertEqual(t.reliefServoRate(reliefSignal: t.landReliefRobust()),
                       t.reliefServoRate(), accuracy: 0,
                       "Delegation weicht von der parameterlosen Variante ab")

        // Die Rampe direkt am neuen Einstieg, inklusive der Ränder, die im
        // Betrieb nicht vorkommen und deshalb sonst ungepinnt blieben.
        // (testServoRateFollowsSignal prüft dieselbe Rampe von der anderen
        // Seite, über reliefTarget-Varianten.)
        let band = c.reliefServoBand, rate = c.reliefServoPer100y
        let cases: [(signal: Double, expected: Double, why: String)] = [
            (c.reliefTarget + 0.05, 0, "über Ziel → aus"),
            (c.reliefTarget, 0, "genau auf Ziel → aus, Defizit 0 hebt nicht"),
            (c.reliefTarget - band * 0.5, rate * 0.5, "halbes Band → halbe Rate"),
            (c.reliefTarget - band * 10, rate, "weit unter Ziel → Deckel"),
            (0, rate * (c.reliefTarget / band), "Signal 0 → Defizit ist reliefTarget"),
            (-0.5, rate, "negatives Signal → Deckel, nicht darüber hinaus"),
        ]
        for k in cases {
            XCTAssertEqual(t.reliefServoRate(reliefSignal: k.signal), k.expected,
                           accuracy: rate * 1e-12, "Signal \(k.signal): \(k.why)")
        }
    }

    /// Das Signal ist praktisch auflösungsunabhängig (die verworfene Fenster-
    /// Variante NICHT — s. Config-Logbuch bei reliefTarget). Die Reihe geht
    /// bewusst bis in die PRODUKTIONS-Auflösung (SimConfig().n = 832): genau
    /// darauf stützt sich die Kalibrier-Behauptung, dass Testkonfigs mit
    /// kleinerem n auf dasselbe reliefTarget regeln wie die Produktion.
    /// Gemessen (Seed 1337, frisches Terrain): 0.16504 (n=80), 0.17822 (160),
    /// 0.18311 (320), 0.18457 (640), 0.18506 (832) — Spanne 11 %, ab n=160 nur
    /// noch 3.7 %.
    func testSignalIsResolutionStable() {
        var values: [Double] = []
        for n in [80, 160, 320, 640, SimConfig().n] {
            var c = SimConfig(); c.n = n
            values.append(Terrain(config: c, seed: 1337).landReliefRobust())
        }
        let lo = values.min()!, hi = values.max()!
        XCTAssertLessThan((hi - lo) / hi, 0.15,
                          "Signal driftet mit der Auflösung: \(values)")
        // Ab der ersten Testauflösung (n=160) aufwärts noch enger — die
        // Produktionsauflösung darf nicht aus der Reihe tanzen.
        let fromTestRes = Array(values.dropFirst())
        let lo2 = fromTestRes.min()!, hi2 = fromTestRes.max()!
        XCTAssertLessThan((hi2 - lo2) / hi2, 0.06,
                          "Signal bei Produktionsauflösung weicht ab: \(values)")
    }
}
