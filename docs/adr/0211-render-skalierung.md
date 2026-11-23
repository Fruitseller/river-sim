# Render-Skalierung je Qualitätsstufe, räumliche Verfahren

Die 3D-Szene rendert mit weniger Pixeln und wird auf die Fenstergröße hochskaliert, die 2D-Bedienung bleibt nativ (#235): `performance` 0,5, `balanced` 0,67, `quality` nativ je Achse. Grund: die Bildzeit folgt den Pixeln, nicht der Vertexzahl. Gemessen am alten Stand, 6016×3260, je Kamera im selben Prozess umgeschaltet (`docs/perf-measurements.md` § V): halbe Auflösung je Achse sparte 20 bis 24 ms von 31 bis 41 ms, ein Viertel der Terrain-Vertices nur 3 bis 6 ms. MSAA bleibt an und wirkt auf der kleineren Auflösung.

Verfahren: auf dem Mac MetalFX Spatial (Godot ≥ 4.4, nur Metal-Treiber), sonst FSR 1.0. Beide sind räumlich und brauchen keine Bewegungsvektoren. MetalFX Temporal kostete gemessen genauso viel (22,3 statt 22,4 ms in `nah` bei 6016×3260) und brächte keine Zeit; außerdem verschiebt das Gelände seine Vertices aus Texturen, die im Zeitraffer gleiten, und dafür kennt Godot keine Bewegungsvektoren, Schlieren wären zu erwarten. Im Bild geprüft ist Temporal nicht. FSR gibt es nur auf RenderingDevice-Treibern; Compatibility (OpenGL) und `--headless` skalieren bilinear, sonst warnt Godot und fällt selbst darauf zurück.

A/B ohne Umbau: `RS_RENDER_SCALE=<0,25…1>` setzt den Faktor, `RS_SCALING=bilinear|fsr|metalfx` das Verfahren. Der Override greift nur, wenn der Treiber das Verfahren kann; sonst fiele Godot still auf bilinear zurück, und die Messung stünde unter dem falschen Namen.

Betrifft: `RenderScale.gd` (`SCALE`, `mode_for`, `apply`)
