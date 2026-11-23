import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

final class CanopyTests: XCTestCase {

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], forest: [UInt8]) {
        let overlays = frameOverlays(render, terrain)
        return (overlays.water, overlays.forestMask)
    }

    private func referenceForest(_ terrain: Terrain, colors: [UInt8], surfaces: [UInt8],
                                 bandCore: [Double], water: [UInt8], wetMeadow: [Bool],
                                 protect: [UInt8]) -> [UInt8] {
        let n = terrain.cfg.n, world = terrain.cfg.world
        return ForestCanopyMask.target(
            terrain, surfaces: surfaces, colors: colors, bandCore: bandCore, waterBytes: water,
            wetMeadow: wetMeadow, barSand: BarMaterial.field(terrain).sand,
            clump: ForestCanopyMask.clumpField(n: n, world: world),
            riparianNoise: ForestCanopyMask.riparianField(n: n, world: world),
            protect: protect).mask
    }

    func testNoForestOverRiversLakesOrBands() {
        var c = renderConfig(n: 192)
        c.meanderBeltKernelWidths = calibrationBeltRenderKernelWidths
        c.meanderBeltSymmetricStamp = calibrationBeltSymmetricStamp
        let terrain = agedWorld(c, years: 2000, seed: 1337)
        let render = RenderState(geometryMode: true)
        let (water, forest) = refresh(render, terrain)
        let coverage = render.bandCore
        let n = terrain.cfg.n
        let river = byte01(WaterRender.protectRiverThreshold)
        let lake = byte01(WaterRender.protectLakeThreshold)

        var rivers = 0, lakes = 0, bands = 0
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                let isRiver = water[k * 4] >= river
                let isLake = water[k * 4 + 1] >= lake
                let isBand = coverage[k] >= WaterRender.protectBandThreshold
                guard isRiver || isLake || isBand else { continue }
                if isRiver { rivers += 1 }
                if isLake { lakes += 1 }
                if isBand { bands += 1 }
                for nj in max(0, j - 1)...min(n - 1, j + 1) {
                    for ni in max(0, i - 1)...min(n - 1, i + 1) {
                        XCTAssertEqual(forest[nj * n + ni], 0,
                                       "Wald an (\(ni), \(nj)) neben Wasser (\(i), \(j))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(rivers, 0, "Testwelt braucht sichtbare Raster-Flüsse")
        XCTAssertGreaterThan(lakes, 0, "Testwelt braucht sichtbare Seen")
        XCTAssertGreaterThan(bands, 0, "Testwelt braucht Flussbänder")
        XCTAssertGreaterThan(forest.filter { $0 == 255 }.count, n * n / 40,
                             "Testwelt braucht geschlossenen Wald, sonst prüft der Test nichts")
        let s = CanopyWaterline.measure(terrain, mesh: render.riverRibbonMesh, forest: forest)
        print(CanopyWaterline.report(s))
        XCTAssertGreaterThan(s.points, 2000, "Testwelt trägt zu wenig Bandwasser für eine Aussage")
        XCTAssertEqual(s.forested, 0,
                       "Wald im sichtbaren Bandwasser (inkl. Wasserlinien-Rauschen); erster Punkt \(s.first.map { "(\($0.0), \($0.1))" } ?? "-")")
    }

    func testNoForestOnWallsSnowOrShore() {
        let n = 96
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        let sea = terrain.cfg.sea
        let perCell = terrain.cfg.world / Double(n) / RenderContract.heightScale
        var state = terrain.state
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                surfaces[k * 4] = 255
                switch i {
                case ..<24:  state.h[k] = sea + 0.2
                case ..<48:  state.h[k] = sea + 0.2 + Double(i - 24) * perCell * 2.5
                case ..<72:  state.h[k] = sea + 0.2; surfaces[k * 4 + 2] = 255
                default:     state.h[k] = sea + CanopyRender.shoreLo * 0.5
                }
            }
        }
        terrain.restore(state)
        let forest = ForestCanopyMask.bytes(terrain, surfaces: surfaces,
                                            protect: [UInt8](repeating: 0, count: n * n),
                                            clump: [Float](repeating: 0, count: n * n))
        for j in 2..<(n - 2) {
            for i in [4, 20] { XCTAssertEqual(forest[j * n + i], 255, "Ebene trägt Wald (\(i), \(j))") }
            for i in [30, 40, 60, 66, 80, 90] {
                XCTAssertEqual(forest[j * n + i], 0, "Wald an (\(i), \(j))")
            }
        }
    }

    func testOnlyDenseVegetationBecomesForest() {
        let n = 32
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        var state = terrain.state
        for k in state.h.indices { state.h[k] = terrain.cfg.sea + 0.2 }
        terrain.restore(state)
        func forest(vegetation: Double) -> UInt8 {
            var surfaces = [UInt8](repeating: 0, count: n * n * 4)
            for k in 0..<(n * n) { surfaces[k * 4] = byte01(vegetation) }
            let mask = ForestCanopyMask.bytes(terrain, surfaces: surfaces,
                                              protect: [UInt8](repeating: 0, count: n * n),
                                              clump: [Float](repeating: 0, count: n * n))
            return mask[(n / 2) * n + n / 2]
        }
        XCTAssertEqual(forest(vegetation: 0.1), 0, "Magere Vegetation bleibt Wiese")
        let middle = forest(vegetation: 0.3)
        XCTAssertGreaterThan(middle, 0, "Mittlere Vegetation trägt lichten Wald (Saum)")
        XCTAssertLessThan(middle, 255, "Mittlere Vegetation ist kein geschlossener Bestand")
        XCTAssertEqual(forest(vegetation: 0.7), 255, "Dichte Vegetation ist geschlossener Wald")
    }

    func testClearingsCutIntoDenseVegetation() {
        let cfg = SimConfig.production
        let clump = ForestCanopyMask.clumpField(n: cfg.n, world: cfg.world)
        let open = clump.filter {
            0.78 + Double($0) * CanopyRender.clumpGain
                < (CanopyRender.vegetationLo + CanopyRender.vegetationHi) / 2
        }.count
        let share = Double(open) / Double(clump.count)
        XCTAssertGreaterThan(share, 0.02, "Dichte Bestände brauchen Lichtungen")
        XCTAssertLessThan(share, 0.2, "Lichtungen dürfen den Bestand nicht auflösen")
    }

    func testNoForestWithoutCellSpacing() {
        let n = 32
        var veg = [UInt8](repeating: 0, count: n * n * 4)
        for k in 0..<(n * n) { veg[k * 4] = 255 }
        let protect = [UInt8](repeating: 0, count: n * n)
        let clump = [Float](repeating: 0, count: n * n)
        let flat = Terrain(config: renderConfig(n: n), seed: 1337)
        var state = flat.state
        for k in state.h.indices { state.h[k] = flat.cfg.sea + 0.2 }
        flat.restore(state)
        XCTAssertTrue(ForestCanopyMask.bytes(flat, surfaces: veg, protect: protect, clump: clump)
                          .contains(255), "Vorbedingung: Ebene trägt Wald")
        for world in [0, -10, Double.nan, .infinity] {
            var c = renderConfig(n: n)
            c.world = world
            XCTAssertEqual(c.cellSize, 0)
            let terrain = Terrain(allocating: c, seed: 1337)
            terrain.restore(state)
            XCTAssertEqual(ForestCanopyMask.bytes(terrain, surfaces: veg, protect: protect, clump: clump),
                           [UInt8](repeating: 0, count: n * n), "Wald bei world = \(world)")
        }
    }

    func testSameWorldYieldsIdenticalForest() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Waldverteilung liefern")
    }

    func testForestFollowsTheProtectMask() {
        let terrain = aged()
        let withBands = refresh(RenderState(geometryMode: true), terrain).forest
        let withoutBands = refresh(RenderState(geometryMode: false), terrain).forest
        XCTAssertNotEqual(withoutBands, withBands, "Band-Bau muss den Wald zurücknehmen")
        let ribbons = builtRibbons(terrain)
        let waterRenderer = WaterFieldRenderer()
        let refWater = waterRenderer.bytes(terrain, blend: 1.0, geometryMode: true,
                                           bandChannelFlags: ribbons.bandChannelFlags,
                                           bandCoverage: ribbons.bandCoverage,
                                           bandOwner: ribbons.bandOwner)
        let refMaterial = WetMeadow.apply(
            TerrainColorRenderer.buffers(terrain, bars: BarMaterial.field(terrain)),
            mask: waterRenderer.wetMeadow)
        XCTAssertEqual(withBands,
                       referenceForest(terrain, colors: refMaterial.colors, surfaces: refMaterial.surfaces,
                                       bandCore: ribbons.bandVisibleCoverage, water: refWater,
                                       wetMeadow: waterRenderer.wetMeadow,
                                       protect: WaterProtectMask.bytes(
                                           n: terrain.cfg.n, bandCoverage: ribbons.bandCoverage,
                                           waterBytes: refWater, wetMeadow: waterRenderer.wetMeadow,
                                           barSand: BarMaterial.field(terrain).sand)))
    }

    func testBrushStrokeLeavesNoStaleForest() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        refresh(render, terrain)
        terrain.step(dtYears: 200)
        render.invalidate(terrain, .advanced)
        let before = refresh(render, terrain).forest
        XCTAssertNotEqual(before, refresh(RenderState(geometryMode: true), terrain).forest,
                          "Vorbedingung: das Gedächtnis hält nachwachsenden Wald")

        let n = Double(terrain.cfg.n)
        BrushTool.raise.apply(to: terrain, gx: n / 2, gz: n / 2,
                              radiusWorld: 25, strength: 40, target: 0)
        render.invalidate(terrain, .edited)
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain, .edited)
        let after = frameOverlays(render, terrain)

        XCTAssertNotEqual(before, after.forestMask, "Pinselstrich muss den Wald verändern")
        XCTAssertEqual(after.forestMask,
                       referenceForest(terrain, colors: after.colors, surfaces: after.surfaces,
                                       bandCore: render.bandCore, water: after.water,
                                       wetMeadow: render.wetMeadowMask, protect: after.protectMask),
                       "Der Wald folgt nicht dem Material und der Schutzmaske seines Frames")
    }

    func testRegenerateLeavesNoStaleForest() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let before = refresh(render, terrain).forest

        terrain.generate(seed: 9999)
        terrain.computeFlow()
        render.invalidate(terrain, .replaced)
        let after = refresh(render, terrain).forest

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), terrain).forest)
    }

    func testLoadLeavesNoStaleForest() throws {
        let saved = aged(seed: 4242)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("forest-mask-\(UUID().uuidString).rsworld").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try WorldSnapshot.write(saved, to: path)

        let render = RenderState(geometryMode: true)
        let before = refresh(render, aged()).forest
        let loaded = try WorldSnapshot.read(from: path)
        render.invalidate(loaded, .replaced)
        let after = refresh(render, loaded).forest

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), loaded).forest)
    }

    func testRegrowthIsDtInvariant() {
        let target: [UInt8] = [255, 200, 128, 60]
        let start: [Float] = [0, 0.1, 0.3, 0.2]
        let tau = CanopyRender.regrowYears
        var once = start
        let jump = ForestCanopyMask.regrow(&once, toward: target, dtYears: 600, tau: tau)
        var many = start
        var tick: [UInt8] = []
        for _ in 0..<24 {
            tick = ForestCanopyMask.regrow(&many, toward: target, dtYears: 25, tau: tau)
        }
        let rise = Float(1 - exp(-600 / tau))
        for k in target.indices {
            let t = Float(target[k]) / 255
            XCTAssertEqual(once[k], start[k] + (t - start[k]) * rise, accuracy: 1e-6)
            XCTAssertEqual(many[k], once[k], accuracy: 1e-5, "Zelle \(k)")
            XCTAssertLessThanOrEqual(abs(Int(tick[k]) - Int(jump[k])), 1, "Zelle \(k)")
            XCTAssertLessThan(jump[k], target[k], "nach 2 τ noch nicht ganz nachgewachsen")
        }
    }

    func testForestVanishesAtOnce() {
        let target: [UInt8] = [0, 40, 255]
        var memory: [Float] = [1, 1, 1]
        let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: 0,
                                          tau: CanopyRender.regrowYears)
        XCTAssertEqual(out, target)
        XCTAssertEqual(memory, target.map { Float($0) / 255 })
    }

    func testForestRegrowsOverSimYears() {
        let dt = 200.0
        func run() -> (memory: [UInt8], fresh: [UInt8], wet: [Bool]) {
            let terrain = aged()
            let render = RenderState(geometryMode: true)
            refresh(render, terrain)
            terrain.step(dtYears: dt)
            render.invalidate(terrain, .advanced)
            let (water, memory) = refresh(render, terrain)
            let cover = render.riverRibbonMesh.bandCoverage
            let river = byte01(WaterRender.protectRiverThreshold), lake = byte01(WaterRender.protectLakeThreshold)
            let wet = cover.indices.map {
                cover[$0] >= CanopyRender.retreatInstantBandCoverage
                    || water[$0 * 4] >= river || water[$0 * 4 + 1] >= lake
            }
            return (memory, refresh(RenderState(geometryMode: true), terrain).forest, wet)
        }
        let (memory, fresh, wet) = run()
        let rest = UInt8(min(255, (255 * (1 - Terrain.relaxFraction(dt: dt, tau: CanopyRender.retreatYears))).rounded(.up) + 1))
        var regrowing = 0, retreating = 0
        for k in fresh.indices {
            if wet[k] {
                XCTAssertLessThanOrEqual(memory[k], fresh[k], "Zelle \(k): Wald über Wasser")
            } else {
                XCTAssertLessThanOrEqual(Int(memory[k]), Int(fresh[k]) + Int(rest),
                                         "Zelle \(k): Wald weicht langsamer als der Rückzug")
            }
            if memory[k] < fresh[k] { regrowing += 1 }
            if memory[k] > fresh[k] { retreating += 1 }
        }
        XCTAssertGreaterThan(regrowing, 0, "Kein Wald wächst nach: Gedächtnis wirkungslos")
        XCTAssertEqual(run().memory, memory, "Gleiche Abfolge muss dieselbe Waldmaske liefern")
    }

    func testRegrowthHandlesNonPositiveAndNonFiniteDtSafely() {
        let target: [UInt8] = [0, 100, 200]
        let initialMemory: [Float] = [0.5, 0.2, 0.1]
        let tau = CanopyRender.regrowYears

        for badDt in [0.0, -0.0, -1.0, -500.0, Double.nan, Double.infinity, -Double.infinity] {
            var memory = initialMemory
            let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: badDt, tau: tau)

            XCTAssertEqual(out[0], 0, "Wasser muss Wald sofort vernichten bei dt = \(badDt)")
            XCTAssertEqual(memory[0], 0, "Gedächtnis muss sofort auf 0 fallen bei dt = \(badDt)")

            XCTAssertEqual(memory[1], initialMemory[1], "Gedächtnis darf nicht verändert werden bei dt = \(badDt)")
            XCTAssertEqual(memory[2], initialMemory[2], "Gedächtnis darf nicht verändert werden bei dt = \(badDt)")
            XCTAssertEqual(out[1], 51)
            XCTAssertEqual(out[2], 26)
        }

        var empty: [Float] = []
        let emptyOut = ForestCanopyMask.regrow(&empty, toward: [], dtYears: 100, tau: tau)
        XCTAssertEqual(emptyOut, [])
        XCTAssertEqual(empty, [])
    }

    func testRegrowthHandlesNonPositiveAndNonFiniteTauSafely() {
        let target: [UInt8] = [0, 100, 200]
        let initialMemory: [Float] = [0.5, 0.2, 0.1]

        for badTau in [0.0, -0.0, -1.0, -800.0, Double.nan, -Double.infinity] {
            var memory = initialMemory
            let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: 100.0, tau: badTau)

            XCTAssertEqual(out, target, "Sofortige Relaxation muss das Ziel liefern bei tau = \(badTau)")
            XCTAssertEqual(memory, target.map { Float($0) / 255 }, "Gedächtnis muss sofort Ziel erreichen bei tau = \(badTau)")
        }

        var memInf = initialMemory
        let outInf = ForestCanopyMask.regrow(&memInf, toward: target, dtYears: 100.0, tau: Double.infinity)
        XCTAssertEqual(outInf[0], 0)
        XCTAssertEqual(memInf[0], 0.0)
        XCTAssertEqual(memInf[1], initialMemory[1])
        XCTAssertEqual(memInf[2], initialMemory[2])
        XCTAssertEqual(outInf[1], 51)
        XCTAssertEqual(outInf[2], 26)
    }

    func testBandCoreUsesTheShaderVisibilityWindow() throws {
        let shader = try RepoSource.probe("game/shaders/water.gdshader")
        assertContains(shader, "smoothstep(\(glsl(WaterRender.ribbonVisibleLo)), \(glsl(WaterRender.ribbonVisibleHi)), mix(presence",
                       hint: "Fenster in water.gdshader und WaterRender.ribbonVisibleLo/Hi gemeinsam ändern")
        XCTAssertEqual(WaterRender.ribbonVisibleWidth(0), 0)
        XCTAssertEqual(WaterRender.ribbonVisibleWidth(1), 1)
    }

    func testRiparianForestLinesTheWater() {
        let n = 96
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        var state = terrain.state
        state.h = [Double](repeating: terrain.cfg.sea + 0.2, count: n * n)
        terrain.restore(state)
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        for k in 0..<(n * n) { surfaces[k * 4] = 15 }
        var core = [Double](repeating: 0, count: n * n)
        for j in 0..<n { core[j * n + 48] = 1 }
        let flat = [Float](repeating: 0, count: n * n)
        let noise = [Float](repeating: 0.6, count: n * n)
        let out = ForestCanopyMask.target(
            terrain, surfaces: surfaces, colors: [UInt8](repeating: 0, count: n * n * 4),
            bandCore: core, waterBytes: [], wetMeadow: [], barSand: [],
            clump: flat, riparianNoise: noise).mask
        for j in 4..<(n - 4) {
            for i in 47...49 { XCTAssertEqual(out[j * n + i], 0, "kein Wald am Wasser (\(i), \(j))") }
            XCTAssertEqual(out[j * n + 51], 255, "Galeriewald am Ufer (51, \(j))")
            XCTAssertEqual(out[j * n + 10], 0, "kein Wald fern vom Wasser (10, \(j))")
        }
    }

    func testRiparianCellsRegrowOverTheFastTau() {
        let target: [UInt8] = [255, 255]
        let fast = [true, false]
        let dt = 100.0, tau = CanopyRender.regrowYears, fastTau = CanopyRender.riparianRegrowYears
        XCTAssertLessThan(fastTau, tau, "Auwald wächst schneller als der übrige Wald")
        var memory: [Float] = [0, 0]
        let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: dt, tau: tau,
                                          fast: fast, fastTau: fastTau)
        XCTAssertEqual(Double(memory[0]), Terrain.relaxFraction(dt: dt, tau: fastTau), accuracy: 1e-6)
        XCTAssertEqual(Double(memory[1]), Terrain.relaxFraction(dt: dt, tau: tau), accuracy: 1e-6)
        XCTAssertGreaterThan(out[0], out[1])
        var split: [Float] = [0, 0]
        _ = ForestCanopyMask.regrow(&split, toward: target, dtYears: dt / 2, tau: tau, fast: fast, fastTau: fastTau)
        _ = ForestCanopyMask.regrow(&split, toward: target, dtYears: dt / 2, tau: tau, fast: fast, fastTau: fastTau)
        XCTAssertEqual(split[0], memory[0], accuracy: 1e-5)
        XCTAssertEqual(split[1], memory[1], accuracy: 1e-5)
        var plain: [Float] = [0, 0]
        _ = ForestCanopyMask.regrow(&plain, toward: target, dtYears: dt, tau: tau)
        XCTAssertEqual(plain[0], memory[1])
    }

    func testProtectMaskBlocksTheBaseForestButNotTheRiparianBand() {
        let n = 96
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        var state = terrain.state
        state.h = [Double](repeating: terrain.cfg.sea + 0.2, count: n * n)
        terrain.restore(state)
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        for k in 0..<(n * n) { surfaces[k * 4] = 255 }
        var core = [Double](repeating: 0, count: n * n)
        var protect = [UInt8](repeating: 0, count: n * n)
        for j in 0..<n {
            core[j * n + 48] = 1
            for i in 38...58 { protect[j * n + i] = 255 }
        }
        let out = ForestCanopyMask.target(
            terrain, surfaces: surfaces, colors: [UInt8](repeating: 0, count: n * n * 4),
            bandCore: core, waterBytes: [], wetMeadow: [], barSand: [],
            clump: [Float](repeating: 0, count: n * n),
            riparianNoise: [Float](repeating: 0.6, count: n * n), protect: protect).mask
        for j in 4..<(n - 4) {
            XCTAssertEqual(out[j * n + 51], 255, "Galeriewald trotz Sperre (51, \(j))")
            XCTAssertEqual(out[j * n + 57], 0, "kein Grundwald in der Sperre (57, \(j))")
            XCTAssertEqual(out[j * n + 20], 255, "Grundwald außerhalb (20, \(j))")
        }
    }

    func testCanopyGuardSeparatesBandsAndLakesFromRasterStreams() {
        let n = 64
        var band = [Double](repeating: 0, count: n * n)
        var water = [UInt8](repeating: 0, count: n * n * 4)
        var meadow = [Bool](repeating: false, count: n * n)
        let riverByte = byte01(WaterRender.protectRiverThreshold)
        let lakeByte = byte01(WaterRender.protectLakeThreshold)
        for j in 0..<n {
            band[j * n + 10] = 1
            water[(j * n + 30) * 4] = riverByte
            water[(j * n + 50) * 4 + 1] = lakeByte
        }
        meadow[20 * n + 40] = true
        let guardMask = WaterProtectMask.canopyGuard(n: n, bandCoverage: band, waterBytes: water,
                                                     wetMeadow: meadow)
        let j = 32
        XCTAssertEqual(guardMask.distance[j * n + 10], 0)
        XCTAssertEqual(Int(guardMask.distance[j * n + 13]), 3)
        XCTAssertEqual(guardMask.distance[j * n + 50], 0)
        XCTAssertEqual(Int(guardMask.distance[j * n + 47]), 3)
        XCTAssertEqual(guardMask.blocked[j * n + 10 + CanopyRender.waterSeamCells], 255)
        XCTAssertEqual(guardMask.blocked[j * n + 11 + CanopyRender.waterSeamCells], 0)
        XCTAssertEqual(guardMask.distance[j * n + 30], 255)
        XCTAssertEqual(guardMask.distance[20 * n + 40], 255)
        XCTAssertEqual(guardMask.blocked[j * n + 30 + WaterRender.protectSeamCells], 255)
        XCTAssertEqual(guardMask.blocked[j * n + 31 + WaterRender.protectSeamCells], 0)
        XCTAssertEqual(guardMask.blocked[20 * n + 40 + WaterRender.protectSeamCells], 255)
        XCTAssertEqual(guardMask.blocked[20 * n + 41 + WaterRender.protectSeamCells], 0)
    }

    func testTerrainShaderBuildsTheCanopyFromTheMask() throws {
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform sampler2D forest_tex",
                       hint: "WO Wald steht, sagt allein die Waldmaske aus SimRender")
        assertContains(shader, "v_lift = calib_window(canopy_lift_lo, canopy_lift_hi, lift_f);",
                       hint: "Das Dach hebt nach dem Anhebe-Fenster der Waldmaske an")
        assertContains(shader, "VERTEX.y += v_lift * canopy_height;",
                       hint: "Das Dach ist angehoben (Schattenwurf der Waldkanten)")
    }

    func testBridgeAndMainCarryTheCanopy() throws {
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "out[Variant(\"forest\")]",
                       hint: "Die Waldmaske kommt mit den Overlays des Frames")
        assertContains(bridge, "func calibration",
                       hint: "Die canopy_*-Zahlen kommen über das Register")
        XCTAssertFalse(bridge.contains("treeInstanceBuffer"),
                       "Instanzbäume sind seit #152 durch das Kronendach ersetzt")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        for needle in ["frame[\"forest\"]", "apply_calibration(sim, \"canopy\", [terrain_mat])"] {
            assertContains(main, needle, hint: "Main.gd liest Kronendach und Waldmaske über die Brücke")
        }
    }
}

