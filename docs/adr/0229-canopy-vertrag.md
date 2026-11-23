# Vertragstest des Kronendachs und der Einzelbäume

Wo Wald steht, pinnt `SimCoreTests/CanopyTests.swift` headless. `game/tests/canopy.gd` (#152) prüft den Weg durch Brücke, Main und Shader:
- jede `canopy_*`- und `material_*`-Zahl kommt über die Brücke (`SimCore.CanopyRender`, `SimCore.MaterialRender`), ist im Terrain-Shader default-frei deklariert und auf dem Material gesetzt;
- Waldmaske und Bodenbedeckung liegen als Textur in Gittergröße am Material und folgen Pinselstrich, Neugenerieren und Laden über die Pfade von Main, nicht nur über die Brücke;
- Einzelbäume (#236) gibt es genau dann, wenn ein RenderingDevice da ist (der Compute-Pass braucht es) und `RS_NO_TREES` fehlt; headless und in CI bleibt das Kronendach. Mit Bäumen weiß der Terrain-Shader davon (`tree_instances`: keine Anhebung, keine gemalten Kronen), und es gibt vier Listen (Nadel-, Laubbaum nah, fern, Schatten);
- Pinselring und Kameraziel liegen auf der sichtbaren Fläche: Sim-Höhe plus Dachhöhe (mit Einzelbäumen null).

Bestandsrand (Review Neon Nr. 2): der Terrain-Vertex-Shader hebt nach der geglätteten Maske (`canopy_lift_smooth_texels`, `lift_f = min(v_forest, sm * 0.25)`), am Rand also weniger. Die sichtbare Fläche muss dort genauso tief liegen. Der Test rechnet das unabhängig aus der Maske des Frames nach.

Der Dummy-Renderer liest Texturen nicht zurück; geprüft wird das Bild, das Main zuletzt hochgeladen hat (`forest_img`), und dass die Textur dieselbe bleibt.

Neugenerieren und Laden: Laden holt den gespeicherten Wald bit-gleich zurück. Der Render-Zustand des Rasterwassers reist nicht im Spielstand (EWMA), aber jeder Weltwechsel endet in einem `settled`-Frame mit Blend 1,0, der ihn vollständig überschreibt. Bis Review Neon Nr. 5 wich der Wald hier ab (Mac 1, Linux 9 Zellen), und der Test klammerte Ufer aus und duldete einen Anteil. Ursache war nicht das Gedächtnis der Waldmaske, sondern dass der Endstand des Pinselstrichs die Bänder des Vor-Pinsel-Stands behielt (`RenderState.rebuildRibbonsIfDue`, Wächter `RenderFrameTests.testFinishedStrokeMatchesTheLoadedWorld`). Toleranz ist deshalb keine mehr nötig.

Betrifft: `game/tests/canopy.gd`, `game/shaders/terrain.gdshader` (Dachanhebung), `game/scripts/Main.gd` (`_forest_lift_at`, `forest_img`)
