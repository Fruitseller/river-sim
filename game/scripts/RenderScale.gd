extends RefCounted
## Render-Skalierung je Qualitätsstufe (#235): die 3D-Szene rendert mit
## weniger Pixeln und wird auf die Fenstergröße hochskaliert; die Bedienung
## (2D) bleibt nativ.
##
## Warum: Die Bildzeit folgt den Pixeln, nicht der Vertexzahl. Gemessen am
## alten Stand, 6016×3260, je Kamera im selben Prozess umgeschaltet
## (docs/perf-measurements.md § M): halbe Auflösung je Achse sparte 20 bis
## 24 ms von 31 bis 41 ms, ein Viertel der Terrain-Vertices nur 3 bis 6 ms.
##
## Verfahren: auf dem Mac MetalFX Spatial (Godot ≥ 4.4, nur Metal-Treiber),
## sonst FSR 1.0. Beide sind räumlich, sie brauchen keine Bewegungsvektoren.
## Temporal (MetalFX Temporal, FSR 2) ist verworfen: Das Gelände verschiebt
## seine Vertices aus Texturen, die im Zeitraffer gleiten, und Godot kennt
## dafür keine Bewegung; Messung und Bild in docs/perf-measurements.md § M.
## MSAA bleibt an und wirkt auf der kleineren Auflösung.
##
## A/B ohne Umbau: `RS_RENDER_SCALE=<0,25…1>` setzt den Faktor,
## `RS_SCALING=bilinear|fsr|metalfx` das Verfahren.

## Anteil je Achse. `quality` rendert nativ wie bisher.
const SCALE := {"performance": 0.5, "balanced": 0.67, "quality": 1.0}

static func scale_for(quality: String) -> float:
	return SCALE.get(quality, SCALE["balanced"])

## Verfahren für den laufenden Grafiktreiber.
static func mode_for(driver: String) -> Viewport.Scaling3DMode:
	if driver == "metal":
		return Viewport.SCALING_3D_MODE_METALFX_SPATIAL
	return Viewport.SCALING_3D_MODE_FSR

static func apply(vp: Viewport, quality: String) -> void:
	var scale := scale_for(quality)
	if OS.has_environment("RS_RENDER_SCALE"):
		scale = clampf(float(OS.get_environment("RS_RENDER_SCALE")), 0.25, 1.0)
	var mode := mode_for(RenderingServer.get_current_rendering_driver_name())
	match OS.get_environment("RS_SCALING"):
		"bilinear":
			mode = Viewport.SCALING_3D_MODE_BILINEAR
		"fsr":
			mode = Viewport.SCALING_3D_MODE_FSR
		"metalfx":
			mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
	if scale >= 1.0:
		mode = Viewport.SCALING_3D_MODE_BILINEAR # nativ: kein Hochskalierer
	vp.scaling_3d_mode = mode
	vp.scaling_3d_scale = scale