enum CanopyWaterline {
    struct Summary {
        var points = 0
        var forested = 0
        var maxForest = 0.0
        var first: (Double, Double)?
    }

    static func forestAt(_ forest: [UInt8], _ gx: Double, _ gz: Double, n: Int) -> Double {
        let xi = min(max(Int(gx.rounded(.down)), 0), n - 2)
        let zi = min(max(Int(gz.rounded(.down)), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fz = min(max(gz - Double(zi), 0), 1)
        func f(_ i: Int, _ j: Int) -> Double { Double(forest[(zi + j) * n + xi + i]) / 255 }
        if fx + fz <= 1 {
            return f(0, 0) + fx * (f(1, 0) - f(0, 0)) + fz * (f(0, 1) - f(0, 0))
        }
        return f(1, 1) + (1 - fx) * (f(0, 1) - f(1, 1)) + (1 - fz) * (f(1, 0) - f(1, 1))
    }

    static func measure(_ t: Terrain, mesh: RibbonMesh, forest: [UInt8]) -> Summary {
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let reach = 1 - WaterRender.ribbonWaterline + WaterRender.ribbonWaterlineJitter
        var out = Summary()
        let starts = mesh.stripStarts.map(Int.init) + [mesh.vertices.count]
        for s in 0..<(starts.count - 1) {
            let lo = starts[s], hi = starts[s + 1]
            guard hi - lo >= 4 else { continue }
            for v in stride(from: lo, to: hi - 2, by: 2) {
                let L0 = SIMD3<Double>(mesh.vertices[v]), R0 = SIMD3<Double>(mesh.vertices[v + 1])
                let L1 = SIMD3<Double>(mesh.vertices[v + 2]), R1 = SIMD3<Double>(mesh.vertices[v + 3])
                let a0 = Double(mesh.colors[v].w), a1 = Double(mesh.colors[v + 2].w)
                for tt in stride(from: 0.0, through: 0.75, by: 0.25) {
                    let vis = WaterRender.ribbonVisibleWidth(a0 + (a1 - a0) * tt)
                    guard vis > 0 else { continue }
                    let du = 0.5 * reach * vis
                    for q in 0...8 {
                        let u = 0.5 - du + 2 * du * Double(q) / 8
                        let p: SIMD3<Double> = u + tt <= 1
                            ? L0 + u * (R0 - L0) + tt * (L1 - L0)
                            : R1 + (1 - u) * (L1 - R1) + (1 - tt) * (R0 - R1)
                        let gx = (p.x + half) / cs, gz = (p.z + half) / cs
                        guard gx >= 0, gz >= 0, gx <= Double(n - 1), gz <= Double(n - 1) else { continue }
                        let f = forestAt(forest, gx, gz, n: n)
                        out.points += 1
                        out.maxForest = max(out.maxForest, f)
                        if f > 0.002 {
                            out.forested += 1
                            if out.first == nil { out.first = (gx, gz) }
                        }
                    }
                }
            }
        }
        return out
    }

    static func report(_ s: Summary) -> String {
        String(format: "Bandwasser: %d Punkte, mit Wald %d = %.2f %%, max Maske %.2f",
               s.points, s.forested, 100 * Double(s.forested) / Double(max(1, s.points)), s.maxForest)
    }
}
