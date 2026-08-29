import XCTest
@testable import SimCore

/// **Der Bett-Funnel trägt seine Regel genau einmal** (Issue #81).
///
/// Alle fluvialen Bett-Bewegungen außer den zwei, die ihr Gletscher-Gate selbst
/// tragen (`outletIncision`, `Hydraulic.erode`), laufen über
/// `Terrain.erodeCell`/`depositCell`. Den Funnel gibt es in zwei
/// AUFRUF-Formen: über die Klassen-Property (Testpfad `transportLimited`,
/// geparkte `floodplainAggradation`) und über die Roh-Puffer-Sicht
/// `Terrain.Bed`, die die Hot-Loops seit der Perf-Runde 3 benutzen
/// (`docs/perf-measurements.md` §I).
///
/// Bis Issue #81 stand die Regel — erst Sediment, dann Fels, `h = rock + sed`,
/// unter Eis gar nichts — in BEIDEN Formen ausgeschrieben, synchron gehalten
/// nur durch den Kommentar „wer eine ändert, ändert beide". Seither ist die
/// Property-Form ein dünner Adapter über die Bed-Form. Dieser Wächter hält
/// beides fest:
///
/// 1. **Parität** — beide Aufruf-Formen liefern über eine Matrix aus
///    Bett-Zuständen und Beträgen bit-gleiche Rückgaben und bit-gleiche
///    Felder, mit und ohne `underIce`.
/// 2. **Die Regel selbst** — damit die Parität nicht dadurch grün bleibt, dass
///    beide Formen gemeinsam falsch werden.
final class BedFunnelTests: XCTestCase {

    private let n = 32

    private func cfg() -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

    /// Synthetisches Bett: die Zellen decken die Fälle ab, an denen sich die
    /// beiden Zweige des Funnels unterscheiden können — kein Sediment, weniger
    /// Sediment als abgetragen wird, mehr Sediment als abgetragen wird.
    /// `withIce` legt Eis auf jede dritte Zelle; ohne Eis bleibt die Maske
    /// LEER, weil genau das im Funnel „aus" heißt.
    private func synthetic(_ t: Terrain, withIce: Bool) {
        let count = n * n
        var sed = [Double](repeating: 0, count: count)
        var rock = [Double](repeating: 0, count: count)
        var h = [Double](repeating: 0, count: count)
        for k in 0..<count {
            sed[k] = Double(k % 5) * 0.037            // 0 … 0.148
            rock[k] = 1 + Double(k % 7) * 0.11
            h[k] = rock[k] + sed[k]
        }
        let ice = withIce ? (0..<count).map { $0 % 3 == 0 } : []
        t.setBedForTests(h: h, sed: sed, rock: rock, underIce: ice)
    }

    /// Beträge quer über die Fallunterscheidung: nichts, negativ (der Funnel
    /// klemmt auf 0), unter/über dem Sediment-Vorrat, groß.
    private let amounts: [Double] = [0, -0.5, 1e-12, 0.02, 0.037, 0.05, 0.148, 0.9, 12.5]

    private func fields(_ t: Terrain) -> [[Double]] { [t.h, t.sed, t.rock] }

    private func assertBitEqual(_ a: [[Double]], _ b: [[Double]], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        for (fi, name) in ["h", "sed", "rock"].enumerated() {
            for k in 0..<a[fi].count where a[fi][k].bitPattern != b[fi][k].bitPattern {
                XCTFail("\(what): \(name)[\(k)] weicht ab — Property \(a[fi][k]) vs. Bed \(b[fi][k])",
                        file: file, line: line)
                return
            }
        }
    }

