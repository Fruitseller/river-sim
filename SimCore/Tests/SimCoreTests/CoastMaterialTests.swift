import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für Strand und Felsküste (Issue #174, Paket C): `CoastMaterial`
/// und seine Gewichte im `TerrainColorRenderer` (Sand im A-Kanal der
/// Makrofarbe, Fels im G-Kanal der Materialgewichte).
final class CoastMaterialTests: XCTestCase {

    /// Das Ende einer Sandbank breitet sich radial aus. Eine quadratische
    /// Distanz gab der diagonalen Probe denselben Sand wie der Achsenprobe.
    func testSandbankEndHasARoundBeachContour() {
        var cfg = SimConfig(); cfg.n = 32
        let t = Terrain(allocating: cfg, seed: 1)
        let h = [Double](repeating: cfg.sea + 0.001, count: cfg.count)
        t.setBedForTests(h: h, sed: h.map { _ in 0.001 }, rock: h.map { $0 - 0.001 }, underIce: [])
        let center = 16 * cfg.n + 16
        var widths = [Float](repeating: 0, count: cfg.count); widths[center] = 4
        let reach = CoastMaterial.beachReach(t, seeds: [center], width: widths)
        XCTAssertEqual(reach[center + 3], 1)
        XCTAssertEqual(reach[center + 3 * cfg.n], 1)
        XCTAssertEqual(reach[center + 3 * cfg.n + 3], 0, "Sand reicht diagonal über den Kreis hinaus")
        XCTAssertGreaterThan(reach[center + 2 * cfg.n + 3], 0)
        XCTAssertLessThan(reach[center + 2 * cfg.n + 3], 0.5)
    }

    /// Kleine Welt: Spalten `i < shore` flaches Meer, rechts davon Land mit der Höhe
    /// `land(i)`.
    func testThickDeltaSedimentDoesNotTurnIntoACoastalRockCliff() {
        let sea = SimConfig().sea
        let t = coastWorld(n: 48, shore: 24) { _ in sea + 0.0015 }
        var state = t.state
        state.sed = state.h.map { _ in 0.05 }
        state.rock = zip(state.h, state.sed).map { $0 - $1 }
        t.restore(state)
        let shore = CoastMaterial.shore(t)
        XCTAssertEqual(shore.cliffReach[24 * 48 + 24], 0, "Sediment ist kein Fels")
        state.sed = state.h.map { _ in 0 }
        state.rock = state.h
        t.restore(state)
        XCTAssertGreaterThan(CoastMaterial.shore(t).cliffReach[24 * 48 + 24], 0,
                             "Brandung erreicht freiliegenden Fels weiter")
    }

    private func coastWorld(n: Int = 32, shore: Int = 8,
                            land: (Int) -> Double) -> Terrain {
        let config = renderConfig(n: n)
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        for j in 0..<n {
            for i in 0..<n {
                // Flacher Schelf: ein tiefer Absturz an der Wasserlinie läse
                // die Makro-Steigung (±2 Zellen) schon als Steilküste.
                state.h[j * n + i] = i < shore ? config.sea - 0.002 : land(i)
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    /// Befund #174 (Seed 42, Südküste): eine flache Uferterrasse vor einem
    /// Berg wurde über das Rückland-Relief zur Felsküste — dunkles Geröll auf
    /// ebenem Boden. Fels gehört an die Kliffwand, nicht auf die Terrasse;
    /// ein Kliff direkt an der Wasserlinie bleibt Fels.
    func testFlatTerraceBelowAMountainIsNoRockCoast() {
        let sea = SimConfig().sea
        // Terrasse 6 Zellen breit auf sea + 0,002 (Gefälle 0,0003 je Zelle),
        // dahinter ein Hang mit 0,04 je Zelle.
        let terrace = coastWorld(n: 48, shore: 12) { i in
            i < 18 ? sea + 0.002 + 0.0003 * Double(i - 12) : sea + 0.004 + 0.04 * Double(i - 18)
        }
        let n = terrace.cfg.n
        let backland = (12...20).map { terrace.h[24 * n + $0] }.max()! - terrace.h[24 * n + 12]
        XCTAssertGreaterThan(backland, 0.075, "Aufbau: Berg im Rückland (Radius 8), früher volle Felsküste")
        let buffers = TerrainColorRenderer.buffers(terrace)
        for i in 12...14 {
            let k = 24 * n + i
            XCTAssertLessThan(buffers.surfaces[k * 4 + 1], 32, "Fels auf der flachen Terrasse bei i = \(i)")
        }
        let cliff = coastWorld(n: 48, shore: 12) { i in sea + 0.002 + 0.03 * Double(i - 12) }
        let k = 24 * n + 13
        XCTAssertGreaterThan(TerrainColorRenderer.buffers(cliff).surfaces[k * 4 + 1], 200,
                             "Kliff an der Wasserlinie bleibt Fels")
    }

    func testCalibrationWindowsFitTheWaveBandAndDoNotOverlap() {
        XCTAssertLessThanOrEqual(WaterRender.beachHeightHi, SimConfig().waveBand,
                                 "Strand nur, wo die Brandung (wavePass) arbeitet")
        XCTAssertLessThan(WaterRender.beachHeightLo, WaterRender.beachHeightHi)
        XCTAssertLessThan(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi)
        XCTAssertLessThan(WaterRender.cliffCoastSlopeLo, WaterRender.cliffCoastSlopeHi)
        XCTAssertLessThanOrEqual(WaterRender.beachSlopeHi, WaterRender.cliffCoastSlopeLo,
                                 "eine Küstenzelle ist Strand ODER Fels")
        XCTAssertGreaterThanOrEqual(WaterRender.coastReachCells, 1)
        // Der Zusammenhang je Küstenpunkt (§E).
        XCTAssertLessThan(WaterRender.beachReliefLo, WaterRender.beachReliefHi)
        XCTAssertLessThan(WaterRender.cliffRiseLo, WaterRender.cliffRiseHi)
        XCTAssertLessThan(WaterRender.cliffFaceSlopeLo, WaterRender.cliffFaceSlopeHi)
        XCTAssertLessThanOrEqual(WaterRender.cliffFaceSlopeHi, WaterRender.cliffCoastSlopeLo,
                                 "die Kliffwand-Schwelle liegt unter der allgemeinen")
        XCTAssertLessThan(WaterRender.cliffRiseRadiusCells, WaterRender.beachReliefRadiusCells,
                          "die Kliffhöhe misst näher an der Küste als das Rückland")
        XCTAssertLessThan(WaterRender.beachOpenLo, WaterRender.beachOpenHi)
        XCTAssertLessThan(WaterRender.beachPotentialLo, WaterRender.beachPotentialHi)
        XCTAssertLessThan(WaterRender.beachSupplyMinCells, WaterRender.beachSupplyFullCells)
        XCTAssertTrue((0...1).contains(WaterRender.beachExposedShare))
        XCTAssertTrue((0...1).contains(WaterRender.beachSupplyFloor))
        XCTAssertTrue((0...1).contains(WaterRender.beachSupplyReliefCut))
        XCTAssertTrue((0...1).contains(WaterRender.beachSupplyNoiseCut))
        XCTAssertGreaterThan(WaterRender.beachMaxWidthCells, 1)
        XCTAssertLessThan(WaterRender.beachMaxWidthCells, Double(CoastMaterial.distanceCap),
                          "der Abstandsdeckel reicht für den breitesten Strand")
        XCTAssertGreaterThanOrEqual(CoastMaterial.distanceCap, WaterRender.coastReachCells + 1)
        // Das Rauschen allein darf einen geschützten Strand nicht löschen und
        // eine offene Küste ohne Zufuhr nicht zum vollen Strand heben.
        let sheltered = (0...10).map { CoastMaterial.beach(relief: 0.01, rise: 0.005, openness: 0.38, supply: 0,
                                                           noise: Double($0) / 10).width }
        XCTAssertGreaterThan(sheltered.min() ?? 0, 0.5 * WaterRender.beachMaxWidthCells,
                             "geschützte Küstenebene bleibt auch bei schlechtestem Rauschen ein breiter Strand")
        let exposed = (0...10).map { CoastMaterial.beach(relief: 0.01, rise: 0.005, openness: 0.55, supply: 0,
                                                         noise: Double($0) / 10).width }
        XCTAssertLessThan(exposed.max() ?? 0, 0.5 * WaterRender.beachMaxWidthCells,
                          "offene Küstenebene wird auch bei bestem Rauschen kein breiter Strand")
        // Die Mip-Kette der Fahnen-Textur ist bei n = 720 (2^4 · 45) nur bis
        // Stufe 4 gleichmäßig; der Shader liest nur eine niedrige Stufe.
        XCTAssertLessThanOrEqual(WaterRender.oceanPlumeLod, 4)
    }

    func testSeaDistanceIsChebyshevAndCapped() {
        let terrain = coastWorld { _ in SimConfig().sea + 0.1 }
        let dist = CoastMaterial.seaDistance(terrain)
        let n = terrain.cfg.n, cap = UInt8(CoastMaterial.distanceCap)
        XCTAssertEqual(dist.count, n * n)
        for i in 0..<n {
            let expected = i < 8 ? 0 : min(Int(cap), i - 7)
            XCTAssertEqual(Int(dist[10 * n + i]), expected, "Spalte \(i)")
        }
    }

    func testFlatLowCoastBecomesSandAndLeavesTheInlandAlone() {
        let sea = SimConfig().sea
        let terrain = coastWorld { _ in sea + 0.004 }
        let buffers = TerrainColorRenderer.buffers(terrain)
        let n = terrain.cfg.n, j = 16
        // Geschützte Küstenebene: mindestens die ersten beiden Zellen sind Strand
        // (die Breite schwankt mit dem Rauschen, ihr Minimum liegt über 2,5 Zellen).
        for i in 8...9 {
            let k = j * n + i
            XCTAssertGreaterThanOrEqual(buffers.colors[k * 4 + 3], 128, "Strand an Spalte \(i)")
            XCTAssertLessThan(buffers.surfaces[k * 4], 128, "kein Bewuchs auf dem Strand")
        }
        // Die weiche Sandkante (`TerrainColorRenderer.softenSand`, 3×3) läuft
        // eine Zelle über den breitesten Strand hinaus aus.
        let inland = j * n + 8 + WaterRender.coastReachCells + 3
        XCTAssertEqual(buffers.colors[inland * 4 + 3], 0, "Strand nur in Reichweite der Brandung")
        for k in 0..<(n * n) where terrain.h[k] <= sea {
            XCTAssertEqual(buffers.colors[k * 4 + 3], 0, "kein Sand unter Wasser")
        }
    }

    /// Delta-Insel (Issue #174, Punkt 26): eine flache Mündungsbarre vor einer
    /// Steilküste ist Sand, obwohl sie offen im Meer liegt; die Steilküste
    /// daneben bleibt Fels ohne Sand.
    func testDeltaIslandIsSandEvenOnAnOpenCoast() {
        let sea = SimConfig().sea
        let terrain = coastWorld(n: 48, shore: 24) { i in sea + 0.02 * Double(i - 23) }
        let n = terrain.cfg.n
        var state = terrain.state
        var island: [Int] = []
        for j in 20...26 { for i in 8...13 {
            let k = j * n + i
            state.h[k] = sea + 0.0015
            island.append(k)
        } }
        state.waterLevel = state.h
        terrain.restore(state)
        XCTAssertEqual(Set(CoastMaterial.deltaIslands(terrain)), Set(island))
        let buffers = TerrainColorRenderer.buffers(terrain)
        let centre = 23 * n + 10
        XCTAssertGreaterThanOrEqual(buffers.colors[centre * 4 + 3], 128, "Inselmitte ist Sand")
        XCTAssertEqual(buffers.colors[(23 * n + 25) * 4 + 3], 0, "Steilküste bleibt ohne Sand")
    }

    func testSteepCoastStaysRockWithoutSand() {
        let sea = SimConfig().sea
        // 0,02 je Zelle: macroSlope = 4 · 0,02 · 0,125 = 0,01 — steil für diese Küste.
        let terrain = coastWorld { i in sea + 0.02 * Double(i - 7) }
        let buffers = TerrainColorRenderer.buffers(terrain)
        let n = terrain.cfg.n
        let k = 16 * n + 9
        XCTAssertEqual(buffers.colors[k * 4 + 3], 0, "Felsküste trägt keinen Sand")
        XCTAssertGreaterThan(buffers.surfaces[k * 4 + 1], 200, "Felsküste ist Fels")
        let far = 16 * n + 20
        XCTAssertLessThan(buffers.surfaces[far * 4 + 1], buffers.surfaces[k * 4 + 1],
                          "derselbe Hang ohne Brandung bleibt beim allgemeinen Klippen-Gewicht")
    }

    /// Review zu #174 C: die Felsküste füllte den Rest `1 − Vegetation − Halde −
    /// Rohboden` und ließ dabei die Kälte aus. Unter teilweiser Schneedeckung
    /// summierten sich die Gewichte über 1 (Shader: Gewichtssumme).
    func testCliffCoastUnderPartialSnowKeepsWeightsWithinOne() {
        let sea = SimConfig().sea
        let terrain = coastWorld { i in sea + 0.02 * Double(i - 7) }
        let n = terrain.cfg.n
        var state = terrain.state
        state.veg = [Double](repeating: 1, count: n * n)
        state.rain = [Double](repeating: 1, count: n * n)   // ohne Regen wächst hier nichts
        state.snow = [Double](repeating: terrain.cfg.snowCoverRef, count: n * n)   // Deckung 0,5
        terrain.restore(state)
        let buffers = TerrainColorRenderer.buffers(terrain)
        var worst = 0.0, checked = 0
        for i in 8...(7 + WaterRender.coastReachCells) {
            let k = 16 * n + i
            let cold = Double(buffers.surfaces[k * 4 + 2]) / 255
            let rock = Double(buffers.surfaces[k * 4 + 1]) / 255
            guard cold > 0.3, rock > 0 else { continue }   // Aufbau: Küstenfels UNTER Schnee
            checked += 1
            let sum = Double(buffers.surfaces[k * 4]) / 255 + rock + cold
                + Double(buffers.covers[k * 4]) / 255 + Double(buffers.covers[k * 4 + 2]) / 255
            worst = max(worst, sum)
        }
        XCTAssertGreaterThan(checked, 0, "Aufbau: keine Küstenzelle mit Fels unter Schnee")
        XCTAssertLessThanOrEqual(worst, 1 + 5.0 / 255, "Gewichte der Felsküste unter Schnee über 1")
    }

    // MARK: - Küstenzusammenhang (Befund §E)

    /// Rundinsel mit buchtiger Küste (`r(θ) = radius + bump · sin(lobes · θ)`)
    /// und linearem Hang `slope(θ)` je Zelle landeinwärts, flachem Schelf davor.
    /// Gemessen wird nur über Höhe und Gitter; die Zellgröße spielt für die
    /// Küstenableitung keine Rolle.
    private func island(n: Int = 160, radius: Double = 55, bump: Double = 10, lobes: Double = 5,
                        slope: (Double) -> Double, mouths: [(theta: Double, discharge: Double)] = []) -> Terrain {
        let config = renderConfig(n: n)
        let sea = config.sea
        let cellArea = config.cellSize * config.cellSize
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        let c = Double(n) / 2
        for j in 0..<n {
            for i in 0..<n {
                let dx = Double(i) - c, dz = Double(j) - c
                let theta = atan2(dz, dx), d = (dx * dx + dz * dz).squareRoot()
                let r = radius + bump * sin(lobes * theta)
                state.h[j * n + i] = d < r ? sea + 0.0005 + slope(theta) * (r - d) : sea - 0.002
                state.receiver[j * n + i] = -1
                state.area[j * n + i] = 0
            }
        }
        for m in mouths {
            // Ein Lauf von innen zur Küste, die Mündungszelle ist die letzte Landzelle.
            let r = radius + bump * sin(lobes * m.theta)
            var previous = -1
            for step in stride(from: 20.0, through: 0.0, by: -1) {
                let i = Int((c + (r - step) * cos(m.theta)).rounded()), j = Int((c + (r - step) * sin(m.theta)).rounded())
                let k = j * n + i
                guard state.h[k] > sea else { break }
                if previous >= 0 { state.receiver[previous] = Int32(k) }
                state.area[k] = m.discharge * cellArea * (1 - step / 25)
                previous = k
            }
            // Empfänger der letzten Landzelle: die nächste Meereszelle nach außen.
            if previous >= 0 {
                let i = Int((c + (r + 1.5) * cos(m.theta)).rounded()), j = Int((c + (r + 1.5) * sin(m.theta)).rounded())
                state.receiver[previous] = Int32(j * n + i)
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    /// Anteil der Küstenlinie (Abstand 1) mit Sand ≥ 0,5 sowie Fels ≥ 0,5,
    /// ausgewählt über `include(θ)`.
    private func coastShares(_ terrain: Terrain, theta include: (Double) -> Bool) -> (sand: Double, rock: Double, cells: Int) {
        let n = terrain.cfg.n, c = Double(n) / 2
        let buffers = TerrainColorRenderer.buffers(terrain)
        let dist = CoastMaterial.seaDistance(terrain)
        var sand = 0, rock = 0, cells = 0
        for k in 0..<(n * n) where dist[k] == 1 {
            let theta = atan2(Double(k / n) - c, Double(k % n) - c)
            guard include(theta) else { continue }
            cells += 1
            if buffers.colors[k * 4 + 3] >= 128 { sand += 1 }
            if buffers.surfaces[k * 4 + 1] >= 128 { rock += 1 }
        }
        return (Double(sand) / Double(max(cells, 1)), Double(rock) / Double(max(cells, 1)), cells)
    }

    /// Steiles Rückland: kein Strand, Fels bis ans Wasser. Flache Ebene
    /// derselben Insel (gegenüber): Strand. Das war der Befund — vorher trug
    /// BEIDE Küste denselben Sandring.
    func testSteepFlankMeetsTheSeaWithRockAndPlainCarriesBeach() {
        // Westhälfte (|θ| > π/2) steil, Osthälfte flach.
        let terrain = island(bump: 0, slope: { abs($0) > .pi / 2 ? 0.012 : 0.0012 })
        let steep = coastShares(terrain) { abs($0) > .pi / 2 + 0.3 }
        let plain = coastShares(terrain) { abs($0) < .pi / 2 - 0.3 }
        XCTAssertGreaterThan(steep.cells, 60)
        XCTAssertGreaterThan(plain.cells, 60)
        XCTAssertEqual(steep.sand, 0, accuracy: 0.02, "unter einer Steilflanke liegt kein Strand")
        XCTAssertGreaterThan(steep.rock, 0.9, "Steilküste: Fels bis ans Wasser")
        XCTAssertGreaterThan(plain.sand, 0.1, "Küstenebene trägt Strand, auch an der gradlinigen Küste")
        XCTAssertLessThan(plain.rock, 0.05)
    }

    /// Strände liegen in Buchten, nicht auf Landzungen: dieselbe flache Insel mit
    /// Buchten und Landzungen, Sand sitzt in den Buchten.
    func testBeachesSitInBaysNotOnHeadlands() {
        let terrain = island(bump: 14, lobes: 6, slope: { _ in 0.0012 })
        let n = terrain.cfg.n, c = Double(n) / 2
        let dist = CoastMaterial.seaDistance(terrain)
        let shore = CoastMaterial.shore(terrain)
        var bay: [Float] = [], head: [Float] = []
        for k in 0..<(n * n) where dist[k] == 1 {
            let theta = atan2(Double(k / n) - c, Double(k % n) - c)
            // r(θ) = radius + bump · sin(6θ): Täler (Landeinbuchtung) bei sin = −1.
            let s = sin(6 * theta)
            if s < -0.8 { bay.append(shore.beachWidth[k]) }
            if s > 0.8 { head.append(shore.beachWidth[k]) }
        }
        XCTAssertGreaterThan(bay.count, 20); XCTAssertGreaterThan(head.count, 20)
        let bayMean = bay.reduce(0, +) / Float(bay.count), headMean = head.reduce(0, +) / Float(head.count)
        XCTAssertGreaterThan(bayMean, headMean + 0.5, "Buchten tragen breiteren Strand als Landzungen")
    }

    /// Strand ist unterbrochen und wechselt die Breite: ein Ring in EINEM Stück
    /// und gleicher Breite war der Befund.
    func testBeachWidthVariesAndTheBeachIsInterrupted() {
        let terrain = island(bump: 14, lobes: 6, slope: { _ in 0.0012 })
        let n = terrain.cfg.n
        let dist = CoastMaterial.seaDistance(terrain)
        let shore = CoastMaterial.shore(terrain)
        let coast = (0..<(n * n)).filter { dist[$0] == 1 }
        let widths = Set(coast.map { Int(shore.beachWidth[$0].rounded()) })
        XCTAssertGreaterThanOrEqual(widths.count, 4, "mindestens vier verschiedene Breiten, gefunden \(widths.sorted())")
        let sandy = coast.filter { shore.beachWidth[$0] >= 1 }
        XCTAssertGreaterThan(Double(sandy.count) / Double(coast.count), 0.15, "es gibt Strände")
        XCTAssertLessThan(Double(sandy.count) / Double(coast.count), 0.85, "und Küste ohne Strand")
        XCTAssertGreaterThanOrEqual(CoastShapeTests.components(sandy, n: n).count, 3,
                                    "mehrere getrennte Strandabschnitte")
    }

    /// Flussmündungen liefern Sand: an einer sonst steilen Küste liegt nur bei
    /// der Mündung Strand, hinter `beachSupplyReachCells` keiner.
    func testRiverMouthDeliversSandOnASteepCoast() {
        let mouthTheta = 0.5
        // 0,0045 je Zelle: Rückland-Relief um 0,05 — an dieser Küste liegt von
        // sich aus kein Strand (`beachReliefHi`).
        let terrain = island(bump: 0, slope: { _ in 0.0045 },
                             mouths: [(theta: mouthTheta, discharge: 5000)])
        let n = terrain.cfg.n, c = Double(n) / 2
        let dist = CoastMaterial.seaDistance(terrain)
        let shore = CoastMaterial.shore(terrain)
        let mx = c + 55 * cos(mouthTheta), mz = c + 55 * sin(mouthTheta)
        var near: [Float] = [], far: [Float] = []
        for k in 0..<(n * n) where dist[k] == 1 {
            let d = (pow(Double(k % n) - mx, 2) + pow(Double(k / n) - mz, 2)).squareRoot()
            if d < 6 { near.append(shore.beachWidth[k]) }
            if d > WaterRender.beachSupplyReachCells + 4 { far.append(shore.beachWidth[k]) }
        }
        XCTAssertFalse(near.isEmpty)
        XCTAssertGreaterThan(near.max() ?? 0, 2, "Strand an der Mündung")
        XCTAssertEqual(far.max() ?? 0, 0, "kein Strand an der steilen Küste fern der Mündung")
    }

    /// Die Funktion hinter der Küstenableitung ist monoton: flacheres Rückland,
    /// geschütztere Lage und mehr Zufuhr geben nie weniger Strand.
    func testBeachModelIsMonotone() {
        func width(_ relief: Double, _ openness: Double, _ supply: Double, _ noise: Double = 0.5) -> Double {
            CoastMaterial.beach(relief: relief, rise: relief, openness: openness, supply: supply, noise: noise).width
        }
        var previous = Double.infinity
        for r in stride(from: 0.0, through: 0.1, by: 0.005) {
            let w = width(r, 0.4, 0)
            XCTAssertLessThanOrEqual(w, previous + 1e-12, "Relief \(r)"); previous = w
        }
        previous = Double.infinity
        for o in stride(from: 0.3, through: 0.7, by: 0.02) {
            let w = width(0.025, o, 0)
            XCTAssertLessThanOrEqual(w, previous + 1e-12, "Offenheit \(o)"); previous = w
        }
        previous = -1
        for q in stride(from: 0.0, through: 1.0, by: 0.1) {
            let w = width(0.035, 0.5, q)
            XCTAssertGreaterThanOrEqual(w, previous - 1e-12, "Zufuhr \(q)"); previous = w
        }
        // Rauschen unterbricht nur, was nicht eindeutig ist: Küstenebene in
        // geschützter Lage behält ihren Strand, steiles Rückland bekommt keinen.
        XCTAssertGreaterThan(width(0.01, 0.38, 0, 0), 0.5 * WaterRender.beachMaxWidthCells)
        XCTAssertEqual(width(0.09, 0.45, 0, 1), 0)
        let c = CoastMaterial.beach(relief: 0.09, rise: 0.04, openness: 0.5, supply: 0, noise: 0.5)
        XCTAssertEqual(c.cliff, 1, accuracy: 1e-9, "hohes Kliff ist Felsküste")
        XCTAssertEqual(CoastMaterial.beach(relief: 0.01, rise: 0.005, openness: 0.4, supply: 0, noise: 0.5).cliff, 0)
        XCTAssertEqual(CoastMaterial.beach(relief: 0.09, rise: 0.005, openness: 0.5, supply: 0, noise: 0.5).cliff, 0,
                       "Berg im Rückland ohne Kliff an der Küste ist keine Felsküste")
    }

    func testCoastWeightsAreDeterministic() {
        let terrain = agedWorld(renderConfig(n: 96), years: 2000)
        let a = TerrainColorRenderer.buffers(terrain), b = TerrainColorRenderer.buffers(terrain)
        XCTAssertEqual(a.colors, b.colors)
        XCTAssertEqual(a.surfaces, b.surfaces)
        XCTAssertTrue(stride(from: 3, to: a.colors.count, by: 4).contains { a.colors[$0] > 128 },
                      "gealterte Welt ohne einen einzigen Strand")
    }
}
