import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für das Kronendach (Issue #152).
///
/// WO Wald steht, rechnet `SimRender.ForestCanopyMask` auf der CPU; das ist
/// hier ausführbar geprüft:
///  - kein Wald über Rasterwasser, Seen und Flussbändern (auch nicht im
///    Filterabstand einer Zelle, den die lineare Textur verschmiert),
///  - kein Wald in Wänden, auf Schnee/Eis und im Ufersaum über dem Meer,
///  - gleiche Welt ergibt dieselbe Waldverteilung,
///  - Pinselstrich, Neugenerieren und Laden hinterlassen keinen veralteten Wald.
/// WIE er aussieht, rechnet der Terrain-Shader; davon ist headless nur die
/// STRUKTUR des Uniform-Wegs prüfbar (Muster `ReliefUniformsTests`).
final class CanopyTests: XCTestCase {

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    /// Der Render-Takt aus `Main.gd` — seit Issue #214 über den Frame: Bänder,
    /// Wasserfeld, Schutz- und Waldmaske entstehen gemeinsam und in dieser
    /// Reihenfolge (vorher stand sie hier von Hand).
    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], forest: [UInt8]) {
        let overlays = frameOverlays(render, terrain)
        return (overlays.water, overlays.forestMask)
    }

    // MARK: - Wasser

    /// Kein Wald über sichtbaren Flüssen, Seen und Bändern, und auch nicht in
    /// der Nachbarzelle: der Shader liest die Maske linear gefiltert.
    func testNoForestOverRiversLakesOrBands() {
        var c = renderConfig(n: 192)
        c.meanderBeltKernelWidths = calibrationBeltRenderKernelWidths
        c.meanderBeltSymmetricStamp = calibrationBeltSymmetricStamp
        let terrain = agedWorld(c, years: 2000, seed: 1337)
        let render = RenderState(geometryMode: true)
        let (water, forest) = refresh(render, terrain)
        let coverage = render.riverRibbonMesh.bandCoverage
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
        // Seit #168 (Schwellen damals 0,35/0,55, seit #174 0,40/0,60) trägt die Testwelt 2013 geschlossene
        // Waldzellen (5,5 % aller Zellen); die alte Grenze n²/20 (1843) ließ
        // kaum Luft. n²/40 verlangt weiter über 900 geschlossene Waldzellen.
        XCTAssertGreaterThan(forest.filter { $0 == 255 }.count, n * n / 40,
                             "Testwelt braucht geschlossenen Wald, sonst prüft der Test nichts")
    }

    // MARK: - Gelände

    /// Volle Vegetation überall; der Wald fehlt genau in der Wand, auf Schnee
    /// und im Ufersaum. Synthetisch, damit jede Schwelle allein wirkt.
    func testNoForestOnWallsSnowOrShore() {
        let n = 96
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        let sea = terrain.cfg.sea
        // Höhe je Zelle für eine Weltsteigung `s` in x-Richtung.
        let perCell = terrain.cfg.world / Double(n) / RenderContract.heightScale
        var state = terrain.state
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                surfaces[k * 4] = 255
                switch i {
                case ..<24:  state.h[k] = sea + 0.2                                  // Ebene
                case ..<48:  state.h[k] = sea + 0.2 + Double(i - 24) * perCell * 2.5 // Wand
                case ..<72:  state.h[k] = sea + 0.2; surfaces[k * 4 + 2] = 255        // Schnee
                default:     state.h[k] = sea + CanopyRender.shoreLo * 0.5            // Ufersaum
                }
            }
        }
        terrain.restore(state)
        let forest = ForestCanopyMask.bytes(terrain, surfaces: surfaces,
                                            protect: [UInt8](repeating: 0, count: n * n),
                                            clump: [Float](repeating: 0, count: n * n))
        // Die Randzeilen tragen keinen Makro-Stencil (±2 Zellen); dort ist sonst Meer.
        for j in 2..<(n - 2) {
            for i in [4, 20] { XCTAssertEqual(forest[j * n + i], 255, "Ebene trägt Wald (\(i), \(j))") }
            for i in [30, 40, 60, 66, 80, 90] {
                XCTAssertEqual(forest[j * n + i], 0, "Wald an (\(i), \(j))")
            }
        }
    }

    /// Nur dichte Vegetation wird Wald (Issue #168): bei mittlerem
    /// Vegetationsgewicht (0,3, bis #168 schon geschlossener Wald) bleibt
    /// Wiese, ab 0,7 steht geschlossener Bestand. Ebene, ohne Rauschen.
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
        XCTAssertEqual(forest(vegetation: 0.3), 0, "Mittlere Vegetation bleibt Wiese")
        XCTAssertEqual(forest(vegetation: 0.7), 255, "Dichte Vegetation ist geschlossener Wald")
    }

    /// Ohne Schrittweite (`cellSize == 0`: `world <= 0` oder nicht-endlich)
    /// wäre die Weltsteigung ±inf/NaN und der Wald still falsch; die Maske
    /// bleibt leer wie bei jeder anderen unpassenden Eingabe.
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

    // MARK: - Determinismus und Invalidierung

    func testSameWorldYieldsIdenticalForest() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Waldverteilung liefern")
    }

    /// Der Wald folgt beiden Quellen der Schutzmaske: dem Band-Bau ebenso wie
    /// dem Wasser-Upload. Seit Issue #214 über den Frame: der Zustand MIT
    /// Bändern (`geometryMode` wahr) gegen denselben Stand im Raster-Stempel-
    /// Modus (`RS_WATER_STAMP`, keine Bänder) — zwei Frames, derselbe Takt.
    func testForestFollowsTheProtectMask() {
        let terrain = aged()
        let withBands = refresh(RenderState(geometryMode: true), terrain).forest
        let withoutBands = refresh(RenderState(geometryMode: false), terrain).forest
        XCTAssertNotEqual(withoutBands, withBands, "Band-Bau muss den Wald zurücknehmen")
        // Ableitung aus denselben Quellen wie der Frame: Wald gegen die
        // Renderer-Dieselben dieses Standes (Bänder → Wasser → Schutz).
        // `bandOwner` mitgegeben: Der Frame reicht das ECHTE Bau-Ergebnis
        // inklusive Eigner weiter (Abzweig-Zellen, s. `WaterFieldRenderer`),
        // die Referenz muss dasselbe Feld lesen.
        let ribbons = builtRibbons(terrain)
        let waterRenderer = WaterFieldRenderer()
        let refWater = waterRenderer.bytes(terrain, blend: 1.0, geometryMode: true,
                                           bandChannelFlags: ribbons.bandChannelFlags,
                                           bandCoverage: ribbons.bandCoverage,
                                           bandOwner: ribbons.bandOwner)
        let refProtect = WaterProtectMask.bytes(n: terrain.cfg.n,
                                                bandCoverage: ribbons.bandCoverage,
                                                waterBytes: refWater,
                                                wetMeadow: waterRenderer.wetMeadow,
                                                barSand: BarMaterial.field(terrain).sand)
        let refSurfaces = WetMeadow.apply(
            TerrainColorRenderer.buffers(terrain, bars: BarMaterial.field(terrain)),
            mask: waterRenderer.wetMeadow).surfaces
        XCTAssertEqual(withBands,
                       ForestCanopyMask.bytes(terrain, surfaces: refSurfaces,
                                              protect: refProtect,
                                              clump: ForestCanopyMask.clumpField(
                                                  n: terrain.cfg.n, world: terrain.cfg.world)))
    }

    /// Pinselstrich (über `BrushTool`, wie die Brücke): nach dem Render-Takt
    /// steht der Wald genau dort, wo Terrain, Material und Schutzmaske des
    /// FRAMES ihn hinlegen — aus nichts Gecachtem. Vorher läuft die Sim, damit
    /// das Gedächtnis der Waldmaske (#167) etwas hält, das der Pinsel
    /// verwerfen muss.
    ///
    /// Bewusst KEIN Vergleich gegen einen frischen Render-Zustand (wie bei der
    /// Schutzmaske, s. dort): der Frame deckelt den Band-Neubau an der
    /// Zentrumslinien-Bewegung, ein Pinsel bewegt die Linien nicht — die
    /// Bänder des gebrauchteren Zustands sind legitim andere. Statt dessen die
    /// Neuberechnung aus den Eingaben DES Frames; `.edited` leert das
    /// Gedächtnis, `regrow` übernimmt also genau dieses Ziel.
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
                       ForestCanopyMask.bytes(terrain, surfaces: after.surfaces,
                                              protect: after.protectMask,
                                              clump: ForestCanopyMask.clumpField(
                                                  n: terrain.cfg.n, world: terrain.cfg.world)),
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

    // MARK: - Gedächtnis (Issue #167)

    /// Ein großer Schritt ergibt dasselbe wie viele kleine (AGENTS.md
    /// § Framerate-Unabhängigkeit), und zwar die exponentielle Relaxation.
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

    /// Kommt Wasser (oder geht die Vegetation zurück), ist der Wald sofort weg,
    /// auch ohne verstrichene Sim-Zeit.
    func testForestVanishesAtOnce() {
        let target: [UInt8] = [0, 40, 255]
        var memory: [Float] = [1, 1, 1]
        let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: 0,
                                          tau: CanopyRender.regrowYears)
        XCTAssertEqual(out, target)
        XCTAssertEqual(memory, target.map { Float($0) / 255 })
    }

    /// Im Render-Takt: nach einem Sim-Schritt steht über sichtbarem Wasser
    /// kein Wald mehr als in der frischen Maske; ohne Wasser höchstens der
    /// Rest des Rückzugs über die Schrittdauer (`CanopyRender.retreatYears`,
    /// Befund Punkt 50). Wo er zurückkommt, wächst er erst nach. Gleiche
    /// Abfolge ergibt dieselben Bytes.
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
        // Rest des Rückzugs nach `dt` (plus eine Byte-Rundung).
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

    /// Nicht-positive sowie nicht-endliche Zeitschritte (dtYears <= 0, NaN, ±inf)
    /// dürfen das Gedächtnis nicht vergiften und führen zu keinem Nachwachsen;
    /// sofortiger Rückgang bei Wasser bleibt intakt und leere Puffer trappen nicht.
    func testRegrowthHandlesNonPositiveAndNonFiniteDtSafely() {
        let target: [UInt8] = [0, 100, 200]
        let initialMemory: [Float] = [0.5, 0.2, 0.1]
        let tau = CanopyRender.regrowYears

        for badDt in [0.0, -0.0, -1.0, -500.0, Double.nan, Double.infinity, -Double.infinity] {
            var memory = initialMemory
            let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: badDt, tau: tau)

            // Index 0: target 0 <= memory 0.5 -> sofortiger Rückgang auf Ziel
            XCTAssertEqual(out[0], 0, "Wasser muss Wald sofort vernichten bei dt = \(badDt)")
            XCTAssertEqual(memory[0], 0, "Gedächtnis muss sofort auf 0 fallen bei dt = \(badDt)")

            // Nicht-positive oder ungültige dt: kein Nachwachsen, altes Gedächtnis bleibt
            XCTAssertEqual(memory[1], initialMemory[1], "Gedächtnis darf nicht verändert werden bei dt = \(badDt)")
            XCTAssertEqual(memory[2], initialMemory[2], "Gedächtnis darf nicht verändert werden bei dt = \(badDt)")
            XCTAssertEqual(out[1], 51)
            XCTAssertEqual(out[2], 26)
        }

        // Leere Puffer dürfen nicht trappen (nil-baseAddress Guard)
        var empty: [Float] = []
        let emptyOut = ForestCanopyMask.regrow(&empty, toward: [], dtYears: 100, tau: tau)
        XCTAssertEqual(emptyOut, [])
        XCTAssertEqual(empty, [])
    }

    /// Nicht-positive sowie nicht-endliche Zeitkonstanten (tau <= 0, NaN)
    /// führen defensiv zu sofortiger Relaxation auf das Ziel (rise = 1);
    /// tau = +inf führt zu keinem Nachwachsen (verschwindende Rate).
    func testRegrowthHandlesNonPositiveAndNonFiniteTauSafely() {
        let target: [UInt8] = [0, 100, 200]
        let initialMemory: [Float] = [0.5, 0.2, 0.1]

        for badTau in [0.0, -0.0, -1.0, -800.0, Double.nan, -Double.infinity] {
            var memory = initialMemory
            let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: 100.0, tau: badTau)

            XCTAssertEqual(out, target, "Sofortige Relaxation muss das Ziel liefern bei tau = \(badTau)")
            XCTAssertEqual(memory, target.map { Float($0) / 255 }, "Gedächtnis muss sofort Ziel erreichen bei tau = \(badTau)")
        }

        // tau = +inf: Zeitkonstante unendlich -> kein Nachwachsen
        var memInf = initialMemory
        let outInf = ForestCanopyMask.regrow(&memInf, toward: target, dtYears: 100.0, tau: Double.infinity)
        XCTAssertEqual(outInf[0], 0)
        XCTAssertEqual(memInf[0], 0.0)
        XCTAssertEqual(memInf[1], initialMemory[1])
        XCTAssertEqual(memInf[2], initialMemory[2])
        XCTAssertEqual(outInf[1], 51)
        XCTAssertEqual(outInf[2], 26)
    }

    // MARK: - Uniform-Weg (Struktur)

    /// Die `canopy_*`-Zahlen selbst (Spiegel, default-freie Deklaration,
    /// nichts am Register vorbei) prüft `CalibrationRegistryTests`; hier
    /// bleibt, WIE der Terrain-Shader das Dach baut.
    func testTerrainShaderBuildsTheCanopyFromTheMask() throws {
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform sampler2D forest_tex",
                       hint: "WO Wald steht, sagt allein die Waldmaske aus SimRender")
        assertContains(shader,
                       "VERTEX.y += calib_window(canopy_lift_lo, canopy_lift_hi, v_forest) * canopy_height;",
                       hint: "Das Dach ist angehoben (Schattenwurf der Waldkanten)")
    }

    func testBridgeAndMainCarryTheCanopy() throws {
        let bridge = try RepoSource.extensionSources()
        // Die Waldmaske reist im Frame (Issue #214), die `canopy_*`-Zahlen über
        // das Kalibrier-Register (#213) — Einzel-Callables gibt es keine mehr.
        assertContains(bridge, "out[Variant(\"forest\")]",
                       hint: "Die Waldmaske kommt mit den Overlays des Frames")
        assertContains(bridge, "func calibration",
                       hint: "Die canopy_*-Zahlen kommen über das Register")
        XCTAssertFalse(bridge.contains("treeInstanceBuffer"),
                       "Instanzbäume sind seit #152 durch das Kronendach ersetzt")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        // Die Waldmaske kommt seit #94 mit dem Frame (`RenderFrameTests`).
        for needle in ["frame[\"forest\"]", "apply_calibration(sim, \"canopy\", [terrain_mat])"] {
            assertContains(main, needle, hint: "Main.gd liest Kronendach und Waldmaske über die Brücke")
        }
    }
}
