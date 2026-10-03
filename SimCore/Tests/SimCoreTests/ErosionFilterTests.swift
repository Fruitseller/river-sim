import XCTest
@testable import SimCore

/// Tests für den nicht-simulierten Pre-Erosionsfilter (`ErosionFilter.swift`).
final class ErosionFilterTests: XCTestCase {

    /// Determinismus: Wiederholte Aufrufe mit identischen Parametern müssen
    /// bit-identische Deltas liefern.
    func testErosionFilterDeterminism() {
        let p = ErosionFilter.Params()
        let res1 = ErosionFilter.evaluate(px: 0.25, py: 0.75, h: 0.5, sx: 0.02, sy: -0.01,
                                          fadeTarget: 0.1, p: p)
        let res2 = ErosionFilter.evaluate(px: 0.25, py: 0.75, h: 0.5, sx: 0.02, sy: -0.01,
                                          fadeTarget: 0.1, p: p)

        XCTAssertEqual(res1.dh, res2.dh)
        XCTAssertEqual(res1.dsx, res2.dsx)
        XCTAssertEqual(res1.dsy, res2.dsy)
        XCTAssertEqual(res1.magnitude, res2.magnitude)
        XCTAssertEqual(res1.ridgeMap, res2.ridgeMap)

        let n = 8
        var h1 = (0..<(n * n)).map { Double($0) * 0.01 }
        var h2 = h1
        ErosionFilter.apply(h: &h1, n: n, sea: 0.1, seedOffsetX: 1.0, seedOffsetY: 2.0, params: p)
        ErosionFilter.apply(h: &h2, n: n, sea: 0.1, seedOffsetX: 1.0, seedOffsetY: 2.0, params: p)
        XCTAssertEqual(h1, h2, "apply muss deterministisch sein")
    }

    /// Leere oder degenerierte Gitter (n <= 1) sowie nicht-endliche Meereshöhen
    /// dürfen zu keinem Absturz führen und belassen das Höhenfeld unverändert.
    func testApplyHandlesEmptyAndDegenerateGridsSafely() {
        let p = ErosionFilter.Params()

        var empty: [Double] = []
        ErosionFilter.apply(h: &empty, n: 0, sea: 0.1, seedOffsetX: 0, seedOffsetY: 0, params: p)
        XCTAssertEqual(empty, [])

        var single = [0.42]
        ErosionFilter.apply(h: &single, n: 1, sea: 0.1, seedOffsetX: 0, seedOffsetY: 0, params: p)
        XCTAssertEqual(single, [0.42], "n = 1 darf Höhenfeld nicht verändern")

        let n = 4
        var valid = [Double](repeating: 0.5, count: n * n)
        let before = valid
        ErosionFilter.apply(h: &valid, n: n, sea: Double.nan, seedOffsetX: 0, seedOffsetY: 0, params: p)
        XCTAssertEqual(valid, before, "Nicht-endliche Meereshöhe muss No-op sein")

        ErosionFilter.apply(h: &valid, n: n, sea: Double.infinity, seedOffsetX: 0, seedOffsetY: 0, params: p)
        XCTAssertEqual(valid, before, "Unendliche Meereshöhe muss No-op sein")
    }

