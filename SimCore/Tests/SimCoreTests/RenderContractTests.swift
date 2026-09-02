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
        assertContains(main, "const TERRAIN_DETAIL_OLD := 0.70",
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
