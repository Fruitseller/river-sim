import XCTest
@testable import SimCore

/// **Der Bett-Funnel trägt seine Regel genau einmal** (Issues #81/#96) — und
/// seit #96 deckt er ALLE Bett-Schreiber ab, keine zwei Ausnahmen mehr.
///
/// Die Regel — erst Sediment, dann Fels, `h = rock + sed`, Gletscher-Gate —
/// steht einzig in `Terrain.Bed.erode(_:_)`/`deposit(_:_:)`. Den ruft man auf
/// VIER Wegen: über die Klassen-Property (Testpfad `transportLimited`,
/// geparkte `floodplainAggradation`, Pinsel-Trichter `applyDelta`/
/// `applyRegenDelta`), über die Roh-Puffer-Sicht (Hot-Loops, s.
/// `docs/perf-measurements.md` §I), über die Ziel-Fassung `erodeCellTo`
/// (Auslass-Inzision — sie setzt die Zielhöhe EXAKT, s. unten) und direkt
/// (Tropfenschleife `Hydraulic.erode`, mit ihrer strengeren Maske aus Eis
/// und Gürtelbett). Bis #96 trugen die Auslass-Inzision, die Tropfenschleife
/// und der Pinsel je eine eigene Kopie der Zerlegung; das Eis-Gate stand
/// zusätzlich in der Gate-Kette der Inzision und in der Tropfenschleife.
///
/// Was dieser Wächter deshalb prüft:
///
/// 1. **Die Regel selbst** (`testFunnelRuleHoldsInBothCallShapes`) — der
///    tragende Teil. Ein neu ausgeschriebener oder verrutschter Funnel fällt
///    hier auf, egal auf welchem Weg.
/// 2. **Parität der Aufruf-Wege** — solange Property und Bed-Fassung über
///    dieselbe Regel laufen, kann sie nicht brechen; sie ist der Wächter
///    gegen das WIEDERAUFTRENNEN (belegt beim Bau von #81).
/// 3. **Die Ziel-Fassung** — sie darf NICHT par mit der Betrags-Fassung sein:
///    `h − fl(h − target)` ist nicht bit-gleich zu `target` (der Rundtrip
///    weicht im aggressiven Regime um 1 ulp ab, beobachtet an rund 29 % von
///    20 Mio. Stichproben über die Wertebereiche der Inzisionsformel).
///    Genau deshalb existiert sie — und genau das pinnt
///    `testTargetFasciaRoundtripIsNotBitIdentical` mit einem konkreten Paar.
/// 4. **Alle Schreiber** — Auslass-Inzision, Tropfenschleife und Pinsel
///    schreiben nach #96 ausschließlich über den Funnel. Das prüfen
///    Verhaltens-Tests (Pinsel unter Eis) und Quelltext-Proben (keine
///    ausgeschriebene Zerlegung mehr in `outletIncision`, `Hydraulic.erode`,
///    `applyDelta`, `applyRegenDelta`).
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
    ///
    /// `Sendable` (Issue #201): die statischen Tabellen-Einträge sind globales
    /// `let`; die Closures sind zustandslos (`@Sendable`, sie rufen nur Methoden
    /// ihres Arguments) — die Konformität ist vollständig geprüft.
    private struct CallShape: Sendable {
        let name: String
        let erode: @Sendable (Terrain, Int, Double) -> Double
        let deposit: @Sendable (Terrain, Int, Double) -> Double
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
                             _ op: KeyPath<CallShape, @Sendable (Terrain, Int, Double) -> Double>,
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
    /// `simperf --hash` fährt `SimConfig()` — den Produktionspfad. Seit #96
    /// ruft der die Bed-Regel direkt (Auslass-Inzision über die Ziel-Fassung,
    /// Tropfen über `Terrain.Bed`), der Fingerprint deckt sie also ab. Die
    /// PROPERTY-Fassung erreichen ihre zwei Aufrufer weiterhin nur außerhalb
    /// der Produktion — und das sind ZWEI, nicht eine: `floodplainAggradation`
    /// hängt an `floodplainEnabled`, steht aber INNERHALB des
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
    /// Vorher/Nachher-Werte dieses Umbaus: `docs/perf-measurements.md` §K;
    /// die Umbau-Belege von #96 (Auslass-Inzision, Tropfen, Pinsel) stehen im
    /// PR zu Issue #96.
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

    // MARK: - Ziel-Fassung (Auslass-Inzision, Issue #96)

    /// Die Ziel-Fassung trägt dieselbe Regel und dasselbe Gate — aber sie
    /// schreibt die ZIELHÖHE exakt statt `h −= (h − target)`. Das ist kein
    /// Stil-Entscheid, sondern Bit-Identität: der Rundtrip
    /// `h − fl(h − target)` ist im aggressiven Regime der Auslass-Inzision
    /// (Abtrag über die halbe Höhe — große Becken-Auslässe mit weit unten
    /// liegendem Empfänger) NICHT gleich `target`. Dieses Paar hier ist das
    /// konkrete Gegenbeispiel (beobachtet an rund 29 % von 20 Mio. Stichproben
    /// über die Wertebereiche der Inzisionsformel — die Mehrheit der Fälle mit
    /// `target < h/2` weicht um 1 ulp ab):
    ///
    ///     h = 1.3, target = 0.3
    ///     delta     = fl(1.3 − 0.3) = 1.0            (exakt)
    ///     h − delta = fl(1.3 − 1.0) = 0.30000000000000004   ≠ target
    ///
    /// Wer die Ziel-Fassung zu `erodeCell(k, h − target)` „vereinfacht",
    /// ändert die Auslass-Inzision an genau diesen Zellen messbar — dieser
    /// Test hält das Paar fest, und der Verhaltens-Test daneben prüft, dass
    /// die Fassung die Zielhöhe wirklich exakt setzt.
    func testTargetFasciaRoundtripIsNotBitIdentical() {
        let h = 1.3, target = 0.3
        let delta = h - target
        let roundtrip = h - delta
        XCTAssertNotEqual(roundtrip.bitPattern, target.bitPattern,
                          "Das Rundrip-Gegenbeispiel ist eingetroffen — es braucht ein neues, "
                          + "die Ziel-Fassung erhebt dann keinen Bit-Identitäts-Anspruch mehr")
        XCTAssertEqual(delta, 1.0, "Testaufbau: delta ist nicht mehr exakt 1.0")
    }

    /// Die Ziel-Fassung im Verhalten: senkt auf die Zielhöhe EXAKT ab (bit-gleich
    /// zu `target`, nicht `h − (h − target)`), zieht die Zerlegung über den
    /// Rundtrip-Betrag `a = fl(h − target)` (erst Sediment, dann Fels — genau
    /// der Wert, den auch die alte Ausschreibung in der Auslass-Inzision als
    /// `delta` berechnete) und respektiert das Gletscher-Gate.
    func testTargetFasciaSetsTargetExactly() {
        let c = cfg()
        let t = Terrain(config: c, seed: 4711)
        fillSyntheticBed(t, withIce: true)
        let ice = t.underIce
        var lowered = 0
        for k in 0..<c.count {
            let amount = amounts[k % amounts.count]
            let before = t.h[k], sed0 = t.sed[k], rock0 = t.rock[k]
            let want = max(0, amount)
            let target = before - want
            // Der Betrag, den die Fassung tatsächlich abträgt: der Rundtrip
            // `fl(h − target)` — NICHT `want` (genau diese Rundung ist der
            // Grund, warum es die Ziel-Fassung überhaupt gibt).
            let a = before - target
            let moved = t.erodeCellToViaBedForTests(k, target)
            if ice[k] || a <= 0 {
                XCTAssertEqual(moved, 0, "Zelle \(k): ohne Abtrag bewegt")
                XCTAssertEqual(t.h[k].bitPattern, before.bitPattern,
                               "Zelle \(k): Ziel-Fassung hat h verändert, ohne abzutragen")
                XCTAssertEqual(t.sed[k], sed0, "Zelle \(k): Sediment ohne Abtrag bewegt")
                XCTAssertEqual(t.rock[k], rock0, "Zelle \(k): Fels ohne Abtrag bewegt")
                continue
            }
            lowered += 1
            XCTAssertEqual(moved.bitPattern, a.bitPattern,
                           "Zelle \(k): Rückgabe ≠ Rundtrip-Betrag")
            // Die EXAKTE Zielhöhe — nicht der Rundtrip h − (h − target).
            XCTAssertEqual(t.h[k].bitPattern, target.bitPattern,
                           "Zelle \(k): h steht nicht bit-gleich auf der Zielhöhe")
            XCTAssertEqual(t.sed[k], max(0, sed0 - a), accuracy: 1e-15,
                           "Zelle \(k): Sediment nicht zuerst abgetragen")
            XCTAssertEqual(t.rock[k], rock0 - max(0, a - sed0), accuracy: 1e-15,
                           "Zelle \(k): Fels statt Sediment angegriffen")
            XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                           "Zelle \(k): h ≠ rock + sed nach Abtrag")
        }
        XCTAssertGreaterThan(lowered, c.count / 4, "Testaufbau: der Wächter hat kaum gesenkt")
    }

    // MARK: - Fels-Hebung (Pinsel, Issue #96)

    /// Die dritte Funnel-Bewegung (`raiseRockCell`, gebraucht vom Pinsel):
    /// hebt GESTEIN, nie Sediment, hält `h = rock + sed` und trägt dasselbe
    /// Gletscher-Gate wie der Abtrag.
    func testRaiseRockLiftsRockUnderTheFunnelGate() {
        let c = cfg()
        let t = Terrain(config: c, seed: 4711)
        fillSyntheticBed(t, withIce: true)
        let ice = t.underIce
        let sed0 = t.sed, rock0 = t.rock
        var raised = 0
        for k in 0..<c.count {
            let amount = amounts[k % amounts.count]
            let want = max(0, amount)
            let moved = t.raiseRockCellViaBedForTests(k, amount)
            if ice[k] || want == 0 {
                XCTAssertEqual(moved, 0, "Zelle \(k): ohne Hebung bewegt")
                XCTAssertEqual(t.sed[k], sed0[k], "Zelle \(k): Sediment bewegt")
                XCTAssertEqual(t.rock[k], rock0[k], "Zelle \(k): Fels ohne Hebung bewegt")
                continue
            }
            raised += 1
            XCTAssertEqual(moved, want, "Zelle \(k): Rückgabe ≠ Betrag")
            XCTAssertEqual(t.rock[k], rock0[k] + want, accuracy: 1e-15,
                           "Zelle \(k): Fels nicht um den Betrag gehoben")
            XCTAssertEqual(t.sed[k], sed0[k], "Zelle \(k): Hebung hat Sediment verändert")
            XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-12,
                           "Zelle \(k): h ≠ rock + sed nach Hebung")
        }
        XCTAssertGreaterThan(raised, c.count / 4, "Testaufbau: der Wächter hat kaum gehoben")
    }

    // MARK: - Pinsel unter Eis (Issue #96)

    /// Der Pinsel schreibt über den Funnel — also trägt er jetzt auch das
    /// Gletscher-Gate: JEDER Werkzeug-Hieb lässt das Bett unter Eis unberührt
    /// (h/sed/rock bit-gleich), während eisfreie Zellen im selben Strich
    /// normal arbeiten. Vor #96 schrieb der Pinsel sein Bett selbst, ohne
    /// jedes Gate. `regenerateDisturbed` erbt dasselbe: sein Trichter
    /// `applyRegenDelta` läuft über den Funnel.
    func testBrushLeavesTheBedUnderIceUntouched() {
        for tool in BrushTool.allCases {
            let c = cfg()
            let t = Terrain(config: c, seed: 4711)
            fillSyntheticBed(t, withIce: true)
            let h0 = t.h, sed0 = t.sed, rock0 = t.rock
            let ice = t.underIce
            // Strich über den Ursprung: Radius 4 Zellen deckt eisfreie UND
            // vergletscherte Zellen (Eis liegt auf jeder dritten).
            tool.apply(to: t, gx: 1, gz: 1, radiusWorld: 4 * c.cellSize,
                       strength: 1.0, target: h0[0])
            var touchedIce = 0, touchedFree = 0
            for k in 0..<c.count {
                let changed = t.h[k].bitPattern != h0[k].bitPattern
                    || t.sed[k].bitPattern != sed0[k].bitPattern
                    || t.rock[k].bitPattern != rock0[k].bitPattern
                if ice[k] {
                    XCTAssertFalse(changed, "\(tool): Bett unter Eis verändert (Zelle \(k))")
                    if changed { touchedIce += 1 }
                } else if changed {
                    touchedFree += 1
                }
            }
            XCTAssertGreaterThan(touchedFree, 0,
                                 "\(tool): Testaufbau — der Strich hat keine eisfreie Zelle berührt")
            XCTAssertEqual(touchedIce, 0, "\(tool): \(touchedIce) vergletscherte Zellen verändert")
        }
    }

    // MARK: - Alle Schreiber über den Funnel (Issue #96)

    /// Quelltext-Wächter: die drei ehemaligen Kopie-Halter schreiben
    /// ausschließlich über den Funnel — keine ausgeschriebene Zerlegung mehr,
    /// kein zweites Eis-Gate. Gematcht wird auf der Code-Sicht
    /// (`SourceProbe.swiftMethods()`, Kommentare/Strings entfernt), eine
    /// auskommentierte Zeile erfüllt keinen Vertrag.
    func testEveryBedWriterUsesTheFunnel() throws {
        let terrain = try RepoSource.probe("SimCore/Sources/SimCore/Terrain.swift")
        // Erster Treffer statt Dictionary: Überladungen mit gleichem Namen
        // (z. B. `macroSlope`) gäben sonst doppelte Schlüssel.
        func body(of name: String) throws -> String {
            let method = try XCTUnwrap(terrain.swiftMethods().first { $0.name == name },
                                       "\(name) ist keine Methode auf Einrückungsebene 4 mehr")
            return method.body
        }

        // 1) Auslass-Inzision: Ziel-Fassung statt Split, kein eigenes Eis-Gate
        //    mehr in der Gate-Kette (das Gate trägt der Funnel).
        let incision = try body(of: "outletIncision")
        XCTAssertTrue(incision.contains("erodeCellTo("),
                      "Auslass-Inzision schreibt nicht über die Ziel-Fassung des Funnels")
        for forbidden in ["min(delta", "psed", "prock", "iceArr", "underIce"] {
            XCTAssertFalse(incision.contains(forbidden),
                           "Auslass-Inzision trägt noch die ausgeschriebene Kopie: \(forbidden)")
        }

        // 2) Pinsel-Trichter: alle drei Bewegungen über den Funnel.
        let applyDelta = try body(of: "applyDelta")
        for expected in ["raiseRockCell(", "depositCell(", "erodeCell("] {
            XCTAssertTrue(applyDelta.contains(expected),
                          "applyDelta schreibt nicht über den Funnel: \(expected) fehlt")
        }
        for forbidden in ["sed[k]", "rock[k]", "h[k] +="] {
            XCTAssertFalse(applyDelta.contains(forbidden),
                           "applyDelta schreibt das Bett noch selbst: \(forbidden)")
        }

        // 3) Pinsel-Nachzug: Hebung und Abtrag über den Funnel.
        let applyRegenDelta = try body(of: "applyRegenDelta")
        for expected in ["raiseRockCell(", "erodeCell("] {
            XCTAssertTrue(applyRegenDelta.contains(expected),
                          "applyRegenDelta schreibt nicht über den Funnel: \(expected) fehlt")
        }
        for forbidden in ["sed[k] -=", "rock[k] +="] {
            XCTAssertFalse(applyRegenDelta.contains(forbidden),
                           "applyRegenDelta schreibt das Bett noch selbst: \(forbidden)")
        }

        // 4) Tropfenschleife: Bed-Regel mit der stärkeren Maske, keine
        //    ausgeschriebene Zerlegung und kein zweites Gate mehr.
        let droplets = try RepoSource.probe("SimCore/Sources/SimCore/Hydraulic.swift")
        XCTAssertTrue(droplets.contains("Terrain.Bed("),
                      "Tropfenschleife öffnet keine Bett-Sicht für den Funnel-Kern")
        XCTAssertTrue(droplets.contains("bed.erode(") && droplets.contains("bed.deposit("),
                      "Tropfenschleife schreibt nicht über die Bed-Regel")
        for forbidden in ["psed[k] -=", "prock[k] -=", "psed[k] +=", "iceOn && pice"] {
            XCTAssertFalse(droplets.contains(forbidden),
                           "Tropfenschleife trägt noch die ausgeschriebene Kopie: \(forbidden)")
        }
    }

    /// Der Funnel BENENT seine zwei Ausnahmen (Hangdiffusion, Brandung) mit
    /// Messreihe, statt dass sie die Regel nachbauen. Das steht im Doc-Kommentar
    /// — der auf der Code-Sicht gestrippt ist, deshalb Probe auf `raw`.
    func testFunnelNamesItsTwoExceptions() throws {
        let terrain = try RepoSource.probe("SimCore/Sources/SimCore/Terrain.swift")
        XCTAssertTrue(terrain.raw.contains("Die zwei begründeten Ausnahmen"),
                      "Der Funnel benennt seine Ausnahmen nicht mehr — entweder fehlt die "
                      + "Benennung am Funnel, oder der Formulierungs-Wächter hier braucht Mitzug")
        XCTAssertTrue(terrain.raw.contains("hillslopeDiffusion") && terrain.raw.contains("wavePass"),
                      "Die Ausnahmen heißen nicht mehr hillslopeDiffusion/wavePass — "
                      + "Benennung und Wächter auseinandergezogen")
        XCTAssertTrue(terrain.raw.contains("glacier-measurements.md") && terrain.raw.contains("§I.1"),
                      "Die Messreihe der Ausnahme-Begründung fehlt am Funnel")
    }
}
