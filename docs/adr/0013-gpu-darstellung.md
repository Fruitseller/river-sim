# Compute-Pässe auf der GPU nur für die Darstellung, mit Rückfall ohne RenderingDevice

Zwei Darstellungs-Aufgaben laufen als Compute-Pässe auf der GPU: eine Geländefläche feiner als das Sim-Gitter (#238) und ein Wald aus Einzelbäumen, die jedes Bild neu platziert werden (#236).

Grenze zur Sim: der Sim-Zustand bleibt auf der CPU, und nichts aus diesen Pässen geht in die Sim zurück. GPU-Floats sind nicht bit-kompatibel (Rundung, FMA, Reassoziation treiberabhängig), deshalb gilt hier nicht die Bit-Regel der Sim, wohl aber gleicher Eingang → gleicher Ausgang: feste Schrittzahl, Rauschen nur aus der Position. Ohne RenderingDevice (Compatibility-Renderer, headless, CI) fällt jeder Pass auf den bisherigen CPU- bzw. Shader-Pfad zurück.

Gelände-Verfeinerung (#238): aus der Sim-Höhe (n²) entsteht eine Fläche in vierfacher Auflösung (bei n = 720 also 2880², 3,9 m je Texel), dazu Karten für Abtrag, Ablagerung, Abfluss und Schutt. Vorbild ist Schott, Galin, Guérin, Paris, Peytavie, „Terrain Amplification using Multi-scale Erosion" (2024), Code unter MIT (https://github.com/H-Schott/MultiScaleErosion, Lizenz in `NOTICE`): hochskalieren in Zweierschritten, auf jeder Stufe nacherodieren. Jeder Schritt trägt den Abfluss ein Texel weiter, die Reichweite einer Änderung am Eingang ist damit fest begrenzt. Die Ausgabe erfüllt den Vertrag der bisherigen Backtextur (`relief_tex`), Terrain-Shader und Raycast lesen sie unverändert. Ohne RenderingDevice, in `performance` und mit `RS_AMPLIFY=0` backt Main weiter mit `relief_bake.gdshader`. Mit Verfeinerung entfällt der Erosionsfilter je Pixel, weil die Verfeinerung seine Rinnen als Form liefert.

Einzelbäume (#236), was die Entscheidung aus #152 zurücknimmt, Instanzbäume abzuschaffen: ein Compute-Pass (`tree_place.glsl`) geht jedes Bild ein festes, verwackeltes Gitter je Stufe um die Kamera ab, liest Höhe, Verschiebung und Waldmaske aus denselben Texturen wie das Terrain-Material und schreibt nur die Bäume, die stehen und zu sehen sind, in indirekte MultiMeshes (Vorbild: die Vegetation in Horizon Zero Dawn). Die CPU schreibt keinen Transform. Die Größe folgt dem Kameraabstand als Kartensymbol, der Wald dünnt dazu nach Rang aus, damit er gleich dicht wirkt. Ohne RenderingDevice bleibt das Kronendach im Terrain-Shader aus #152.

Verworfen:
- Kacheln mit festen Bauminstanzen (erster Wurf, `docs/graphics-quality.md` § Einzelbäume): jede Instanz kostet ihren Vertex-Shader, auch wenn ihr Baum ausgedünnt oder ohne Wald ist. In `nah` waren das 42 Mio. Primitive im Hauptpass für rund 20.000 sichtbare Bäume, mit Schatten 134 Mio. Der Compute-Pass verwirft solche Bäume vor dem Zeichnen und cullt selbst gegen das Frustum.
- Sim-Pässe oder eine Rückkopplung der verfeinerten Fläche auf der GPU: GPU-Floats sind nicht bit-kompatibel, die Sim verlöre ihre Determinismus-Invariante (`docs/web-tech-refactor-evaluation.md` §5).

Takt, Thread-Regeln und Geschmackswerte: `docs/look/d-amplify/README.md` und `docs/graphics-quality.md` § Einzelbäume.

Betrifft: `TerrainAmplifier.gd`, `shaders/amplify/*.glsl`, `Main._setup_amplifier`, `relief_bake.gdshader`, `ForestTrees.gd`, `TreeMesh.gd`, `shaders/tree_place.glsl`, `shaders/tree.gdshader`, `NOTICE`
