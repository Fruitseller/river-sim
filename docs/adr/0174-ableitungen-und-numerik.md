# GPU-Numerik: Ableitungen im gleichförmigen Kontrollfluss, präzise Hashes, NaN-Schutz

Bildschirm-Ableitungen (`dFdx`, `fwidth`, implizite Mip-Wahl) sind nach einem nicht-uniformen `discard` oder innerhalb einer je Pixel verzweigenden Bedingung undefiniert (Nachbarn im Quad fehlen). Deshalb gilt in allen Shadern:
- Pixelgröße, Footprint, Schelf-Neigung und Ableitungen der Weltposition werden EINMAL am Anfang von `fragment()` im gleichförmigen Kontrollfluss bestimmt, vor jedem discard und frühen Return. Klüftung, Körnung, Spalten, Kronen und Kräuselung blenden darüber aus, laufen aber hinter Verzweigungen.
- Scan-Materialien fragen über `textureGrad` mit diesen Ableitungen ab (`dpdx`, `dpdy`), weil die Aufrufer je Pixel verzweigen (nur auf Fels, nur auf Sand).
- Texturen mit impliziter Mip-Stufe (`amplify_maps`, `relief_pixel`, `cover_at`) nur im gleichförmigen Kontrollfluss lesen. `relief_pixel` braucht die implizite Stufe, weil die 2880²-Fläche der Verfeinerung (#238) in der Ferne sonst flimmerte.
- Im Band werden Ableitungen interpolierter, nicht quad-uniformer Größen (`corridor` am Auslauf zu See/Meer) vor dem Zweig gebildet.
- Der Gradient der Waldmaske in Welt-xz entsteht ebenfalls vorab aus den Bildschirm-Ableitungen von Maske und Position (2×2-System); je Dreieck ist die Maske linear, die Schätzung an jeder Kronenmitte also exakt.

Hashes:
- Wertrauschen (`vhash`): bis zum Review zu #174 lief es über `ehash` aus dem Erosionsfilter, dessen Float-Produkt x·y·(x+y) in float32 ab einigen Dutzend Zellen vom Ursprung die Nachkommabits verliert. Weit von der Kartenmitte erstarrte das Rauschen (Schutt-Körnung und Klüfte glatt, Spalten und Kräuselung als Gitter). Jetzt wird der Zellindex zuerst auf [0, 17) gefaltet; das Produkt bleibt unter ~10⁴, float32 behält zehn Nachkommabits. Rein Float, weil ein Ganzzahl-Hash (pcg) gemessen bis zu 4 ms je Bild kostete (`docs/zielbild-measurements.md`).
- Kronen-Hash: Ganzzahl-Hash (pcg3d, Jarzynski & Olano 2020) statt `ehash`, denn bei Zellindizes um 1000 liegt das Produkt bei ~1e9, `fract` liefert nur noch 0 und alle Kronen stünden im Raster (Projekteigner, Nahzoom).
- Die Verfeinerung hasht (PCG) NUR aus der Position: gleicher Eingang gibt gleichen Ausgang, Rinnen bleiben an ihrem Ort.

`normalize()` auf dem Nullvektor ist auf der GPU NaN; auf exakt flachem Terrain (Einebnen-Werkzeug, Floor-Clamp) wurde daraus eine schwarze Fläche. `safe_dir` gibt degenerierten Richtungen einen festen Ersatz; die Detail-Masken blenden bei Steigung ≈ 0 ohnehin auf null, der Ersatz ist unsichtbar.

Betrifft: `game/shaders/terrain.gdshader` (`vhash`, `crown_hash`, fragment-Prolog), `game/shaders/ocean.gdshader`, `game/shaders/water.gdshader`, `game/shaders/scan_material.gdshaderinc`, `game/shaders/amplify.gdshaderinc` (`amplify_maps`), `game/shaders/amplify/common.glsl` (`pcg`), `game/shaders/erosion_filter.gdshaderinc` (`safe_dir`)
