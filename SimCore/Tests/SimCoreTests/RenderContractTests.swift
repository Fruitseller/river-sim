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
        // Das Alter der hochgeladenen Höhen, nicht das der Sim: im Zeitraffer
        // rechnet die schon am nächsten Schritt (perf-measurements §L).
        assertContains(main, "func _upload_heights(bytes: PackedByteArray, year: float) -> void:",
                       hint: "Der Höhen-Upload kennt das Jahr seiner Höhen")
        assertContains(main,
                       "set_shader_parameter(\"detail_strength\", terrain_detail_strength(year))",
                       hint: "Shader-Kontrast folgt dem Sim-Alter der gezeigten Höhen")
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
        assertContains(main, "FieldTexture.new(\"flow_tex\", Image.FORMAT_R8, true)",
                       hint: "Abfluss-Dichte reist als R8-Textur")
        assertContains(main, "flow_field.upload(terrain_mat, N, frame[\"flow\"])",
                       hint: "Main lädt das Abfluss-Feld mit den Overlays hoch")
        assertContains(shader, "uniform sampler2D flow_tex",
                       hint: "Terrain-Shader kennt die Abfluss-Textur")
        assertContains(shader,
                       "mix(\(glsl(WaterRender.flowDetailGainLo)), "
                       + "\(glsl(WaterRender.flowDetailGainHi)), flow_at(v_uv))",
                       hint: "Stärke-Fenster == WaterRender.flowDetailGainLo/Hi")
        // Das Feld selbst reist seit Issue #214 ausschließlich im Frame
        // (`flow`-Schlüssel) — dass die Brücke ihn setzt und Main.gd ihn
        // liest, pinnt RenderFrameTests.testMainUsesTheFrameTriggerValues.
    }

    func testHeightScaleIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.heightScale, 24.0)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        // Main.gd führt die Zahl seit #213 nicht mehr als Literal, sondern holt
        // sie über die Brücke (`CalibrationRegistryTests`); hier bleibt, dass
        // derselbe Wert als Uniform ankommt.
        assertContains(main, "terrain_mat.set_shader_parameter(\"hscale\", hscale)",
                       hint: "Shader-Uniform der Überhöhung == Main.gd hscale (Brücke)")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform float hscale = \(glsl(RenderContract.heightScale));",
                       hint: "Shader-Default der Überhöhung == RenderContract.heightScale")
        // Nicht nur die DEKLARATION pinnen, sondern jede ANWENDUNG: ein
        // zusätzlicher Faktor am Displacement (`* hscale * 1.08`) oder eine
        // eigene Konstante in den Normalen ließe den Vertrag grün und das
        // gerenderte Terrain trotzdem von `hscale` abweichen — genau die
        // Drift-Klasse, die #51 beendet. Die vier Zeilen sind alle Stellen, die
        // den Uniform lesen: Vertex-Höhe, Vertex-/Pixel-Normale und die
        // Welt-Y-Koordinate der triplanaren Materialschichten. Die
        // Render-Verschiebung (#153) addiert sich zur Vertex-Höhe UNSKALIERT:
        // sie liegt schon in Welteinheiten vor, die Überhöhung wendet der
        // Back-Pass genau einmal an (unten).
        for use in ["VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);",
                    // Vertex-Normale mit demselben Vorzeichen wie die Pixel-Normale
                    // (hU bei +z): Godots Schatten-Normal-Bias liest sie
                    // (Review zu #174, vorher `-(hD - hU)`).
                    "NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hU - hD) * hscale));",
                    "vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0,"
                        + " -s_uv.y * hscale / world_size));",
                    "vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,",
                    // Weltsteigung der Gletscherspalten (#174 D) und des
                    // Raster-Wassers an Wänden, dieselbe Umrechnung wie die
                    // Pixel-Normale.
                    "float world_slope = length(coarse_slope) * hscale / world_size;"] {
            assertContains(shader, use,
                           hint: "Überhöhung wird unskaliert angewandt (keine Zusatzfaktoren)")
        }
        // Und keine weitere, ungeprüfte Anwendung: 1 Deklaration + 1 Vertex-Höhe
        // + 2 Vertex-Normale + 2 Pixel-Normale + 1 Materialkoordinate
        // + 1 Spalten-Steigung = 8.
        XCTAssertEqual(shader.count(of: "hscale"), 8,
                       "Neue oder entfernte `hscale`-Anwendung im Terrain-Shader —"
                       + " Liste der geprüften Stellen mitziehen")
        // Back-Pass der Verschiebung: Main.gd setzt denselben Uniform, der
        // Shader wendet ihn genau einmal an (Höhenzuschlag in Welteinheiten)
        // und rechnet damit den Gratdeckel in Sim-Höhe um.
        assertContains(main, "relief_mat.set_shader_parameter(\"hscale\", hscale)",
                       hint: "Back-Pass bekommt die Überhöhung aus Main.gd hscale")
        let bake = try RepoSource.probe("game/shaders/relief_bake.gdshader")
        assertContains(bake, "uniform float hscale;",
                       hint: "Back-Pass deklariert die Überhöhung default-frei")
        assertContains(bake, "relief = vec4((det.x + ridge) * hscale,",
                       hint: "Überhöhung wird im Back-Pass unskaliert angewandt")
        assertContains(bake, "float cap = relief_ridge_cap / hscale;",
                       hint: "Gratdeckel steht in Welteinheiten (ReliefRender.ridgeCap)")
        XCTAssertEqual(bake.count(ofIdentifier: "hscale"), 3,
                       "Neue oder entfernte `hscale`-Anwendung im Back-Pass")
    }

    func testRiverLiftIsTheSameInEveryLayer() throws {
        // Die Godot-Wächter holen den Wert seit #213 über die Brücke (Gruppe
        // `contract`, `CalibrationRegistryTests`), Main.gd braucht ihn nicht.
        XCTAssertEqual(RenderContract.riverLift, 0.35)
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
        assertContains(ocean, "if (inside_terrain) {",
                       hint: "Ozean liest die Höhe nur innerhalb des Terrain-Quadrats")
        assertContains(ocean, "h = texture(height_tex, terrain_uv).r;",
                       hint: "Küstenlinie bilinear wie im Terrain (nicht über den Schelf-B-Spline)")
        assertContains(ocean, "if (h > sea_level)",
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
    ///
    /// Der Wächter prüft bewusst den Rohtext inkl. Doc-Kommentaren (`RepoSource.file`
    /// statt `SourceProbe.code`): genau ein veralteter Kommentar in `Terrain.generate`
    /// war der erste Drift-Fall dieses PRs. Historische Verweise in Tests werden nicht
    /// erfasst, weil nur die SimCore-Quellen und der Mess-Harness geprüft werden.
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
