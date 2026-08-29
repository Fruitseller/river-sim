import XCTest
@testable import SimCore

/// **Der Bett-Funnel trägt seine Regel genau einmal** (Issue #81).
///
/// Alle fluvialen Bett-Bewegungen außer den zwei, die ihr Gletscher-Gate selbst
/// tragen (`outletIncision`, `Hydraulic.erode`), laufen über
/// `Terrain.erodeCell`/`depositCell`. Den ruft man auf ZWEI Wegen: über die
/// Klassen-Property (Testpfad `transportLimited`, geparkte
/// `floodplainAggradation`) und über die Roh-Puffer-Sicht `Terrain.Bed`, die die
/// Hot-Loops seit der Perf-Runde 3 benutzen (`docs/perf-measurements.md` §I).
///
/// Bis Issue #81 stand die Regel — erst Sediment, dann Fels, `h = rock + sed`,
/// unter Eis gar nichts — in BEIDEN Wegen ausgeschrieben, synchron gehalten nur
/// durch den Kommentar „wer eine ändert, ändert beide". Seither ist der
/// Property-Weg ein dünner Adapter über die Bed-Fassung.
///
/// Was dieser Wächter deshalb prüft:
///
/// 1. **Die Regel selbst** (`testFunnelRuleHoldsInBothCallShapes`) — der
///    tragende Teil. Ein neu ausgeschriebener oder verrutschter Funnel fällt
///    hier auf, egal auf welchem Weg.
/// 2. **Parität beider Wege** — solange der Adapter delegiert, kann sie nicht
///    brechen; sie ist der Wächter gegen das WIEDERAUFTRENNEN. Wer die Regel in
///    den Adapter zurückschreibt, stellt den Stand vor #81 wieder her, und ab
///    dann misst die Parität wieder etwas (belegt beim Bau: Gate aus der
///    Property-Fassung entfernt → `testErodeParityUnderIce` rot; Sediment-Anteil
///    halbiert → beide Erosions-Paritäten rot).
final class BedFunnelTests: XCTestCase {

    private let n = 32

    private func cfg() -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

    /// Ein Aufruf-Weg in den Funnel: Name für die Fehlermeldung plus die beiden
    /// Operationen. Die Tests laufen über diese Tabelle, statt die Wahl des Wegs
    /// an jeder Aufrufstelle erneut auszuschreiben.
    private struct CallShape {
        let name: String
        let erode: (Terrain, Int, Double) -> Double
        let deposit: (Terrain, Int, Double) -> Double
    }

    private static let viaProperty = CallShape(
        name: "Property",
        erode: { $0.erodeCellViaPropertyForTests($1, $2) },
        deposit: { $0.depositCellViaPropertyForTests($1, $2) })

    private static let viaBed = CallShape(
        name: "Bed",
        erode: { $0.erodeCellViaBedForTests($1, $2) },
        deposit: { $0.depositCellViaBedForTests($1, $2) })

