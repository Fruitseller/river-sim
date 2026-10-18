import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter zu den „Kästen" im Tiefland (Issue #174, `docs/geometry-water-measurements.md`
/// § H): große Raster-Läufe ohne Band waren gleichbreite, zellgerade Streifen mit
/// stumpfen Enden (Diamant-Dilatation um einen D8/MFD-Pfad). Die Scheibe
/// (`RiverWidening`, `WaterRender` § „Verbreiterung als Scheibe") macht daraus einen
/// Lauf mit Rundung, Breitenschwankung, Mäander-Wiegen und spitzem Kopf.
///
/// Alle Proben führen den echten Renderer (`WaterFieldRenderer.bytes`) auf einer
/// Kunstwelt aus (ebenes Land, ein Lauf in einer Zeile) und messen die SICHTBARE Form
/// (R-Kanal ab `riverMaskLo`) — nicht die Zwischenfelder. Der alte Arm
/// (`legacyWiden`) läuft jeweils als Gegenprobe: er zeigt, dass das Maß den Kasten
/// erkennt und nicht nur den neuen Lauf lobt.
final class RiverWideningTests: XCTestCase {

    private let n = 112, row = 56, x0 = 6, x1 = 104

    /// Ebene auf 0,3 mit einem Lauf in Zeile `row` von `x0` bis `x1` (D8 von links nach
    /// rechts). `discharge` in Vielfachen von `renderMinCells`: 20 = kräftiger
    /// Hauptlauf (Intensität 1), 1,3 = Lauf knapp über der Verbreiterungs-Schwelle.
    /// `wallRow`: ab dieser Zeile steht eine 0,1 hohe Wand (Bank-Schranke).
    private func world(discharge: Double, wallRow: Int? = nil, rows: [Int]? = nil) -> Terrain {
        let config = renderConfig(n: n)
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        let cellArea = config.cellSize * config.cellSize
        for k in 0..<(n * n) {
            state.h[k] = 0.3
            state.receiver[k] = -1
            state.area[k] = 0
            state.areaMFD[k] = 0
            state.streamMap[k] = 0
        }
        if let wallRow {
            for j in wallRow..<n { for i in 0..<n { state.h[j * n + i] = 0.4 } }
        }
        for r in rows ?? [row] {
            for i in x0...x1 {
                let k = r * n + i
                state.areaMFD[k] = discharge * config.renderMinCells * cellArea
                state.area[k] = state.areaMFD[k]
                state.streamMap[k] = 1
                if i < x1 { state.receiver[k] = Int32(k + 1) }
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    private func render(_ terrain: Terrain, legacy: Bool) -> [UInt8] {
        let field = WaterFieldRenderer()
        field.legacyWiden = legacy
        return field.bytes(terrain, blend: 1, geometryMode: true,
                           bandChannelFlags: [], bandCoverage: [], deferTail: true)
    }

    private func visible(_ bytes: [UInt8], _ i: Int, _ j: Int) -> Bool {
        bytes[(j * n + i) * 4] >= byte01(WaterRender.riverMaskLo)
    }

    /// Deckend sichtbar: Fluss-Maske des Shaders ab der Hälfte (Mitte des Fensters
    /// `riverMaskLo…riverMaskHi`), nicht erst am Fuß.
    private func solid(_ bytes: [UInt8], _ i: Int, _ j: Int) -> Bool {
        bytes[(j * n + i) * 4] >= byte01(0.5 * (WaterRender.riverMaskLo + WaterRender.riverMaskHi))
    }

    private struct Shape {
        /// Sichtbare Zellen je Spalte.
        var widths: [Double] = []
        /// Mittlere Zeile der sichtbaren Zellen je Spalte.
        var centers: [Double] = []
    }

    /// Breite und Lage der Mittellinie je Spalte über `columns`.
    private func shape(_ bytes: [UInt8], columns: ClosedRange<Int>) -> Shape {
        var out = Shape()
        for i in columns {
            var count = 0.0, sum = 0.0
            for j in 0..<n where visible(bytes, i, j) { count += 1; sum += Double(j) }
            out.widths.append(count)
            out.centers.append(count > 0 ? sum / count : Double(row))
        }
        return out
    }

    private func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
    private func deviation(_ a: [Double]) -> Double {
        let m = mean(a)
        return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(a.count, 1))).squareRoot()
    }

    // MARK: Der Kasten und seine Auflösung

    /// Gegenprobe: die alte Dilatation macht aus einem Lauf einen Streifen, dessen Breite
    /// und Mittellinie sich nirgends ändern. Das ist der „Kasten".
    func testDiamondDilationDrawsAUniformStraightStrip() {
        let s = shape(render(world(discharge: 20), legacy: true), columns: 20...90)
        XCTAssertEqual(deviation(s.widths), 0, accuracy: 0.001, "alt: Breite konstant")
        XCTAssertEqual(deviation(s.centers), 0, accuracy: 0.001, "alt: Mittellinie gerade")
    }

    /// Der Lauf schwankt in der Breite, schlängelt sich unter einer Zelle bis zu
    /// einigen Zellen und bleibt dabei zusammenhängend und in der Größe des alten
    /// Laufs (kein Wasser geht verloren, keiner wird zum See).
    func testDiscWideningVariesWidthAndWandersWithoutLosingWater() {
        let terrain = world(discharge: 20)
        let new = shape(render(terrain, legacy: false), columns: 20...90)
        let old = shape(render(terrain, legacy: true), columns: 20...90)
        XCTAssertGreaterThan(deviation(new.widths) / mean(new.widths), 0.08, "Breitenschwankung")
        XCTAssertGreaterThan(deviation(new.centers), 0.5, "Mäander-Wiegen")
        XCTAssertGreaterThan(mean(new.widths), 0.8 * mean(old.widths), "nicht schmaler als zuvor")
        XCTAssertLessThan(mean(new.widths), 1.3 * mean(old.widths), "nicht breiter als zuvor")
        XCTAssertGreaterThanOrEqual(new.widths.min() ?? 0, 1, "kein Abriss: in jeder Spalte Wasser")
        // Die Mittellinie bleibt am Bett: das Wiegen reicht nur einige Zellen weit.
        XCTAssertLessThan((new.centers.map { abs($0 - Double(row)) }.max() ?? 0), 4)
    }

    /// Ein Lauf beginnt spitz: hinter dem Kopf ist er schmaler als in der Mitte (vorher
    /// stand dort ein stumpfer Kasten in voller Breite).
    func testRunStartsPointedInsteadOfBluntBox() {
        let terrain = world(discharge: 20)
        let new = shape(render(terrain, legacy: false), columns: x0...(x0 + 40))
        let old = shape(render(terrain, legacy: true), columns: x0...(x0 + 40))
        let head = mean(Array(new.widths[0...1])), middle = mean(Array(new.widths[25...40]))
        XCTAssertLessThan(head, 0.75 * middle, "neu: spitzer Kopf")
        let oldHead = mean(Array(old.widths[0...1])), oldMiddle = mean(Array(old.widths[25...40]))
        XCTAssertGreaterThan(oldHead, 0.9 * oldMiddle, "alt: stumpfer Kopf")
    }

    /// Ein schwacher Lauf knapp über der Schwelle bleibt mindestens so breit wie bisher
    /// — die Kohärenz-Maske zählt Zellen (`WaterRender.streamGateCells`), und ein
    /// schmalerer Lauf riss als Ganzes ab, sobald seine Komponente darunter fiel
    /// (gemessen: der Küstenbach in Seed 1337, `docs/geometry-water-measurements.md` § H).
    func testWeakRunKeepsItsWidthAndStaysVisible() {
        let terrain = world(discharge: 1.3)
        let new = render(terrain, legacy: false)
        let old = render(terrain, legacy: true)
        func cells(_ b: [UInt8]) -> Int { (0..<(n * n)).filter { b[$0 * 4] >= byte01(WaterRender.riverMaskLo) }.count }
        XCTAssertGreaterThanOrEqual(cells(old), WaterRender.streamGateCells, "Aufbau: der alte Lauf ist sichtbar")
        XCTAssertGreaterThanOrEqual(cells(new), cells(old) * 9 / 10, "neu mindestens so breit wie alt")
        for i in (x0 + 2)...(x1 - 2) { XCTAssertTrue(visible(new, i, row), "Lücke im Lauf an Spalte \(i)") }
    }

    /// Flächenabfluss (viele parallele Linien dicht nebeneinander) verschmolz mit der alten
    /// Dilatation zu EINER dunklen Fläche, die über den äußersten Strang hinausquoll. Die
    /// Dichte-Regel hält den Rand am Strang: über der äußersten Linie eines dichten Bündels
    /// steht weniger deckendes Wasser als über einem einzelnen Lauf.
    func testDenseSheetDoesNotBleedPastItsOutermostStrand() {
        func overhang(_ rows: [Int], top: Int, legacy: Bool) -> Double {
            let b = render(world(discharge: 20, rows: rows), legacy: legacy)
            var sum = 0.0
            for i in 30...80 {
                var k = 0
                while top - 1 - k >= 0 && solid(b, i, top - 1 - k) { k += 1 }
                sum += Double(k)
            }
            return sum / 51
        }
        let top = row - 8
        let sheet = Array(top...(row + 8))
        let lone = overhang([top], top: top, legacy: false)
        let dense = overhang(sheet, top: top, legacy: false)
        XCTAssertGreaterThan(lone, 0.5, "Aufbau: ein einzelner Lauf quillt über seine Linie hinaus")
        XCTAssertLessThan(dense, 0.8 * lone, "dichtes Bündel: Rand bleibt näher am Strang")
        // Der alte Arm kannte die Regel nicht: gleicher Überstand mit und ohne Nachbarn.
        XCTAssertEqual(overhang(sheet, top: top, legacy: true), overhang([top], top: top, legacy: true), accuracy: 0.001)
    }

    /// Die Bank-Schranke gilt weiter: neben einer Wand malt der Lauf nicht die Wand hinauf.
    func testWideningStopsAtAWall() {
        let wall = row + 2
        let bytes = render(world(discharge: 20, wallRow: wall), legacy: false)
        for j in wall..<n {
            for i in 0..<n {
                XCTAssertFalse(visible(bytes, i, j), "Wasser an der Wand (\(i), \(j))")
            }
        }
        XCTAssertTrue(visible(bytes, 50, row), "Aufbau: der Lauf selbst bleibt")
    }

    // MARK: Eigenschaften des Stempels

    /// Der Stempel schreibt per Maximum: er nimmt einer Zelle nie Intensität (keine
    /// Linie wird dünner als vorher), und dieselbe Eingabe gibt dieselben Bytes.
    func testWideningNeverLowersAndIsDeterministic() {
        let terrain = world(discharge: 20)
        var sd = [Double](repeating: 0, count: n * n)
        for i in x0...x1 { sd[row * n + i] = WaterRender.streamIntensity(
            dischargeCells: 20 * terrain.cfg.renderMinCells, creekCells: terrain.cfg.renderMinCells) }
        var a = sd, b = sd
        RiverWidening.widen(sd, into: &a, h: terrain.h, hf: terrain.waterLevel, receiver: terrain.receiver, n: n)
        RiverWidening.widen(sd, into: &b, h: terrain.h, hf: terrain.waterLevel, receiver: terrain.receiver, n: n)
        XCTAssertEqual(a, b)
        for k in 0..<(n * n) { XCTAssertGreaterThanOrEqual(a[k], sd[k]) }
        XCTAssertEqual(render(terrain, legacy: false), render(terrain, legacy: false))
    }

    // MARK: Kalibrier-Vertrag (WaterRender)

    func testWidenRadiusKeepsTheOldHierarchy() {
        let t0 = WaterRender.widenThresholds[0]
        XCTAssertEqual(WaterRender.widenRadius(intensity: t0), 0, "Bäche unter der Schwelle bleiben dünn")
        XCTAssertEqual(WaterRender.widenRadius(intensity: t0 + 1e-9),
                       WaterRender.widenRadiusAtFirstThreshold, accuracy: 1e-6)
        XCTAssertEqual(WaterRender.widenRadius(intensity: 1), WaterRender.widenRadiusFull, accuracy: 1e-9)
        var last = 0.0
        for step in 0...100 {
            let r = WaterRender.widenRadius(intensity: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(r, last, "monoton bei \(step) %")
            last = r
        }
        // Schwache Läufe nicht schmaler als der alte Pass 1 (eine Zelle), kräftige nicht
        // breiter als der alte Pass 2 (zwei Zellen).
        XCTAssertGreaterThanOrEqual(WaterRender.widenRadiusAtFirstThreshold, 1)
        XCTAssertLessThanOrEqual(WaterRender.widenRadiusFull, 2)
    }

    func testHeadTaperAndCrowdFactorAreMonotone() {
        var last = 0.0
        for u in 0...(WaterRender.widenHeadTaperCells + 3) {
            let f = WaterRender.widenHeadTaper(upstreamCells: u)
            XCTAssertGreaterThanOrEqual(f, last)
            XCTAssertGreaterThan(f, 0, "am Kopf reißt die Linie nicht ab")
            last = f
        }
        XCTAssertEqual(WaterRender.widenHeadTaper(upstreamCells: WaterRender.widenHeadTaperCells), 1, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.widenCrowdFactor(share: 0), 1)
        XCTAssertEqual(WaterRender.widenCrowdFactor(share: 1), WaterRender.widenCrowdMinimum, accuracy: 1e-12)
        var previous = 1.0
        for step in 0...20 {
            let f = WaterRender.widenCrowdFactor(share: Double(step) / 20)
            XCTAssertLessThanOrEqual(f, previous)
            previous = f
        }
        XCTAssertLessThan(WaterRender.widenCrowdLo, WaterRender.widenCrowdHi)
    }
}