    /// Parität der beiden Aufruf-Formen: gleiche Rückgabe, gleiches Bett.
    private func checkParity(withIce: Bool, erode: Bool) {
        let c = cfg()
        let viaProperty = Terrain(config: c, seed: 4711)
        let viaBed = Terrain(config: c, seed: 4711)
        synthetic(viaProperty, withIce: withIce)
        synthetic(viaBed, withIce: withIce)

        var touched = 0
        for k in 0..<c.count {
            let amount = amounts[k % amounts.count]
            let p = erode ? viaProperty.erodeCellViaPropertyForTests(k, amount)
                          : viaProperty.depositCellViaPropertyForTests(k, amount)
            let b = erode ? viaBed.erodeCellViaBedForTests(k, amount)
                          : viaBed.depositCellViaBedForTests(k, amount)
            XCTAssertEqual(p.bitPattern, b.bitPattern,
                           "Rückgabe an Zelle \(k) (Betrag \(amount)) weicht ab: \(p) vs. \(b)")
            if p != 0 { touched += 1 }
        }
        let what = "\(erode ? "erodeCell" : "depositCell")\(withIce ? " mit Eis" : " ohne Eis")"
        assertBitEqual(fields(viaProperty), fields(viaBed), what)
        // Ein Wächter, der nichts bewegt, wäre in beiden Formen gleich grün.
        XCTAssertGreaterThan(touched, c.count / 4, "\(what): der Wächter hat kaum etwas bewegt")
    }

    func testErodeParityWithoutIce() { checkParity(withIce: false, erode: true) }
    func testErodeParityUnderIce() { checkParity(withIce: true, erode: true) }
    func testDepositParityWithoutIce() { checkParity(withIce: false, erode: false) }
    func testDepositParityUnderIce() { checkParity(withIce: true, erode: false) }

    /// Die Regel, die der Funnel trägt — geprüft an beiden Aufruf-Formen, damit
    /// sie nicht gemeinsam abdriften können: erst Sediment, dann Fels,
    /// `h = rock + sed`, Rückgabe = tatsächlich bewegter Betrag, unter Eis
    /// nichts.
    func testFunnelRuleHoldsInBothCallShapes() {
        for viaBed in [false, true] {
            let c = cfg()
            let t = Terrain(config: c, seed: 4711)
            synthetic(t, withIce: true)
            let ice = t.underIce
            let sed0 = t.sed, rock0 = t.rock

            var erodedOnIce = 0, erodedOffIce = 0
            for k in 0..<c.count {
                let amount = amounts[k % amounts.count]
                let moved = viaBed ? t.erodeCellViaBedForTests(k, amount)
                                   : t.erodeCellViaPropertyForTests(k, amount)
                let want = max(0, amount)
                if ice[k] {
                    XCTAssertEqual(moved, 0, "unter Eis abgetragen (Zelle \(k))")
                    XCTAssertEqual(t.sed[k], sed0[k], "unter Eis Sediment bewegt (Zelle \(k))")
                    XCTAssertEqual(t.rock[k], rock0[k], "unter Eis Fels bewegt (Zelle \(k))")
                    if want > 0 { erodedOnIce += 1 }
                    continue
                }
                XCTAssertEqual(moved, want, "Rückgabe ≠ Betrag (Zelle \(k))")
                XCTAssertEqual(t.sed[k], max(0, sed0[k] - want), accuracy: 1e-15,
                               "Sediment nicht zuerst abgetragen (Zelle \(k))")
                XCTAssertEqual(t.rock[k], rock0[k] - max(0, want - sed0[k]), accuracy: 1e-15,
                               "Fels statt Sediment angegriffen (Zelle \(k))")
                XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                               "h ≠ rock + sed nach Abtrag (Zelle \(k))")
                if want > 0 { erodedOffIce += 1 }
            }
            XCTAssertGreaterThan(erodedOnIce, 0, "Testaufbau: keine vergletscherte Zelle angefragt")
            XCTAssertGreaterThan(erodedOffIce, 0, "Testaufbau: keine eisfreie Zelle angefragt")

            // Deposition auf demselben Bett: nur Sediment wächst, Fels nie.
            let sed1 = t.sed, rock1 = t.rock
            for k in 0..<c.count {
                let amount = amounts[k % amounts.count]
                let moved = viaBed ? t.depositCellViaBedForTests(k, amount)
                                   : t.depositCellViaPropertyForTests(k, amount)
                let want = ice[k] ? 0 : max(0, amount)
                XCTAssertEqual(moved, want, "Ablage-Rückgabe falsch (Zelle \(k))")
                XCTAssertEqual(t.sed[k], sed1[k] + want, accuracy: 1e-15,
                               "Sediment falsch angewachsen (Zelle \(k))")
                XCTAssertEqual(t.rock[k], rock1[k], "Ablage hat Fels verändert (Zelle \(k))")
                XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                               "h ≠ rock + sed nach Ablage (Zelle \(k))")
            }
        }
    }
}