    /// Synthetisches Bett: die Zellen decken die Fälle ab, an denen sich die
    /// beiden Wege unterscheiden können — kein Sediment, weniger Sediment als
    /// abgetragen wird, mehr Sediment als abgetragen wird. `withIce` legt Eis
    /// auf jede dritte Zelle; ohne Eis bleibt die Maske LEER, weil genau das im
    /// Funnel „aus" heißt.
    private func fillSyntheticBed(_ t: Terrain, withIce: Bool) {
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

    /// Die drei Bett-Felder unter ihrem Namen — der Vergleich nennt sonst nur
    /// einen Index und man muss raten, welches Feld gemeint ist.
    private func namedFields(_ t: Terrain) -> [(name: String, values: [Double])] {
        [("h", t.h), ("sed", t.sed), ("rock", t.rock)]
    }

    /// Jede Seite bringt ihren eigenen Namen mit, statt dass die Meldung die
    /// Rollen der Argumente errät — sonst stimmt sie nur so lange, wie der
    /// Aufrufer sie in der erwarteten Reihenfolge übergibt.
    private func assertBedsAreBitEqual(_ left: (shape: CallShape, terrain: Terrain),
                                       _ right: (shape: CallShape, terrain: Terrain),
                                       _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(namedFields(left.terrain), namedFields(right.terrain)) {
            for k in 0..<a.values.count where a.values[k].bitPattern != b.values[k].bitPattern {
                XCTFail("\(what): \(a.name)[\(k)] weicht ab — "
                        + "\(left.shape.name) \(a.values[k]) "
                        + "vs. \(right.shape.name) \(b.values[k])",
                        file: file, line: line)
                return
            }
        }
    }

    /// Parität der beiden Aufruf-Wege: gleiche Rückgabe, gleiches Bett. Welche
    /// Operation geprüft wird, sagt der KeyPath in `CallShape` — die Wahl ist
    /// dort schon modelliert und wird hier nicht als Flag zweitverwaltet.
    private func checkParity(withIce: Bool,
                             _ op: KeyPath<CallShape, (Terrain, Int, Double) -> Double>,
                             _ label: String) {
        let c = cfg()
        let byProperty = Terrain(config: c, seed: 4711)
        let byBed = Terrain(config: c, seed: 4711)
        fillSyntheticBed(byProperty, withIce: withIce)
        fillSyntheticBed(byBed, withIce: withIce)
        var moved = 0
        for k in 0..<c.count {
            let amount = amounts[k % amounts.count]
            let p = Self.viaProperty[keyPath: op](byProperty, k, amount)
            let b = Self.viaBed[keyPath: op](byBed, k, amount)
            XCTAssertEqual(p.bitPattern, b.bitPattern,
                           "Rückgabe an Zelle \(k) (Betrag \(amount)) weicht ab: \(p) vs. \(b)")
            if p != 0 { moved += 1 }
        }
        let what = "\(label)\(withIce ? " mit Eis" : " ohne Eis")"
        assertBedsAreBitEqual((Self.viaProperty, byProperty), (Self.viaBed, byBed), what)
        // Ein Wächter, der nichts bewegt, wäre auf beiden Wegen gleich grün.
        XCTAssertGreaterThan(moved, c.count / 4, "\(what): der Wächter hat kaum etwas bewegt")
    }

    /// **Bit-Identitäts-Instrument für die Pfade, die sich wirklich geändert
    /// haben** (Issue #81).
    ///
    /// `simperf --hash` fährt `SimConfig()` — den Produktionspfad, und genau der
    /// ruft die Adapter NICHT auf (`hydraulicEnabled = true` heißt Droplet statt
    /// `transportLimited`, `floodplainEnabled = false` heißt keine Aggradation).
    /// Sein Fingerprint KONNTE sich durch den Adapter-Umbau nicht ändern; als
    /// Beleg für diesen Umbau ist er wertlos.
    ///
    /// Der Beleg gehört auf die Konfigurationen, in denen die zwei Aufrufer
    /// wirklich laufen — und das sind ZWEI, nicht eine. `floodplainAggradation`
    /// hängt zwar an `floodplainEnabled`, steht aber INNERHALB des
    /// `hydraulicEnabled`-Zweigs; `transportLimited` steht im Gegenzweig. KEIN
    /// Wert von `hydraulicEnabled` erreicht beide, ein einzelner Lauf belegt
    /// also immer nur einen Aufrufer. Deshalb zwei Arme, jeder mit
    /// `Terrain.fingerprint()` darüber (voller State-Fingerprint, Issue #78).
    ///
    /// `n = 96` ist die Kantenlänge der übrigen Kopplungstests dieser Suite
    /// (`meanderCfg`), 20.000 Jahre dieselbe Marke, an der `Glacier.swift` den
    /// Grid-Pfad prüft, Seed 1337 der Seed des Mess-Harness. Zusammen 0,5 s —
    /// nicht die Laufzeit ist der Grund fürs Gate, sondern die Konvention
    /// (`MeasurementGate.swift`).
    ///
    /// Ein Erwartungswert steht bewusst NICHT hier: der Fingerprint ist ein
    /// Pro-Maschine-Vergleich (System-libm, AGENTS.md „Laufzeit messen").
    /// Vorher/Nachher-Werte dieses Umbaus: `docs/perf-measurements.md` §K.
    func testChangedPathFingerprintDiagnostic() throws {
        try skipUnlessMeasuring()
        for (arm, hydraulic) in [("transportLimited", false), ("floodplainAggradation", true)] {
            var c = SimConfig()
            c.n = 96; c.world = calibrationWorld
            c.hydraulicEnabled = hydraulic
            c.floodplainEnabled = true
            let t = Terrain(config: c, seed: 1337)
            while t.years < 20_000 { t.step(dtYears: 500) }
            print("[FUNNEL] Arm \(arm) (hydraulicEnabled=\(hydraulic)): fingerprint "
                  + String(format: "%016llx", t.fingerprint()))
        }
    }

    func testErodeParityWithoutIce() { checkParity(withIce: false, \.erode, "erodeCell") }
    func testErodeParityUnderIce() { checkParity(withIce: true, \.erode, "erodeCell") }
    func testDepositParityWithoutIce() { checkParity(withIce: false, \.deposit, "depositCell") }
    func testDepositParityUnderIce() { checkParity(withIce: true, \.deposit, "depositCell") }

    /// Die Regel, die der Funnel trägt — geprüft auf beiden Wegen, damit sie
    /// nicht gemeinsam abdriften können: erst Sediment, dann Fels,
    /// `h = rock + sed`, Rückgabe = tatsächlich bewegter Betrag, unter Eis
    /// nichts.
    func testFunnelRuleHoldsInBothCallShapes() {
        for shape in [Self.viaProperty, Self.viaBed] {
            let c = cfg()
            let t = Terrain(config: c, seed: 4711)
            fillSyntheticBed(t, withIce: true)
            let ice = t.underIce
            let sed0 = t.sed, rock0 = t.rock

            var askedOnIce = 0, askedOffIce = 0
            for k in 0..<c.count {
                let amount = amounts[k % amounts.count]
                let moved = shape.erode(t, k, amount)
                let want = max(0, amount)
                if ice[k] {
                    XCTAssertEqual(moved, 0, "\(shape.name): unter Eis abgetragen (Zelle \(k))")
                    XCTAssertEqual(t.sed[k], sed0[k],
                                   "\(shape.name): unter Eis Sediment bewegt (Zelle \(k))")
                    XCTAssertEqual(t.rock[k], rock0[k],
                                   "\(shape.name): unter Eis Fels bewegt (Zelle \(k))")
                    if want > 0 { askedOnIce += 1 }
                    continue
                }
                XCTAssertEqual(moved, want, "\(shape.name): Rückgabe ≠ Betrag (Zelle \(k))")
                XCTAssertEqual(t.sed[k], max(0, sed0[k] - want), accuracy: 1e-15,
                               "\(shape.name): Sediment nicht zuerst abgetragen (Zelle \(k))")
                XCTAssertEqual(t.rock[k], rock0[k] - max(0, want - sed0[k]), accuracy: 1e-15,
                               "\(shape.name): Fels statt Sediment angegriffen (Zelle \(k))")
                XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                               "\(shape.name): h ≠ rock + sed nach Abtrag (Zelle \(k))")
                if want > 0 { askedOffIce += 1 }
            }
            XCTAssertGreaterThan(askedOnIce, 0, "Testaufbau: keine vergletscherte Zelle angefragt")
            XCTAssertGreaterThan(askedOffIce, 0, "Testaufbau: keine eisfreie Zelle angefragt")

            // Deposition auf demselben Bett: nur Sediment wächst, Fels nie.
            let sed1 = t.sed, rock1 = t.rock
            for k in 0..<c.count {
                let amount = amounts[k % amounts.count]
                let moved = shape.deposit(t, k, amount)
                let want = ice[k] ? 0 : max(0, amount)
                XCTAssertEqual(moved, want, "\(shape.name): Ablage-Rückgabe falsch (Zelle \(k))")
                XCTAssertEqual(t.sed[k], sed1[k] + want, accuracy: 1e-15,
                               "\(shape.name): Sediment falsch angewachsen (Zelle \(k))")
                XCTAssertEqual(t.rock[k], rock1[k],
                               "\(shape.name): Ablage hat Fels verändert (Zelle \(k))")
                XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                               "\(shape.name): h ≠ rock + sed nach Ablage (Zelle \(k))")
            }
        }
    }
}
