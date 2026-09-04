import XCTest
@testable import SimCore

/// Wächter für `RenderContract` (Issue #51): die Zahlen, die Godot-Schicht,
/// GDExtension und Shader gemeinsam annehmen müssen.
///
/// Warum hier und warum als Textvergleich: `game/scripts/Main.gd` und die
/// Shader sind headless nicht ausführbar, ihr Quelltext aber lesbar (s.
/// `RepoSource`). Genau in dieser Lücke ist die Drift entstanden, die dieser
/// Vertrag beendet — der Shader-Default von `hscale` stand auf 26.0, während
/// `Main.gd` mit 24.0 rechnete.
final class RenderContractTests: XCTestCase {

    /// Ein FPS-Deckel reicht im Pausezustand nicht: Auch 30 Retina-Frames pro
    /// Sekunde lasten die GPU aus, obwohl sich die Welt nicht ändert. Nach der
    /// Leerlauffrist muss Main deshalb den Renderloop ganz abschalten und ihn
    /// bei der nächsten Eingabe wieder einschalten. Fensterleisten-Aktionen
    /// (Maximieren, Resize) erzeugen kein InputEvent und brauchen einen eigenen
    /// Weckruf — sonst steht das eingefrorene Pausebild skaliert im neuen
    /// Fenster, ausgerechnet beim Maximieren fürs Messprozedere (AGENTS.md).
    func testPausedIdleDisablesRenderLoop() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "RenderingServer.render_loop_enabled = false",
                       hint: "Pause-Leerlauf zeichnet keine Frames")
        assertContains(main, "RenderingServer.render_loop_enabled = true",
                       hint: "Eingabe weckt den Renderloop wieder auf")
        assertContains(main, "NOTIFICATION_WM_SIZE_CHANGED",
                       hint: "Fenster-Resize/Maximieren weckt den Renderloop (kein InputEvent)")
        assertContains(main, "NOTIFICATION_WM_WINDOW_FOCUS_IN",
                       hint: "Fokuswechsel weckt den Renderloop (kein InputEvent)")

        // Der Leerlauf-Ausstieg: whitespace-tolerant statt an exakte Tabs
        // gebunden (eine kosmetische Umformatierung ist kein Vertragsbruch)
        // — und POSITIONIERT: er muss NACH dem Renderloop-Umschalter stehen
        // (sonst würde nie suspendiert) und VOR dem Sim-Schritt (sonst
        // steppte die Pause weiter, nur unsichtbar).
        let code = main.code
        let exit = code.range(of: #"if idle:\s+return"#, options: .regularExpression)
        XCTAssertNotNil(exit,
                        "Leerlauf überspringt auch Shader-, Kamera- und Raycast-Arbeit")
        let toggle = code.range(of: "render_loop_suspended = idle")
        XCTAssertNotNil(toggle, "Leerlauf-Zustand schaltet den Renderloop um")
        let simStep = code.range(of: "if _simulation_should_step(")
        XCTAssertNotNil(simStep, "Sim-Schritt-Gate fehlt (s. testSculptingOwnsTheSimulationClock)")
        if let exit, let toggle, let simStep {
            XCTAssertLessThan(toggle.upperBound, exit.lowerBound,
                              "Der Leerlauf-Ausstieg muss nach dem Renderloop-Umschalter stehen")
            XCTAssertLessThan(exit.upperBound, simStep.lowerBound,
                              "Der Leerlauf-Ausstieg muss vor dem Sim-Schritt stehen")
        }
    }

    /// Der Brush lädt seine Höhe sofort hoch und zieht das globale Flussnetz
    /// selbst nach. Ein paralleler `sim.step` würde dieselben Zellen davor
    /// weiterentwickeln und bei 60 J/s Wirkung und Hauptthreadzeit streitig
    /// machen. Die Tempowahl bleibt stehen; nur aktive Striche sperren Schritte.
    func testSculptingOwnsTheSimulationClock() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "if _simulation_should_step(year_rate, sculpting):",
                       hint: "Zeitraffer tritt während eines Werkzeugstrichs zurück")
    }

    /// Die zusätzlichen Shader-Rinnen gleichen den SICHTBAREN Alterungskontrast
    /// aus, ohne die Sim-Höhen nachträglich umzuschreiben: jung schwächer als der
    /// frühere konstante Wert 0.30, alt stärker, dazwischen glatt und gedeckelt.
    func testTerrainDetailCounterbalancesVisualAging() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(main, "const TERRAIN_DETAIL_YOUNG := 0.16",
                       hint: "Jahr 0 überzeichnet die Rinnen nicht")
        assertContains(main, "const TERRAIN_DETAIL_OLD := 0.42",
                       hint: "100k behält sichtbare Reliefstruktur")
        assertContains(main, "const TERRAIN_DETAIL_AGE_YEARS := 100000.0",
                       hint: "Rampe endet am größten UI-Zeitsprung")
        assertContains(main,
                       "set_shader_parameter(\"detail_strength\", terrain_detail_strength(sim.currentYear()))",
                       hint: "Shader-Kontrast folgt dem aktuellen Sim-Alter")
        assertContains(main, "clampf(years / TERRAIN_DETAIL_AGE_YEARS, 0.0, 1.0)",
                       hint: "Detailkontrast bleibt vor Jahr 0 und nach 100k gedeckelt")
        assertContains(shader, "uniform float detail_strength = 0.16;",
                       hint: "Editor- und Jahr-0-Default stimmen überein")
    }

    /// Der Detail-Layer allein degeneriert auf der gealterten Welt zu einem
    /// uniformen Tapeten-Muster (Nutzer-Abnahme 2026-09-02): prozedurales Noise
    /// bindet an keine echte Geländestruktur. Seit PR #106 bündelt die
    /// Abfluss-Textur (`flow_tex`, R8 aus `WaterFieldRenderer.flowDetailField`)
    /// die Rinnen dort, wo Wasser wirklich abfließt; das Stärke-Fenster des
    /// Shaders muss dem Kalibrier-Vertrag in `WaterRender` folgen.
    func testTerrainDetailFollowsRealDischarge() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(main, "FieldTexture.new(\"flow_tex\", Image.FORMAT_R8)",
                       hint: "Abfluss-Dichte reist als R8-Textur")
        assertContains(main, "flow_field.upload(terrain_mat, N, sim.flowDetailBytes())",
                       hint: "Main lädt das Abfluss-Feld mit den Overlays hoch")
        assertContains(shader, "uniform sampler2D flow_tex",
                       hint: "Terrain-Shader kennt die Abfluss-Textur")
        assertContains(shader,
                       "mix(\(glsl(WaterRender.flowDetailGainLo)), "
                       + "\(glsl(WaterRender.flowDetailGainHi)), texture(flow_tex, v_uv).r)",
                       hint: "Stärke-Fenster == WaterRender.flowDetailGainLo/Hi")
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "render.flowDetailBytes(terrain)",
                       hint: "SimNode marshallt das Abfluss-Feld nur durch")
    }

    func testHeightScaleIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.heightScale, 24.0)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "const HSCALE := \(glsl(RenderContract.heightScale))",
                       hint: "Mesh-Überhöhung == RenderContract.heightScale")
        assertContains(main, "set_shader_parameter(\"hscale\", HSCALE)",
                       hint: "Shader-Uniform der Überhöhung == Main.gd HSCALE")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform float hscale = \(glsl(RenderContract.heightScale));",
                       hint: "Shader-Default der Überhöhung == RenderContract.heightScale")
        // Nicht nur die DEKLARATION pinnen, sondern jede ANWENDUNG: ein
        // zusätzlicher Faktor am Displacement (`* hscale * 1.08`) oder eine
        // eigene Konstante in den Normalen ließe den Vertrag grün und das
        // gerenderte Terrain trotzdem von `HSCALE` abweichen — genau die
        // Drift-Klasse, die #51 beendet. Die vier Zeilen sind alle Stellen, die
        // den Uniform lesen: Vertex-Höhe, Vertex-/Pixel-Normale und die
        // Welt-Y-Koordinate der triplanaren Materialschichten.
        for use in ["VERTEX.y = mix(hraw, hfv, lift) * hscale;",
                    "NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hD - hU) * hscale));",
                    "vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0,"
                        + " -s_uv.y * hscale / world_size));",
                    "vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,"] {
            assertContains(shader, use,
                           hint: "Überhöhung wird unskaliert angewandt (keine Zusatzfaktoren)")
        }
        // Und keine fünfte, ungeprüfte Anwendung: 1 Deklaration + 1 Vertex-Höhe
        // + 2 Vertex-Normale + 2 Pixel-Normale + 1 Materialkoordinate = 7.
        XCTAssertEqual(shader.count(of: "hscale"), 7,
                       "Neue oder entfernte `hscale`-Anwendung im Terrain-Shader —"
                       + " Liste der geprüften Stellen mitziehen")
    }

    func testRiverLiftIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.riverLift, 0.35)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "const RIVER_LIFT := \(glsl(RenderContract.riverLift))",
                       hint: "Band-Anhebung == RenderContract.riverLift")
        // Über Wasser gilt der Land-Lift NICHT — die beiden Wasser-Versätze
        // müssen deutlich kleiner bleiben, sonst wäre die Sonderbehandlung
        // wirkungslos (das Band schwebte als Platte über der Fläche).
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, RenderContract.riverLift)
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), RenderContract.riverLift)
    }

    /// Godot 4 nennt den Alpha-Tiefenpass `depth_prepass_alpha`. Der ähnlich
    /// klingende Vulkan-Begriff `depth_draw_alpha_prepass` kompiliert nicht und
    /// ließ den neuen Ozean erst beim Start der echten Szene ausfallen.
    func testOceanUsesAValidAlphaDepthPrepass() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        assertContains(ocean,
                       "render_mode blend_mix, depth_prepass_alpha, cull_disabled;",
                       hint: "Ozean-Shader verwendet Godot-4-Rendermodus")
    }

    /// Das Ozean-Mesh reicht über die Kamera-Sichtweite und zeichnet innerhalb
    /// der Terrainfläche nur über Meeresboden. Sonst sieht eine flache Kamera
    /// gleichzeitig seine quadratische Kante und die Platte unter dem Land.
    func testOceanClipsItsPlaneBelowLand() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(ocean, "uniform sampler2D height_tex",
                       hint: "Ozean liest dasselbe Höhenfeld wie das Terrain")
        assertContains(ocean, "texture(height_tex, terrain_uv).r > sea_level",
                       hint: "Land schneidet die Ozeanplatte ab")
        assertContains(main, "height_field.mirror_to(ocean_mat)",
                       hint: "Main bindet die Höhentextur auch an den Ozean")
        assertContains(main, "ocean_mat.set_shader_parameter(\"sea_level\", sea)",
                       hint: "Ozean und Terrain verwenden denselben Meeresspiegel")
        assertContains(main, "wp.size = Vector2(cam.far * 3.0, cam.far * 3.0)",
                       hint: "Ozeanrand liegt bei jeder erlaubten Kamera hinter dem Far-Clip")
        assertContains(ocean, "ALPHA = 1.0;",
                       hint: "Offenes Meer verbirgt die rechteckige Terrain-Unterseite")
    }

    func testDefaultSeedIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.defaultSeed, 1337)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "var sim_seed := \(RenderContract.defaultSeed)",
                       hint: "Start-Seed der Anzeige == RenderContract.defaultSeed")
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "seed: RenderContract.defaultSeed",
                       hint: "Erstes Terrain der GDExtension == RenderContract.defaultSeed")
    }

    /// Der Produktions-Einlauf der Generierung (PR #106,
    /// `Terrain.generate(seed:settleYears:)`) muss auf BEIDEN Brücken-Wegen
    /// hängen — Start-Terrain und „Neues Terrain"-Knopf. Fehlte er auf einem,
    /// bekämen Spieler zwei verschiedene Welt-Klassen aus demselben Seed.
    func testBothBridgeGeneratePathsSettle() throws {
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "settleYears: SimConfig.productionSettleYears",
                       hint: "Start-Terrain läuft ein")
        XCTAssertEqual(bridge.count(of: "settleYears: SimConfig.productionSettleYears"), 2,
                       "Beide generate-Wege der Brücke (Init + @Callable) laufen ein")
    }

    /// Die Produktions-Config ist EIN benannter Wert in SimCore (Issue #97) —
    /// die Brücke liest ihn, statt ihn nachzubauen. Vorher stand dieselbe
    /// Zwei-Zeilen-Abweichung in sechs handgepflegten Kopien; die Brücke war
    /// die einzige davon, die headless nicht ausführbar ist, also die einzige,
    /// die still driften konnte. Genau deshalb prüft dieser Wächter ihren
    /// Quelltext auch auf die ABWESENHEIT einer eigenen Fassung: ein neuer
    /// `config.hydraulicSkipWaterSpawns = …` in der Brücke wäre sonst wieder
    /// unbemerkt.
    func testBridgeReadsTheOneProductionConfig() throws {
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "config: SimConfig.production",
                       hint: "Start-Terrain der Brücke fährt SimConfig.production")
        for flag in ["hydraulicSkipWaterSpawns", "meanderSpatialCutoffIndex"] {
            XCTAssertEqual(bridge.count(ofIdentifier: flag), 0,
                           "Die Brücke setzt \(flag) wieder von Hand — der Schalter "
                           + "gehört in SimConfig.production")
        }
        XCTAssertEqual(bridge.count(ofIdentifier: "productionConfig"), 0,
                       "Die Brücke baut wieder eine eigene Produktions-Config")
        XCTAssertEqual(bridge.count(ofIdentifier: "generationSettleYears"), 0,
                       "Die Brücke hält den Einlauf wieder selbst — er steht in "
                       + "SimConfig.productionSettleYears")
    }

    /// Die Gegenseite desselben Vertrags, ausführbar: `production` ist genau
    /// `SimConfig()` plus die zwei Laufzeit-Schalter. Rutscht eine dritte
    /// Abweichung hinein, fährt die Produktion eine andere Physik als jede
    /// Kalibrierung und jeder Test — und die Kopfzeile des Mess-Harness
    /// behauptet weiter, sie zu spiegeln.
    func testProductionConfigIsTheDefaultsPlusTheTwoPerformanceFlags() {
        var expected = SimConfig()
        expected.hydraulicSkipWaterSpawns = true
        expected.meanderSpatialCutoffIndex = true
        XCTAssertEqual(SimConfig.production, expected,
                       "SimConfig.production weicht über die zwei Perf-Schalter "
                       + "hinaus von SimConfig() ab")
        XCTAssertEqual(SimConfig.productionSettleYears, 3000)

        var custom = SimConfig()
        custom.enableProductionPerformance()
        XCTAssertEqual(custom, SimConfig.production,
                       "enableProductionPerformance() auf SimConfig() muss genau SimConfig.production entsprechen")

        var nonDefault = SimConfig()
        nonDefault.n = 832
        nonDefault.world = 130
        nonDefault.enableProductionPerformance()
        XCTAssertTrue(nonDefault.hydraulicSkipWaterSpawns)
        XCTAssertTrue(nonDefault.meanderSpatialCutoffIndex)
        XCTAssertEqual(nonDefault.n, 832)
        XCTAssertEqual(nonDefault.world, 130)
    }

    /// SimCore-Quellen dürfen keine alten Bezeichner auf die entfernten
    /// Brücken-Properties führen (`SimNode.generationSettleYears`,
    /// `SimNode.productionConfig`).
    func testNoStaleSimNodeConfigReferencesInSimCore() throws {
        for path in ["SimCore/Sources/SimCore/Terrain.swift",
                     "SimCore/Sources/SimCore/Config.swift",
                     "SimCore/Sources/SimPerf/main.swift"] {
            let content = try RepoSource.file(path)
            XCTAssertFalse(content.contains("SimNode.generationSettleYears"),
                           "\(path) verweist noch auf SimNode.generationSettleYears")
            XCTAssertFalse(content.contains("SimNode.productionConfig"),
                           "\(path) verweist noch auf SimNode.productionConfig")
        }
    }

    /// Der Default des `Terrain`-Initialisierers ist die dritte Kopie derselben
    /// Zahl — und die einzige, die sich hier AUSFÜHREN lässt: gleicher Seed →
    /// bit-gleiches Feld (Determinismus-Invariante des Projekts).
    func testTerrainDefaultSeedMatchesTheContract() {
        var cfg = SimConfig()
        cfg.n = 96; cfg.world = calibrationWorld
        let implicitSeed = Terrain(config: cfg)
        let explicitSeed = Terrain(config: cfg, seed: RenderContract.defaultSeed)
        XCTAssertEqual(implicitSeed.h, explicitSeed.h,
                       "Terrain-Default-Seed weicht von RenderContract.defaultSeed ab")
    }
}
