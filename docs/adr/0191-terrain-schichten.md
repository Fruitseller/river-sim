# Terrain-Shader: unabhängige Schichten, WO in SimRender, WIE im Shader

Das Terrain ist ein statisches Gitter, das der Vertex-Shader nach `height_tex` (R32F) verschiebt; Normalen kommen aus Nachbar-Texeln, die Farbe aus `color_tex`. Darauf liegen getrennte Schichten: Raster-Wasser, feines Erosionsdetail, Render-Verschiebung, Kronendach und Materialschicht. Für alle gilt dieselbe Arbeitsteilung: WO etwas liegt (Wasser, Wald, Fels, Sand, Schnee) rechnet SimRender auf der CPU, der Shader baut nur, WIE es aussieht. Alles ist reine Darstellung, die Physik bleibt in SimCore.

- Raster-Wasser: glattes, linear gefiltertes Feld-Overlay aus `water_tex` statt blockigem Pro-Zell-Wasser (s. [ADR 0186](0186-raster-wasser.md)).
- Erosionsdetail: runevision-Filter je Pixel, mit der Kameradistanz ausgeblendet (Aliasing, Kosten), s. [ADR 0177](0177-erosionsdetail.md).
- Render-Verschiebung (#153): grobe Rinnen (~2,5 km Wellenlänge) und einseitig geschärfte Grate als echte Verschiebung mit Silhouette und Schatten, gebacken in `relief_bake.gdshader`, s. [ADR 0187](0187-render-verschiebung.md).
- Kronendach (#152): WO Wald steht, sagt allein `forest_tex` (SimRender.ForestCanopyMask, endet an der Schutzmaske); der Shader macht Anhebung und Kronen, s. [ADR 0182](0182-kronendach-je-pixel.md).
- Materialschicht (#174 D): aus `surface_tex`/`cover_tex` (Gewichte von SimRender.TerrainColorRenderer, Kalibrierung SimCore.MaterialRender) entstehen Körnung, Schichten, Spalten, Moränen, Windverfrachtung und Mikro-Normale in Weltkoordinaten.

Detail- und Materialschicht haben getrennte Schalter (`detail_enabled`, `material_enabled`), weil es verschiedene Dinge sind: wer die Erosionsrinnen isoliert, behält die Materialien. Main.gd hängt beide an `render_quality`; ist `material_enabled` aus, entfällt der komplette Rauschaufwand der Schicht, nicht nur der ausgeblendete Teil.

Texturkanal-Vertrag:
- `hf_tex`: gefüllte Oberfläche (Seespiegel).
- `color_tex`: RGB Makrofarbe, A Sandgewicht = max(Strand, Gleithang-Bank) (#174 C/C2).
- `surface_tex`: R Vegetation, G Fels, B Schnee/Eis, A Lithologie.
- `cover_tex` (#174 D): R Schutthalde, G blankes Gletschereis (Anteil an B von `surface_tex`), B Rohboden (frisch gestört), A Talboden-Wiese. `hint_default_black`: ohne Bindung (Editor-Vorschau) keine dieser Schichten.

Debug-Ansichten der Flusstal-Studie werden nur im `FLUSSTAL_STUDY`-Build per Präprozessor eingebunden (Flusstal.gd setzt das Define zur Laufzeit vor die Quelle; Godot 4.7 erlaubt `#define` vor `shader_type`). Der Spiel-Shader überspringt Include und Aufruf komplett: keine Studien-Uniforms in Produktion, und `studies/` lässt sich verschieben, ohne den Hauptshader zu brechen (Review zu #121). Das Include steht nach den Helfern, weil die Studie sie mitbenutzt.

Betrifft: `game/shaders/terrain.gdshader` (Uniforms, `material_enabled`, `detail_enabled`, `FLUSSTAL_STUDY`), `game/studies/flusstal/landscape.gdshaderinc`, `SimRender.TerrainColorRenderer`, `SimRender.ForestCanopyMask`
