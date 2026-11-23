import XCTest
@testable import SimCore

final class BedFunnelTests: XCTestCase {

    private let n = 32

    private func cfg() -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

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

    private func fillSyntheticBed(_ t: Terrain, withIce: Bool) {
        let count = n * n
        var sed = [Double](repeating: 0, count: count)
        var rock = [Double](repeating: 0, count: count)
        var h = [Double](repeating: 0, count: count)
        for k in 0..<count {
            sed[k] = Double(k % 5) * 0.037
            rock[k] = 1 + Double(k % 7) * 0.11
            h[k] = rock[k] + sed[k]
        }
        let ice = withIce ? (0..<count).map { $0 % 3 == 0 } : []
        t.setBedForTests(h: h, sed: sed, rock: rock, underIce: ice)
    }

    private let amounts: [Double] = [0, -0.5, 1e-12, 0.02, 0.037, 0.05, 0.148, 0.9, 12.5]

    private func namedFields(_ t: Terrain) -> [(name: String, values: [Double])] {
        [("h", t.h), ("sed", t.sed), ("rock", t.rock)]
    }

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
        XCTAssertGreaterThan(moved, c.count / 4, "\(what): der Wächter hat kaum etwas bewegt")
    }

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

    func testTargetFasciaRoundtripIsNotBitIdentical() {
        let h = 1.3, target = 0.3
        let delta = h - target
        let roundtrip = h - delta
        XCTAssertNotEqual(roundtrip.bitPattern, target.bitPattern,
                          "Das Rundrip-Gegenbeispiel ist eingetroffen — es braucht ein neues, "
                          + "die Ziel-Fassung erhebt dann keinen Bit-Identitäts-Anspruch mehr")
        XCTAssertEqual(delta, 1.0, "Testaufbau: delta ist nicht mehr exakt 1.0")
    }

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

    func testBrushLeavesTheBedUnderIceUntouched() {
        for tool in BrushTool.allCases {
            let c = cfg()
            let t = Terrain(config: c, seed: 4711)
            fillSyntheticBed(t, withIce: true)
            let h0 = t.h, sed0 = t.sed, rock0 = t.rock
            let ice = t.underIce
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

    func testEveryBedWriterUsesTheFunnel() throws {
        let terrain = try RepoSource.probe("SimCore/Sources/SimCore/Terrain.swift")
        func body(of name: String) throws -> String {
            let method = try XCTUnwrap(terrain.swiftMethods().first { $0.name == name },
                                       "\(name) ist keine Methode auf Einrückungsebene 4 mehr")
            return method.body
        }

        let incision = try body(of: "outletIncision")
        XCTAssertTrue(incision.contains("erodeCellTo("),
                      "Auslass-Inzision schreibt nicht über die Ziel-Fassung des Funnels")
        for forbidden in ["min(delta", "psed", "prock", "iceArr", "underIce"] {
            XCTAssertFalse(incision.contains(forbidden),
                           "Auslass-Inzision trägt noch die ausgeschriebene Kopie: \(forbidden)")
        }

        let applyDelta = try body(of: "applyDelta")
        for expected in ["raiseRockCell(", "depositCell(", "erodeCell("] {
            XCTAssertTrue(applyDelta.contains(expected),
                          "applyDelta schreibt nicht über den Funnel: \(expected) fehlt")
        }
        for forbidden in ["sed[k]", "rock[k]", "h[k] +="] {
            XCTAssertFalse(applyDelta.contains(forbidden),
                           "applyDelta schreibt das Bett noch selbst: \(forbidden)")
        }

        let applyRegenDelta = try body(of: "applyRegenDelta")
        for expected in ["raiseRockCell(", "erodeCell("] {
            XCTAssertTrue(applyRegenDelta.contains(expected),
                          "applyRegenDelta schreibt nicht über den Funnel: \(expected) fehlt")
        }
        for forbidden in ["sed[k] -=", "rock[k] +="] {
            XCTAssertFalse(applyRegenDelta.contains(forbidden),
                           "applyRegenDelta schreibt das Bett noch selbst: \(forbidden)")
        }

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
}
