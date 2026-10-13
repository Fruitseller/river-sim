import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für das Render des Mäandergürtels (Issue #174, Paket C Teil 2):
///  - `BarMaterial`: frische Bank = Sand, alternd zurück zur Wiese; Scroll-
///    Rippen folgen den Isolinien des Bankalters und blenden aus, wo sie
///    aliasen würden; Altarme verlanden über Ried zum Vegetationsbogen, auch
///    TROCKENE junge Altarme (ohne Wasserband) zeigen das Ried.
///  - Sand geht in die Materialgewichte (A-Kanal der Makrofarbe, weniger
///    Vegetation) und in die Schutzmaske (kein Wald auf frischen Bänken).
///  - Querprofil im Band: UV2.y trägt die Bogenstärke der Sim, das
///    Prallhang-Ufer ist das tiefe.
///  - Abfluss-Vertrauen: ein kleiner Lauf ohne Stream-Map-Stütze bleibt
///    unsichtbar (die Stütze filtert weiter verwaiste Linien). Im Raster
///    füllt das Vertrauen nur die Lücken des Bands, und unter einem deckenden
///    Band bleibt kein Raster-Wasser stehen, auch am Steilhang (Review #181).
/// Alles reine Render-Ableitung: das Terrain bleibt bit-gleich.
final class BarMaterialTests: XCTestCase {

    /// Flaches Land knapp über dem Meer, ohne Schnee/Eis, mit einem
    /// gesetzten Bankalter-Feld. `age(i, j)` < 0 = keine Bank.
    private func flatWorld(n: Int = 64, age: (Int, Int) -> Double,
                           oxbows: [[MeanderNode]] = [], oxbowAge: [Double] = []) -> Terrain {
        let t = Terrain(config: renderConfig(n: n), seed: 1337)
        var s = t.state
        let sea = t.cfg.sea
        s.h = [Double](repeating: sea + 0.08, count: n * n)
        s.hf = s.h
        s.waterLevel = s.h
        if s.snow.count == n * n { s.snow = [Double](repeating: 0, count: n * n) }
        if s.ice.count == n * n { s.ice = [Double](repeating: 0, count: n * n) }
        s.saltCrust = [Double](repeating: 0, count: n * n)
        // Kein Abfluss, keine Läufe: Wasserfeld und Bänder bleiben leer.
        s.area = [Double](repeating: 0, count: n * n)
        s.areaMFD = [Double](repeating: 0, count: n * n)
        s.streamMap = [Double](repeating: 0, count: n * n)
        s.meanderChannels = []
        s.barAge = (0..<(n * n)).map { age($0 % n, $0 / n) }
        s.oxbows = oxbows
        s.oxbowAge = oxbowAge
        t.restore(s)
        return t
    }

    // MARK: - Sand

    func testFreshBarIsSandAndOldBarIsNot() {
        let n = 64
        let t = flatWorld(n: n) { i, j in
            guard (10..<20).contains(j), (10..<54).contains(i) else { return -1 }
            return i < 32 ? 0 : 20_000
        }
        let f = BarMaterial.field(t)
        XCTAssertEqual(f.sand[15 * n + 20], 1, accuracy: 1e-6, "frische Bank = voller Sand")
        XCTAssertEqual(f.sand[15 * n + 45], 0, "alte Bank trägt keinen Sand mehr")
        XCTAssertEqual(f.sand[40 * n + 20], 0, "ohne Bank kein Sand")
        XCTAssertEqual(WaterRender.barSand(age: -1), 0)
        XCTAssertEqual(WaterRender.barSand(age: WaterRender.barSandYearsLo), 1, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.barSand(age: WaterRender.barSandYearsHi), 0, accuracy: 1e-12)
        var last = 2.0
        for age in stride(from: 0.0, through: 4000, by: 100) {
            let s = WaterRender.barSand(age: age)
            XCTAssertLessThanOrEqual(s, last, "Sand nimmt mit dem Alter nur ab")
            last = s
        }
    }

    func testSingleFreshCellIsNoBar() {
        let n = 64
        let t = flatWorld(n: n) { i, j in i == 30 && j == 30 ? 0 : -1 }
        XCTAssertEqual(BarMaterial.field(t).sand[30 * n + 30], 0,
                       "eine einzelne frisch gestempelte Zelle ist ein Sprenkel, keine Bank")
    }

    func testSandEntersMaterialWeights() {
        let n = 64
        let bar = flatWorld(n: n) { i, j in (10..<20).contains(j) && (10..<30).contains(i) ? 0 : -1 }
        let none = flatWorld(n: n) { _, _ in -1 }
        let a = TerrainColorRenderer.buffers(bar), b = TerrainColorRenderer.buffers(none)
        let k = 15 * n + 20
        XCTAssertGreaterThan(a.colors[k * 4 + 3], 200, "Sand im A-Kanal der Makrofarbe")
        XCTAssertEqual(b.colors[k * 4 + 3], 0)
        XCTAssertLessThan(a.surfaces[k * 4], b.surfaces[k * 4] / 4 + 1,
                          "Sand verdrängt die Vegetation")
        let sum = Int(a.surfaces[k * 4]) + Int(a.surfaces[k * 4 + 1]) + Int(a.surfaces[k * 4 + 2])
        XCTAssertLessThanOrEqual(sum, 256, "Gewichte summieren sich weiter auf höchstens 1")
    }

    func testFreshBarsAreProtectedFromForest() {
        let n = 64
        let t = flatWorld(n: n) { i, j in (10..<20).contains(j) && (10..<30).contains(i) ? 0 : -1 }
        let render = RenderState(geometryMode: true)
        _ = render.waterFieldBytes(t, blend: 1.0)
        let mask = render.protectMaskBytes(t)
        let forest = render.forestMaskBytes(t)
        for j in 11..<19 {
            for i in 11..<29 {
                XCTAssertEqual(mask[j * n + i], 255, "frische Bank (\(i),\(j)) ist geschützt")
                XCTAssertEqual(forest[j * n + i], 0, "kein Wald auf frischer Bank")
            }
        }
        XCTAssertEqual(mask[40 * n + 40], 0, "trockenes Land ohne Bank bleibt frei")
    }

    // MARK: - Scroll-Bars

    func testScrollRipplesFollowAgeIsolines() {
        let n = 96
        let step = 120.0  // Jahre je Zelle → Rippenabstand 400/120 ≈ 3,3 Zellen
        let t = flatWorld(n: n) { i, j in
            (10..<80).contains(j) && (5..<90).contains(i) ? 4000 + step * Double(i) : -1
        }
        let f = BarMaterial.field(t)
        // Entlang einer Isolinie (gleiches i) überall dieselbe Rippe …
        for i in 20..<70 {
            let ref = f.vegShift[40 * n + i]
            for j in 20..<70 { XCTAssertEqual(f.vegShift[j * n + i], ref, accuracy: 1e-6) }
        }
        // … quer dazu wechseln Rücken und Senke mit der Periode im Alter.
        let row = (20..<70).map { Double(f.vegShift[40 * n + $0]) }
        XCTAssertGreaterThan(row.max()!, 0.1, "Senken sind grüner")
        XCTAssertLessThan(row.min()!, -0.1, "Rücken sind magerer")
        var crossings = 0
        for a in 1..<row.count where (row[a - 1] < 0) != (row[a] < 0) { crossings += 1 }
        let expected = 2 * Double(row.count) * step / WaterRender.barScrollPeriodYears
        XCTAssertEqual(Double(crossings), expected, accuracy: 3,
                       "eine Rippe je \(WaterRender.barScrollPeriodYears) Jahre Bankalter")
    }

    func testScrollRipplesFadeWhereTheyWouldAlias() {
        // Enger als `barScrollMinSpacingLo` Zellen je Periode: Rauschen, keine Rippe.
        let tight = WaterRender.barScrollPeriodYears / (WaterRender.barScrollMinSpacingLo * 0.9)
        for age in stride(from: 0.0, through: 2000, by: 37) {
            XCTAssertEqual(WaterRender.barScroll(age: age, gradientYearsPerCell: tight), 0)
        }
        XCTAssertEqual(WaterRender.barScroll(age: 500, gradientYearsPerCell: 0), 0,
                       "ohne Gradient keine Isolinie")
        XCTAssertEqual(WaterRender.barScroll(age: WaterRender.barScrollFadeYearsHi + 1,
                                             gradientYearsPerCell: 100), 0,
                       "alte Rippen sind unter Auelehm verschwunden")
    }

    // MARK: - Altarme

    func testOxbowLifecycleRunsReedThenArc() {
        let v = WaterRender.oxbowVisibleYears, maxAge = 25_000.0
        let young = WaterRender.oxbowStages(age: 0.3 * v, maxAge: maxAge)
        XCTAssertGreaterThan(young.reed, 0.9, "junger Altarm: Ried (auch ohne Wasser)")
        XCTAssertEqual(young.arc, 0)
        let old = WaterRender.oxbowStages(age: WaterRender.oxbowArcFull * v, maxAge: maxAge)
        XCTAssertEqual(old.reed, 0, accuracy: 1e-12)
        XCTAssertEqual(old.arc, 1, accuracy: 1e-12, "später: Bogen in der Vegetation")
        let gone = WaterRender.oxbowStages(age: maxAge, maxAge: maxAge)
        XCTAssertEqual(gone.reed + gone.arc, 0, accuracy: 1e-12,
                       "blendet vor dem Listen-Horizont der Sim aus")
    }

    private func arc(n: Int) -> [MeanderNode] {
        (0..<30).map { a in
            let phi = Double.pi * Double(a) / 29
            return MeanderNode(x: 32 + 14 * cos(phi), z: 30 + 14 * sin(phi))
        }
    }

    func testDryYoungOxbowShowsAsReed() {
        let n = 64
        let t = flatWorld(n: n, age: { _, _ in -1 }, oxbows: [arc(n: n)], oxbowAge: [1500])
        let f = BarMaterial.field(t)
        let k = 44 * n + 32  // Scheitel des Bogens
        XCTAssertGreaterThan(f.reed[k], 0.9, "trockener junger Altarm färbt als Ried")
        XCTAssertEqual(f.reed[5 * n + 5], 0)
        let colors = TerrainColorRenderer.buffers(t, bars: f).colors
        let plain = TerrainColorRenderer.buffers(t, bars: .empty).colors
        XCTAssertNotEqual(Array(colors[k * 4..<k * 4 + 3]), Array(plain[k * 4..<k * 4 + 3]),
                          "Ried tönt die Makrofarbe")
    }

    func testOldOxbowBecomesVegetationArcAndNewerBarCoversIt() {
        let n = 64
        let age = WaterRender.oxbowArcFull * WaterRender.oxbowVisibleYears
        let t = flatWorld(n: n, age: { i, j in i < 32 && j > 35 ? 100 : -1 },
                          oxbows: [arc(n: n)], oxbowAge: [age])
        let f = BarMaterial.field(t)
        XCTAssertEqual(Double(f.vegShift[44 * n + 33]), WaterRender.oxbowArcVeg, accuracy: 1e-5,
                       "alter Altarm: Vegetationsbogen")
        XCTAssertEqual(f.reed[44 * n + 33], 0)
        XCTAssertEqual(f.vegShift[42 * n + 25], 0, "eine jüngere Bank hat den Bogen überschüttet")
    }

    // MARK: - Querprofil im Band

    func testOutwardSideFollowsTheSimConvention() {
        // Linksbogen (Krümmung > 0): Außenufer rechts der Fließrichtung = UV.x 0.
        XCTAssertEqual(WaterRender.ribbonOutward(across: 0, bend: 1), 1)
        XCTAssertEqual(WaterRender.ribbonOutward(across: 1, bend: 1), -1)
        XCTAssertEqual(WaterRender.ribbonOutward(across: 1, bend: -1), 1)
        XCTAssertEqual(WaterRender.ribbonOutward(across: 0.5, bend: 1), 0, "Mitte bleibt")
        XCTAssertEqual(WaterRender.ribbonOutward(across: 0, bend: 0), 0, "Wendepunkt symmetrisch")
        XCTAssertGreaterThan(WaterRender.ribbonBendShift(across: 0, bend: 0.8), 0, "außen tiefer")
        XCTAssertLessThan(WaterRender.ribbonBendShift(across: 1, bend: 0.8), 0, "innen seichter")

        // Gegen die Sim: ein Linksbogen (gegen den Uhrzeigersinn in x/z) hat
        // positive Bogenstärke.
        var cfg = SimConfig.production
        cfg.meanderFlatSlope = 1  // jede Strecke mobil
        let nodes = (0..<40).map { a -> MeanderNode in
            let phi = -Double.pi / 2 + Double.pi * Double(a) / 39
            return MeanderNode(x: 300 + 30 * cos(phi), z: 300 + 30 * sin(phi))
        }
        let ch = RiverChannel(nodes: nodes, discharge: Array(repeating: 6000, count: 40))
        let bend = MeanderState.bendStrength(ch, config: cfg, heightAt: { _ in cfg.sea + 0.05 })
        XCTAssertGreaterThan(bend[20], 0, "Linksbogen → positive Bogenstärke")
        XCTAssertTrue(bend.allSatisfy { abs($0) <= 1 })
        let right = RiverChannel(nodes: nodes.reversed(), discharge: ch.discharge)
        XCTAssertLessThan(MeanderState.bendStrength(right, config: cfg,
                                                    heightAt: { _ in cfg.sea + 0.05 })[20], 0)
    }

    func testRibbonCarriesBendOnlyOnRivers() {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        let mesh = RiverRibbonRenderer().build(terrain, hscale: 24, lift: 0.35)
        XCTAssertFalse(mesh.vertices.isEmpty)
        var riverBend = false
        for (index, start) in mesh.stripStarts.enumerated() {
            let end = index + 1 < mesh.stripStarts.count ? Int(mesh.stripStarts[index + 1]) : mesh.uv2s.count
            for v in Int(start)..<end {
                let uv2 = mesh.uv2s[v]
                XCTAssertLessThanOrEqual(abs(uv2.y), 1)
                if uv2.x != Float(WaterRender.ribbonKindRiver) {
                    XCTAssertEqual(uv2.y, 0, "Delta-Arm und Altarm bleiben symmetrisch")
                } else if uv2.y != 0 { riverBend = true }
            }
        }
        XCTAssertTrue(riverBend, "die Fluss-Bänder tragen die Bogenstärke")
    }

    func testShadersReadBendAndSand() throws {
        let water = try RepoSource.probe("game/shaders/water.gdshader")
        assertContains(water, "v_bend = UV2.y", hint: "Bogenstärke aus UV2.y (Vertex-Vertrag)")
        assertContains(water, "float outward = -(UV.x * 2.0 - 1.0) * clamp(v_bend, -1.0, 1.0);",
                       hint: "Spiegel von WaterRender.ribbonOutward")
        assertContains(water, "depth = clamp(depth + water_ribbon_bend_depth * outward, 0.0, 1.0);",
                       hint: "außen tiefer, innen seichter")
        let terrain = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(terrain, "float sand = macro_rgba.a;", hint: "Sand aus dem A-Kanal der Makrofarbe")
        assertContains(terrain, "terr = mix(terr, sand_col, sand);", hint: "Bank-Material")
    }

    // MARK: - Abfluss-Vertrauen und Physik

    func testTrustWindow() {
        let ref = 320.0
        XCTAssertEqual(WaterRender.ribbonTrust(dischargeCells: WaterRender.ribbonTrustLoReferences * ref,
                                               referenceCells: ref), 0)
        XCTAssertEqual(WaterRender.ribbonTrust(dischargeCells: WaterRender.ribbonTrustHiReferences * ref,
                                               referenceCells: ref), 1)
        XCTAssertEqual(WaterRender.ribbonTrust(dischargeCells: .nan, referenceCells: ref), 0)
        XCTAssertEqual(WaterRender.ribbonTrust(dischargeCells: 1e9, referenceCells: 0), 0)
    }

    func testSmallChannelsStillNeedStreamMapSupport() {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        var s = terrain.state
        s.streamMap = [Double](repeating: 0, count: s.streamMap.count)
        terrain.restore(s)
        let mesh = RiverRibbonRenderer().build(terrain, hscale: 24, lift: 0.35)
        let lo = WaterRender.ribbonTrustLoReferences * terrain.cfg.renderMinCells
        for (ci, ch) in terrain.meander.channels.enumerated() where (ch.discharge.max() ?? 0) <= lo {
            XCTAssertFalse(mesh.bandChannelFlags[ci], "Lauf \(ci) ohne Stütze und Vertrauen bleibt unsichtbar")
        }
    }

    /// Gerader Lauf in Zeile `row` mit großem Abfluss (20 × `renderMinCells`,
    /// voll im Vertrauen). `crossSlope` (Sim-Höhe je Welt-Einheit) neigt das
    /// Gelände quer zum Lauf, `streamMap` ist die Stütze auf der Laufzeile.
    private func straightRiver(n: Int = 64, row: Int = 32, crossSlope: Double = 0,
                               streamMap: Double = 0,
                               channel: Bool = false) -> Terrain {
        let t = flatWorld(n: n) { _, _ in -1 }
        var s = t.state
        let cs = t.cfg.cellSize
        let q = 20 * t.cfg.renderMinCells
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                s.h[k] = t.cfg.sea + 0.08 + crossSlope * Double(abs(j - row)) * cs
                if j == row {
                    s.areaMFD[k] = q * cs * cs
                    s.area[k] = q * cs * cs
                    s.streamMap[k] = streamMap
                }
            }
        }
        s.hf = s.h
        s.waterLevel = s.h
        if channel {
            let nodes = stride(from: 2.0, through: Double(n - 3), by: 1.5).map { MeanderNode(x: $0, z: Double(row)) }
            s.meanderChannels = [RiverChannel(nodes: nodes, discharge: nodes.map { _ in q })]
        }
        t.restore(s)
        return t
    }

    /// Review #181: das Vertrauen malte den großen Lauf im Raster AUCH dort,
    /// wo ein Band ihn trägt — die D8-Treppe stand als zweites Wasser unter
    /// und neben dem glatten Band. Es gilt nur noch in den Band-Lücken.
    func testTrustedRasterFillsOnlyTheBandGaps() {
        let n = 64, row = 32
        let t = straightRiver(n: n, row: row)
        // Band über der linken Hälfte des Laufs, rechts eine Lücke.
        var cover = [Double](repeating: 0, count: n * n)
        for j in (row - 2)...(row + 2) { for i in 0..<(n / 2) { cover[j * n + i] = 1 } }
        let riverT = byte01(WaterRender.riverMaskLo)
        let withBand = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                                  bandChannelFlags: [], bandCoverage: cover)
        let noBand = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                                bandChannelFlags: [], bandCoverage: [])
        for i in 4..<(n / 2 - 4) {
            XCTAssertGreaterThanOrEqual(noBand[(row * n + i) * 4], riverT,
                                        "ohne Band malt das Vertrauen den Lauf (i = \(i))")
            XCTAssertLessThan(withBand[(row * n + i) * 4], riverT,
                              "unter dem Band kein zweites Raster-Wasser (i = \(i))")
        }
        for i in (n / 2 + 4)..<(n - 4) {
            XCTAssertGreaterThanOrEqual(withBand[(row * n + i) * 4], riverT,
                                        "in der Band-Lücke füllt das Raster (i = \(i))")
        }
    }

    /// Review #181: der Raster-Deckel unter einem Band hatte eine eigene
    /// Kaskaden-Ausnahme über die Zell-Neigung. Die sah auch das QUERgefälle
    /// einer Talflanke und ließ das Raster unter einem voll deckenden Band
    /// stehen (doppeltes Wasser in Zellblöcken). Die Kaskade blendet das Band
    /// selbst aus; der Deckel folgt nur noch der Band-Deckung.
    func testRasterUnderAFullBandIsCappedOnASteepCrossSlope() {
        let n = 64, row = 32
        let steep = WaterRender.cascadeSlopeLo + 2 * WaterRender.cascadeSlopeSpan
        let t = straightRiver(n: n, row: row, crossSlope: steep, streamMap: 1, channel: true)
        var cover = [Double](repeating: 0, count: n * n)
        for j in (row - 2)...(row + 2) { for i in 0..<n { cover[j * n + i] = 1 } }
        let riverT = byte01(WaterRender.riverMaskLo)
        let capped = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                                bandChannelFlags: [true], bandCoverage: cover)
        let open = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                              bandChannelFlags: [false], bandCoverage: [])
        for i in 8..<(n - 8) {
            XCTAssertGreaterThanOrEqual(open[(row * n + i) * 4], riverT,
                                        "ohne Band malt das Raster den Lauf (i = \(i))")
            XCTAssertLessThan(capped[(row * n + i) * 4], riverT,
                              "unter dem deckenden Band kein Raster-Wasser, auch am Steilhang (i = \(i))")
        }
    }

    /// Review #181 (Kaskaden): wo die Sim einen Lauf vor einer Steilstrecke
    /// enden lässt, malt das Raster weiter. Das Band endete dort mit voller
    /// Breite über 2 Zellen: rechtwinklig abgeschnitten. Und auf der
    /// Mündungs-Kette sprang die Breite zwischen Knick- und Mittelpunkten:
    /// versetzte Blöcke. Ein Band läuft an Land jetzt spitz aus, und seine
    /// Breite ändert sich je Zelle höchstens um `ribbonMaxHalfWidthSlope`.
    func testRibbonEndsTaperToAPointAndKeepAContinuousWidth() {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        let mesh = RiverRibbonRenderer().build(terrain, hscale: 24, lift: 0.35)
        let n = terrain.cfg.n, cs = terrain.cfg.cellSize, half = terrain.cfg.world / 2
        var landEnds = 0
        for (si, st) in mesh.stripStarts.enumerated() {
            let a = Int(st)
            let b = si + 1 < mesh.stripStarts.count ? Int(mesh.stripStarts[si + 1]) : mesh.vertices.count
            guard mesh.uv2s[a].x == Float(WaterRender.ribbonKindRiver) else { continue }
            let m = (b - a) / 2
            func mid(_ q: Int) -> SIMD3<Float> { (mesh.vertices[a + 2 * q] + mesh.vertices[a + 2 * q + 1]) * 0.5 }
            func halfWidth(_ q: Int) -> Double {
                let w = mesh.vertices[a + 2 * q] - mesh.vertices[a + 2 * q + 1]
                // Waagerecht: am Ufer liegen die beiden Kanten auf eigener Höhe
                // (Land bzw. Spiegel), der Höhenversatz ist keine Breite.
                return Double((w.x * w.x + w.z * w.z).squareRoot()) / cs / 2
            }
            func length(_ p: Int, _ q: Int) -> Double {
                let d = mid(q) - mid(p)
                return Double((d.x * d.x + d.z * d.z).squareRoot()) / cs
            }
            for q in 1..<m {
                XCTAssertLessThanOrEqual(abs(halfWidth(q) - halfWidth(q - 1)),
                                         WaterRender.ribbonMaxHalfWidthSlope * length(q - 1, q) * 1.1 + 0.02,
                                         "Band \(si): Breitensprung zwischen Stützpunkt \(q - 1) und \(q)")
            }
            for order in [Array((0..<m).reversed()), Array(0..<m)] {
                let e = mid(order[0])
                let ci = min(max(Int(((Double(e.x) + half) / cs).rounded()), 0), n - 1)
                let cj = min(max(Int(((Double(e.z) + half) / cs).rounded()), 0), n - 1)
                var wet = false
                for dj in -2...2 { for di in -2...2 {
                    let ni = ci + di, nj = cj + dj
                    guard ni >= 0, nj >= 0, ni < n, nj < n else { continue }
                    let k = nj * n + ni
                    if terrain.h[k] <= terrain.cfg.sea
                        || terrain.waterLevel[k] - terrain.h[k] > WaterRender.pondContourLo { wet = true }
                }}
                if wet { continue }   // Mündung: die Übergabe regelt die Wassersäule
                landEnds += 1
                var dist = 0.0
                for idx in 1..<order.count {
                    dist += length(order[idx - 1], order[idx])
                    guard mesh.colors[a + 2 * order[idx]].w >= 0.5 else { continue }
                    XCTAssertGreaterThanOrEqual(dist, halfWidth(order[idx]),
                                                "Band \(si) endet stumpf: Deckkraft 0,5 liegt \(dist) Zellen vor dem Ende, Halbbreite \(halfWidth(order[idx]))")
                    break
                }
            }
        }
        XCTAssertGreaterThan(landEnds, 0, "Testwelt hat keine Band-Enden an Land")
    }

    func testBeltRenderLeavesThePhysicsUntouched() {
        let terrain = agedWorld(renderConfig(n: 96), years: 2000)
        let before = terrain.fingerprint()
        let render = RenderState(geometryMode: true)
        _ = render.frame(terrain, .settled, now: 0)
        _ = render.barMaterial(terrain)
        XCTAssertEqual(terrain.fingerprint(), before)
    }
}
