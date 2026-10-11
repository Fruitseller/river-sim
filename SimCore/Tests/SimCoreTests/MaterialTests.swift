import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter der geomorphologischen Materialverteilung (Issue #174, Paket D).
///
/// WO Fels, Schutthalde, Gletschereis, Rohboden und Talboden-Wiese liegen,
/// rechnet `SimRender.TerrainColorRenderer` auf der CPU; das ist hier
/// ausführbar geprüft:
///  - die Gewichte summieren sich auf höchstens 1 (der Shader mischt sie als
///    Gewichtssumme, der Rest ist Grund),
///  - Fels sitzt auf steilen, konvexen Formen, Halden in Hohlformen unter Fels,
///  - blankes Eis nur im Zehrgebiet, darüber Firn (liest sich als Schnee),
///  - brauner Rohboden nur, wo der Pinsel gestört hat,
///  - Talboden-Wiese auf flachem Tiefland, nicht am Hang.
/// WIE es aussieht, rechnet der Terrain-Shader; davon ist headless nur die
/// STRUKTUR des Uniform-Wegs prüfbar (Muster `CanopyTests`).
/// Flächenanteile auf den Matrix-Welten: `testMaterialCoverageDiagnostic`.
final class MaterialTests: XCTestCase {

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    private func weight(_ buffer: [UInt8], _ k: Int, _ channel: Int) -> Double {
        Double(buffer[k * 4 + channel]) / 255
    }

    // MARK: - Gewichte

    /// Vegetation + Fels + Kälte + Halde + Rohboden ≤ 1 je Zelle (bis auf die
    /// Byte-Rundung), auch nach einem Pinselstrich, der Rohboden erzeugt.
    func testWeightsNeverExceedOne() {
        let terrain = aged()
        let n = terrain.cfg.n
        terrain.sculpt(gx: Double(n) / 2, gz: Double(n) / 2, radiusWorld: 6, dir: -1, strength: 2)
        let b = TerrainColorRenderer.buffers(terrain)
        XCTAssertEqual(b.covers.count, n * n * 4)
        var worst = 0.0
        for k in 0..<(n * n) {
            let sum = weight(b.surfaces, k, 0) + weight(b.surfaces, k, 1) + weight(b.surfaces, k, 2)
                + weight(b.covers, k, 0) + weight(b.covers, k, 2)
            worst = max(worst, sum)
        }
        XCTAssertLessThanOrEqual(worst, 1 + 5.0 / 255, "Materialgewichte summieren sich über 1")
    }

    /// Gleiche Welt, gleiche Puffer (der Pass läuft parallel über disjunkte
    /// Zeilen und muss bit-identisch zur sequenziellen Schleife sein).
    func testSameWorldYieldsIdenticalCovers() {
        let a = TerrainColorRenderer.buffers(aged())
        let b = TerrainColorRenderer.buffers(aged())
        XCTAssertEqual(a.covers, b.covers)
        XCTAssertEqual(a.surfaces, b.surfaces)
    }

    func testEmptyTerrainYieldsEmptyCovers() {
        let empty = Terrain(allocating: renderConfig(n: 0), seed: 1337)
        XCTAssertEqual(TerrainColorRenderer.buffers(empty).covers, [])
        XCTAssertEqual(RenderState().terrainCoverBytes(empty), [])
    }

    // MARK: - Fels und Halde

    /// Fels wächst mit der Steigung und bricht auf Graten früher durch als in
    /// Rinnen; die Halde braucht Fels in Reichweite, eine Hohlform und eine
    /// Steigung im Schüttwinkel.
    func testRockPrefersSteepConvexAndScreeConcaveBelowRock() {
        let mid = (MaterialRender.rockSlopeLo + MaterialRender.rockSlopeHi) / 2
        XCTAssertEqual(TerrainColorRenderer.rockTarget(worldSlope: 0.2, convexity: 0), 0)
        XCTAssertEqual(TerrainColorRenderer.rockTarget(worldSlope: 5, convexity: 0), 1)
        let ridge = TerrainColorRenderer.rockTarget(worldSlope: mid, convexity: MaterialRender.convexRef)
        let plain = TerrainColorRenderer.rockTarget(worldSlope: mid, convexity: 0)
        let gully = TerrainColorRenderer.rockTarget(worldSlope: mid, convexity: -MaterialRender.convexRef)
        XCTAssertGreaterThan(ridge, plain, "Grate tragen früher Fels")
        XCTAssertGreaterThan(plain, gully, "Rinnen tragen später Fels")

        let slope = MaterialRender.screeSlopeHi + 0.1
        let concave = -MaterialRender.screeConcavity
        XCTAssertEqual(TerrainColorRenderer.screeTarget(worldSlope: slope, source: 1, convexity: concave), 1)
        XCTAssertEqual(TerrainColorRenderer.screeTarget(worldSlope: slope, source: 0, convexity: concave), 0,
                       "Keine Halde ohne Fels in Reichweite")
        XCTAssertEqual(TerrainColorRenderer.screeTarget(worldSlope: slope, source: 1, convexity: 0.05), 0,
                       "Keine Halde auf Rippen")
        XCTAssertEqual(TerrainColorRenderer.screeTarget(worldSlope: 0.1, source: 1, convexity: concave), 0,
                       "Keine Halde auf flachem Boden")
    }

    /// Auf einer gealterten Welt liegt der Fels im Mittel steiler und
    /// konvexer als Halde und Bewuchs, und jede Halde hat Fels in Reichweite.
    func testAgedWorldPutsRockOnSteepRidgesAndScreeBelow() {
        let terrain = aged()
        let n = terrain.cfg.n
        let h = terrain.h
        let b = TerrainColorRenderer.buffers(terrain)
        let slopeScale = 2 * RenderContract.heightScale / terrain.cfg.cellSize
        var rock: [(Double, Double)] = [], scree: [(Double, Double)] = [], veg: [(Double, Double)] = []
        let r = MaterialRender.screeReachCells
        for j in (2 + r)..<(n - 2 - r) {
            for i in (2 + r)..<(n - 2 - r) {
                let k = j * n + i
                guard h[k] > terrain.cfg.sea + 0.012 else { continue }
                let site = (Terrain.macroSlope(h, k, n) * slopeScale,
                            TerrainColorRenderer.convexity(h, k, n) * RenderContract.heightScale)
                if weight(b.surfaces, k, 1) >= 0.5 { rock.append(site) }
                if weight(b.covers, k, 0) >= 0.5 {
                    scree.append(site)
                    var near = 0.0
                    for dj in -r...r { for di in -r...r { near = max(near, weight(b.surfaces, k + dj * n + di, 1)) } }
                    XCTAssertGreaterThan(near, 0.1, "Halde an (\(i), \(j)) ohne Fels in Reichweite")
                }
                if weight(b.surfaces, k, 0) >= 0.3 { veg.append(site) }
            }
        }
        func mean(_ a: [(Double, Double)], _ f: ((Double, Double)) -> Double) -> Double {
            a.map(f).reduce(0, +) / Double(max(a.count, 1))
        }
        XCTAssertGreaterThan(rock.count, 50, "Testwelt braucht Fels")
        XCTAssertGreaterThan(scree.count, 20, "Testwelt braucht Halden")
        XCTAssertGreaterThan(veg.count, 50, "Testwelt braucht Bewuchs")
        XCTAssertGreaterThan(mean(rock, \.0), mean(veg, \.0), "Fels steiler als Bewuchs")
        XCTAssertGreaterThan(mean(rock, \.1), mean(scree, \.1), "Fels konvexer als Halde")
        XCTAssertLessThan(mean(scree, \.1), 0, "Halden liegen in Hohlformen")
    }

    // MARK: - Schnee und Gletscher

    /// Blankes Eis nur im Zehrgebiet (über 0 °C), darüber Firn; ohne Eis
    /// keines. Die Kältedeckung (B von `surfaces`) bleibt in allen drei Fällen
    /// voll — Wald und Kronendach sehen Schnee und Eis gleich.
    func testBareIceOnlyBelowTheEquilibriumLine() {
        let terrain = aged()
        let n = terrain.cfg.n
        var state = terrain.state
        let land = (0..<(n * n)).first { k in
            let i = k % n, j = k / n
            return i > 4 && i < n - 4 && j > 4 && j < n - 4 && state.h[k] > terrain.cfg.sea + 0.05
        }!
        XCTAssertEqual(state.ice.count, n * n, "Testwelt braucht das Klima")
        let tongue = land, firn = land + 1, snowfield = land + 2
        for k in [tongue, firn, snowfield] { state.snow[k] = 0; state.ice[k] = 0 }
        state.ice[tongue] = 0.2; state.temperature[tongue] = 3
        state.ice[firn] = 0.2; state.temperature[firn] = -3
        state.snow[snowfield] = 2; state.temperature[snowfield] = -3
        terrain.restore(state)
        let b = TerrainColorRenderer.buffers(terrain)
        XCTAssertGreaterThan(weight(b.covers, tongue, 1), 0.9, "Zunge im Zehrgebiet ist blankes Eis")
        XCTAssertEqual(weight(b.covers, firn, 1), 0, "Nährgebiet ist Firn")
        XCTAssertEqual(weight(b.covers, snowfield, 1), 0, "Schnee ohne Eis ist kein Gletscher")
        for k in [tongue, firn, snowfield] {
            XCTAssertGreaterThan(weight(b.surfaces, k, 2), 0.9, "Kältedeckung bleibt voll (\(k))")
        }
    }

    // MARK: - Rohboden

    /// Ohne Eingriff gibt es keinen Rohboden; ein Pinselstrich legt ihn frei,
    /// und er klingt mit der Regeneration der Sim wieder ab.
    func testRawSoilOnlyOnDisturbedGround() {
        let terrain = aged()
        let n = terrain.cfg.n
        XCTAssertTrue(TerrainColorRenderer.buffers(terrain).covers.enumerated()
                        .allSatisfy { $0.offset % 4 != 2 || $0.element == 0 },
                      "Rohboden ohne Eingriff")
        terrain.sculpt(gx: Double(n) / 2, gz: Double(n) / 2, radiusWorld: 6, dir: 1, strength: 2)
        let after = TerrainColorRenderer.buffers(terrain).covers
        var raw = 0
        for k in 0..<(n * n) where after[k * 4 + 2] > 0 {
            raw += 1
            XCTAssertGreaterThan(terrain.disturb[k], 0, "Rohboden nur auf gestörten Zellen")
        }
        XCTAssertGreaterThan(raw, 0, "Pinselstrich legt Rohboden frei")
        terrain.step(dtYears: terrain.cfg.disturbanceRecoveryYears * 6)
        let healed = TerrainColorRenderer.buffers(terrain).covers
        XCTAssertLessThan((0..<(n * n)).filter { healed[$0 * 4 + 2] > 0 }.count, raw,
                          "Rohboden wächst wieder zu")
    }

    // MARK: - Talboden

    /// Talboden-Wiese nur auf flachem Tiefland: flach unter dem Nadelwald-Band
    /// ja, steil oder hoch nein.
    func testValleyMeadowOnFlatLowlandOnly() {
        var config = renderConfig(n: 64)
        config.world = 10 // Zellgröße wie in Produktion (~0,156)
        let terrain = Terrain(config: config, seed: 1337)
        let n = terrain.cfg.n
        let bands = terrain.heightBands
        var state = terrain.state
        let perCell = terrain.cfg.cellSize / RenderContract.heightScale
        let low = max(terrain.cfg.sea + 0.05, bands.coniferLow - 0.05)
        let high = bands.coniferHigh + 0.05
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                switch i {
                case ..<20: state.h[k] = low                                       // Talboden
                case ..<40: state.h[k] = low + Double(i - 20) * perCell * 1.5       // Hang
                default:    state.h[k] = high                                      // Hochfläche
                }
            }
        }
        terrain.restore(state)
        let covers = TerrainColorRenderer.buffers(terrain).covers
        for j in 4..<(n - 4) {
            XCTAssertGreaterThan(weight(covers, j * n + 10, 3), 0.9, "Talboden an (10, \(j))")
            XCTAssertEqual(weight(covers, j * n + 30, 3), 0, "Kein Talboden am Hang (30, \(j))")
            XCTAssertEqual(weight(covers, j * n + 55, 3), 0, "Kein Talboden über dem Band (55, \(j))")
        }
    }

    // MARK: - Uniform-Weg (Struktur)

    func testEveryTableValueComesFromMaterialRender() {
        let mirror: [String: Double] = [
            "material_ridge_rock_gain": MaterialRender.ridgeRockGain,
            "material_gully_scree_share": MaterialRender.gullyScreeShare,
            "material_joint_spacing": MaterialRender.jointSpacing,
            "material_joint_depth": MaterialRender.jointDepth,
            "material_scree_grain": MaterialRender.screeGrain,
            "material_crevasse_spacing": MaterialRender.crevasseSpacing,
            "material_crevasse_slope_lo": MaterialRender.crevasseSlopeLo,
            "material_crevasse_slope_hi": MaterialRender.crevasseSlopeHi,
            "material_moraine_lo": MaterialRender.moraineLo,
            "material_moraine_hi": MaterialRender.moraineHi,
        ]
        XCTAssertEqual(MaterialUniforms.scalars.count, mirror.count,
                       "Tabellen-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in MaterialUniforms.scalars {
            XCTAssertEqual(entry.value, mirror[entry.name],
                           "\(entry.name) trägt nicht seine MaterialRender-Konstante")
        }
    }

    /// Der Terrain-Shader deklariert jede Tabellen-Zahl default-frei, liest
    /// sie und deklariert keine `material_*`-Zahl an der Tabelle vorbei.
    func testTerrainShaderReadsExactlyTheTable() throws {
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        for entry in MaterialUniforms.scalars {
            assertContains(shader, "uniform float \(entry.name);",
                           hint: "\(entry.name) default-frei deklariert (Muster #92)")
            XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: entry.name), 2,
                                        "\(entry.name) wird deklariert, aber nie gelesen")
        }
        let declared = try shader.pairs(pattern: "uniform\\s+([A-Za-z0-9_]+)\\s+(material_[A-Za-z0-9_]+)")
        for (kind, name) in declared where kind == "float" {
            XCTAssertTrue(MaterialUniforms.scalars.contains { $0.name == name },
                          "terrain.gdshader deklariert \(name) an MaterialUniforms vorbei")
        }
        assertContains(shader, "uniform sampler2D cover_tex",
                       hint: "WO Schutt, Eis, Rohboden und Talboden liegen, sagt allein cover_tex")
        XCTAssertFalse(shader.contains("study_material"),
                       "Die PBR-Materialien der Studie sind durch #174 D ersetzt")
    }

    func testBridgeAndMainCarryTheMaterials() throws {
        let bridge = try RepoSource.extensionSources()
        for needle in ["func materialUniformNames", "func materialUniformValues",
                       "MaterialUniforms.scalars", "out[Variant(\"cover\")]"] {
            assertContains(bridge, needle, hint: "Brücke marshallt Material-Kalibrierung und Bodenbedeckung")
        }
        let main = try RepoSource.probe("game/scripts/Main.gd")
        for needle in ["materialUniformNames()", "materialUniformValues()", "frame[\"cover\"]",
                       "static func material_calibration"] {
            assertContains(main, needle, hint: "Main.gd liest Material und Bodenbedeckung über die Brücke")
        }
    }

    /// Wolkenkörper und Wolkenschatten teilen EINE Rauschquelle (#174 D): der
    /// Körper-Shader bindet das gemeinsame Include und rechnet seine Deckung
    /// mit derselben Funktion wie der Schatten, alle drei Schatten-Shader
    /// übergeben die Weltposition samt Höhe (Projektion entlang der Sonne).
    func testCloudBodiesShareTheShadowNoise() throws {
        let body = try RepoSource.file("game/shaders/cloud_body.gdshader")
        XCTAssertTrue(body.contains("\n#include \"res://shaders/clouds.gdshaderinc\"\n"),
                      "Wolkenkörper lesen dieselbe Rauschquelle wie die Schatten")
        XCTAssertTrue(body.contains("float density = cloud_density(xz, u_time);"),
                      "Körper aus derselben Dichte wie der Schatten")
        let include = try RepoSource.file("game/shaders/clouds.gdshaderinc")
        XCTAssertTrue(include.contains("return 1.0 - cloud_cover(at, t) * cloud_strength;"),
                      "Schatten aus derselben Deckung wie der Körper")
        for path in ["game/shaders/terrain.gdshader", "game/shaders/water.gdshader",
                     "game/shaders/ocean.gdshader"] {
            let shader = try RepoSource.probe(path)
            XCTAssertTrue(try shader.captures(pattern: "cloud_light\\(([^,]+),").allSatisfy {
                !$0.hasSuffix(".xz") && !$0.contains("world_size * 0.5")
            }, "\(path) übergibt die Weltposition mit Höhe")
        }
    }
}