    /// Nicht-endliche Koordinaten oder Steigungen sowie ungültige Skalierungs-
    /// Parameter liefern defensiv Nullen statt NaN oder Division durch 0.
    func testEvaluateHandlesNonFiniteAndInvalidParametersSafely() {
        var p = ErosionFilter.Params()

        let nanCoord = ErosionFilter.evaluate(px: .nan, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(nanCoord.dh, 0)
        XCTAssertEqual(nanCoord.magnitude, 0)

        let infCoord = ErosionFilter.evaluate(px: 0, py: .infinity, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(infCoord.dh, 0)

        let nanSlope = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: .nan, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(nanSlope.dh, 0)

        p.scale = 0
        let zeroScale = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(zeroScale.dh, 0)

        p.scale = -1.0
        let negScale = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(negScale.dh, 0)

        p.scale = 0.06
        p.cellScale = 0
        let zeroCellScale = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(zeroCellScale.dh, 0)

        p.cellScale = 0.7
        p.octaves = 0
        let zeroOctaves = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(zeroOctaves.dh, 0)

        p.octaves = -3
        let negOctaves = ErosionFilter.evaluate(px: 0, py: 0, h: 0.5, sx: 0, sy: 0, fadeTarget: 0, p: p)
        XCTAssertEqual(negOctaves.dh, 0)

        // scale * cellScale unterläuft auf 0 -> freq = inf darf kein NaN erzeugen
        p = ErosionFilter.Params()
        p.scale = 1e-300
        p.cellScale = 1e-300
        let underflow = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p)
        XCTAssertEqual(underflow.dh, 0)
        XCTAssertEqual(underflow.dsx, 0)
        XCTAssertEqual(underflow.dsy, 0)
        XCTAssertEqual(underflow.magnitude, 0)
        XCTAssertEqual(underflow.ridgeMap, 0)

        // Nicht-endliche skalare Parameter
        p = ErosionFilter.Params()
        p.strength = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.gain = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.lacunarity = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.normalization = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.gullyWeight = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.detail = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        // Nicht-endliche Tupel-Parameter
        p = ErosionFilter.Params()
        p.rounding.0 = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.onset.2 = .infinity
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)

        p = ErosionFilter.Params()
        p.assumedSlope.1 = .nan
        XCTAssertEqual(ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p).dh, 0)
    }

    /// Endliche, aber extreme Parameter passieren `Params.isValid` und laufen
    /// erst in die Netze INNERHALB von `evaluate`: Stärke-Überlauf vor der
    /// Schleife, Oktaven-Abbruch bei unendlicher Frequenz, Ausgangsprüfung.
    func testEvaluateOverflowGuardsInsideTheFilter() {
        // strength * scale läuft auf inf über -> Null-Deltas vor der Schleife.
        var p = ErosionFilter.Params()
        p.strength = 1e308
        p.scale = 2
        XCTAssertTrue(p.isValid)
        let strengthOverflow = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p)
        XCTAssertEqual(strengthOverflow.dh, 0)
        XCTAssertEqual(strengthOverflow.magnitude, 0)

        // freq wird nach der ersten Oktave unendlich -> Abbruch; das Ergebnis
        // ist damit exakt das einer einzigen Oktave und bleibt endlich.
        p = ErosionFilter.Params()
        p.lacunarity = .greatestFiniteMagnitude
        XCTAssertTrue(p.isValid)
        let broken = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p)
        p.octaves = 1
        let single = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p)
        XCTAssertTrue(broken.dh.isFinite && broken.dsx.isFinite && broken.dsy.isFinite)
        XCTAssertEqual(broken.magnitude, single.magnitude)
        XCTAssertEqual(broken.dh, single.dh)
        XCTAssertEqual(broken.dsx, single.dsx)
        XCTAssertEqual(broken.dsy, single.dsy)
        XCTAssertEqual(broken.ridgeMap, single.ridgeMap)

        // strength0 bleibt endlich, die Summe über die Oktaven nicht ->
        // die Ausgangsprüfung fällt auf Null-Deltas zurück.
        p = ErosionFilter.Params()
        p.strength = .greatestFiniteMagnitude
        p.scale = 1
        XCTAssertTrue(p.isValid)
        let sumOverflow = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01, fadeTarget: 0, p: p)
        XCTAssertEqual(sumOverflow.dh, 0)
        XCTAssertEqual(sumOverflow.dsx, 0)
        XCTAssertEqual(sumOverflow.dsy, 0)
        XCTAssertEqual(sumOverflow.magnitude, 0)
        XCTAssertEqual(sumOverflow.ridgeMap, 0)
    }

    /// NaN-Werte in fadeTarget werden über die Klemme `min(1, max(-1, ...))`
    /// sicher auf -1 gefaltet und führen zu keinen NaN-Rückgabewerten.
    func testFadeTargetClampOrderHandlesNanSafely() {
        let p = ErosionFilter.Params()
        let result = ErosionFilter.evaluate(px: 0.5, py: 0.5, h: 0.5, sx: 0.01, sy: 0.01,
                                            fadeTarget: Double.nan, p: p)
        XCTAssertTrue(result.dh.isFinite, "dh muss endlich sein")
        XCTAssertTrue(result.dsx.isFinite, "dsx muss endlich sein")
        XCTAssertTrue(result.dsy.isFinite, "dsy muss endlich sein")
        XCTAssertTrue(result.magnitude.isFinite, "magnitude muss endlich sein")
        XCTAssertTrue(result.ridgeMap.isFinite, "ridgeMap muss endlich sein")
    }

    /// Nicht-endliche Höhenwerte im Eingangsfeld führen bei `apply` zu keinem Abbruch
    /// und vergiften benachbarte endliche Zellen nicht (Nicht-Kontagion).
    func testApplyWithNonFiniteHeightsDoesNotTrap() {
        let n = 4
        var h = [Double](repeating: 0.5, count: n * n)
        h[3] = Double.nan
        h[7] = Double.infinity
        let p = ErosionFilter.Params()

        ErosionFilter.apply(h: &h, n: n, sea: 0.1, seedOffsetX: 0, seedOffsetY: 0, params: p)
        XCTAssertEqual(h.count, n * n)
        XCTAssertTrue(h[3].isNaN, "NaN-Zelle muss NaN bleiben")
        XCTAssertEqual(h[7], Double.infinity, "inf-Zelle muss unendlich bleiben")
        for k in 0..<(n * n) where k != 3 && k != 7 {
            XCTAssertTrue(h[k].isFinite, "Endliche Nachbarzelle \(k) darf nicht vergiftet werden")
        }
    }
}
