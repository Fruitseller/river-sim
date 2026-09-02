extends Node3D
## river-sim — Godot-Frontend (M2).
## Der Simulationskern (Erosion/Flüsse/Tektonik) lebt in der GDExtension `SimNode`
## (Swift/SimCore, headless getestet). Dieses Skript macht nur Rendering, Kamera,
## Eingabe und Zeitsteuerung — die Physik-Logik wird NICHT hier dupliziert.

# Höhen-Skalierung fürs Mesh (von 30 gesenkt: weniger vertikale Überhöhung →
# sanfterer Look, ergänzt das gesenkte baseRelief). DIESELBE Zahl steht als
# RenderContract.heightScale in SimCore und als Default von `hscale` in
# terrain.gdshader; Wächter: SimCoreTests/RenderContractTests.swift (Issue #51).
const HSCALE := 24.0
const BALANCED_TERRAIN_GRID := 384
const PERFORMANCE_TERRAIN_GRID := 256

# Kosmetische Sub-Grid-Rinnen des Terrain-Shaders. Die Physik altert von einer
# scharfen zu einer runden Landschaft; eine konstante Detailstärke überzeichnete
# dadurch Jahr 0 und ließ 100k im Vergleich leer aussehen. Der Renderkontrast
# läuft in der Gegenrichtung und hält beide Zustände als dieselbe Welt lesbar,
# ohne Sim-Höhen, Wasser oder Spielstände zu verändern.
#
# Kalibrierung per A/B-Screenshot (maximiert, RS_STEP=100000, Seed 1337):
# Die Stärke ist NICHT der Hebel für „alt wirkt leer": bei 0.70 wurde aus dem
# Detail-Layer ein sichtbar repetitives Tapeten-Muster (Nutzer-Abnahme
# 2026-09-02), weil die gealterte Welt gleichförmig flache Hänge hat und
# `erosion_detail` die Wellen-Richtung auf die lokale Steigung normiert —
# überall gleiche Frequenz und Amplitude. Am jungen Ende ist der Layer
# ohnehin fast unsichtbar (die ECHTEN Pre-Erosions-Rinnen der Generierung
# dominieren, A/B mit detail_enabled=false ununterscheidbar).
const TERRAIN_DETAIL_YOUNG := 0.16
const TERRAIN_DETAIL_OLD := 0.42
const TERRAIN_DETAIL_AGE_YEARS := 100000.0

var sim: Object
var N: int
var world_size: float
var half: float
var step: float
var sea: float
var terrain_grid: int
var render_quality := "balanced"
var pick_radius_cap := 0.5 # effektive Spitzhacken-Breite (aus SimNode, fürs Ring-Visual)

var terrain_mi: MeshInstance3D
var water_mi: MeshInstance3D
var ring_mi: MeshInstance3D

# 3D-Bäume aus dem veg-Feld (Stufe 1, reine Optik): je Variante (Laub/Nadel/
# Busch) EIN MultiMeshInstance3D → 3 Drawcalls für zehntausende Instanzen.
# Die Instanz-Transforms baut SimNode.treeInstanceBuffer deterministisch
# (Hash-Jitter, kein Frame-Random); GDScript setzt nur den Puffer.
var tree_mmi: Array[MultiMeshInstance3D] = []
const TREE_VARIANTS := 3
const TREE_REBUILD_DELTA := 0.1 # Rebuild erst, wenn sich veg irgendwo um > 0.1 geändert hat
enum TreeCoverage { NONE, REDUCED, FULL }
var tree_coverage := TreeCoverage.REDUCED
var tree_coverage_picker: OptionButton

# Wasser-Geometrie (Issues #31/#34): Mäander, Delta-Distributäre und Altarme als
# Band-Geometrie aus SimNode.buildRiverRibbons statt Textur-Stempel. Seit #34 der
# STANDARD; `RS_WATER_STAMP` schaltet für den A/B-Vergleich auf den alten
# Raster-Stempel-Pfad zurück (ohne Rebuild, SimNode liest dieselbe Variable).
# Dirty-Vertrag wie bei den Bäumen: Rebuild nur, wenn sich die Zentrumslinien
# merklich bewegt haben (riversMaxDelta in Zellen).
var river_ribbons := true
var river_mi: MeshInstance3D
var river_mesh := ArrayMesh.new()
var river_mat: ShaderMaterial
# Pinsel-Strich: die HÖHE folgt jedem Frame (heightsBytes ≈ 0,2 ms), die teure
# Aufbereitung dahinter nur in diesem Takt. Gemessen je Aufruf (n = 832, M4 Max):
# recomputeFlow 41 ms + waterFieldBytes 17 ms + buildRiverRibbons 10 ms samt
# 315k-Index-Mesh-Upload — pro Frame gerechnet sind das ~14 FPS, und genau das
# war der gemeldete Lag beim Arbeiten mit den Werkzeugen (RS_QUALITY=quality).
# 0,15 s hält den Strich flüssig und die Flüsse trotzdem sichtbar mitlaufend;
# beim Loslassen zieht `_finish_stroke()` einmal alles vollständig nach, damit der
# fertige Strich nie mit einem halb alten Flussnetz stehen bleibt.
# Der Takt blieb bei 0,15 s; seit Aug 2026 verteilt sich der Nachzug stattdessen
# auf ZWEI Frames (Flussnetz / Uploads) — Aufschlüsselung und Messwerkzeug am
# Aufruf in `_process`.
# Takt des Zeitraffer-Sim-Schritts. Ein Schritt kostet FAST FIX ~40 ms, egal wie
# viele Jahre er trägt: computeFlow (priorityFlood 23 ms + computeMFDArea 11 ms +
# Empfängerwahl 3 ms) hängt an der Gittergröße, nicht an dt. Der Takt ist damit
# direkt Framerate: GEMESSEN (n = 832, RS_QUALITY=quality, RS_FPS, M4 Max)
# 0,15 s → 38,8 FPS · 0,25 s → 44,3 FPS · 0,35 s → 48,1 FPS. Bezahlt wird das
# mit gröberen Sprüngen je Update (bei 60 J/s trägt ein Schritt 15 statt 9
# Jahre) — dt-invariant ist das Ergebnis ohnehin, sichtbar ist nur, wie fein die
# Landschaft zwischen zwei Updates gleitet; die Wasser-Blend (0.15, s. u.)
# überbrückt es. 0,25 s ist die Wahl des Nutzers (+14 % FPS); 0,35 s wäre
# nochmal +10 %, ist aber nicht auf sein Zeitraffer-GEFÜHL geprüft worden —
# gemessen sind hier nur die Bildraten.
const SIM_TICK_SECONDS := 0.25
const SCULPT_REFRESH_SECONDS := 0.15
const RIVER_REBUILD_DELTA := 0.05  # Zellen Knoten-Verschiebung
const RIVER_REBUILD_SECONDS := 1.0  # Strahler + Mesh sind CPU-seitig; 0,30 s kosteten im Zeitraffer messbar ~4 % FPS
# Welt-Y über Gelände: deckt den Chord-Fehler des gröberen Render-Gitters im
# Talgrund (384er-Gitter auf 832er-Feld). == RenderContract.riverLift (SimCore);
# über Wasser gilt stattdessen WaterRender.ribbonLakeSurfaceLift/-SeaSurfaceSink.
const RIVER_LIFT := 0.35

# Terrain wird per Textur-Displacement gerendert: statisches Gitter, Höhen-,
# Makrofarben-, Material- und Wasserfelder werden nur hochgeladen.
var terrain_mat: ShaderMaterial
var ocean_mat: ShaderMaterial

## Ein Feld → EINE Shader-Textur: legt Image/ImageTexture beim ersten Upload an
## (und hängt sie an ihren Shader-Parameter), danach nur noch `set_data` +
## `update`. Ersetzt fünf wortgleiche Blöcke (Issue #53) — der Unterschied waren
## nur Name und Pixelformat.
class FieldTexture:
	var _param: StringName
	var _format: int
	var _img: Image
	var _tex: ImageTexture
	var _mirror_mat: ShaderMaterial

	func _init(param: StringName, format: int) -> void:
		_param = param
		_format = format

	## Bindet denselben GPU-Texturzustand an einen zweiten Shader. Die Höhenkarte
	## schneidet damit auch die Ozeanplatte ab, ohne einen zweiten Image-Upload.
	func mirror_to(mat: ShaderMaterial) -> void:
		_mirror_mat = mat
		if _tex != null:
			_mirror_mat.set_shader_parameter(_param, _tex)

	func upload(mat: ShaderMaterial, n: int, bytes: PackedByteArray) -> void:
		if _img == null:
			_img = Image.create_from_data(n, n, false, _format, bytes)
			_tex = ImageTexture.create_from_image(_img)
			mat.set_shader_parameter(_param, _tex)
			if _mirror_mat != null:
				_mirror_mat.set_shader_parameter(_param, _tex)
		else:
			_img.set_data(n, n, false, _format, bytes)
			_tex.update(_img)

var height_field := FieldTexture.new("height_tex", Image.FORMAT_RF)
# gefüllte Oberfläche (Seespiegel) → echte horizontale Seeflächen
var hf_field := FieldTexture.new("hf_tex", Image.FORMAT_RF)
var color_field := FieldTexture.new("color_tex", Image.FORMAT_RGBA8)
var surface_field := FieldTexture.new("surface_tex", Image.FORMAT_RGBA8)
var water_field := FieldTexture.new("water_tex", Image.FORMAT_RGBA8)

# GPU-Schwanzstufen des Raster-Wasserfelds (siehe shaders/water_field_*.gdshader).
# Die Aufbereitung des Felds bleibt in der Extension — ihre zwei teuren Stufen
# sind sequenzielle Graph-Algorithmen (Kontinuitäts-Kette entlang der
# D8-Empfänger, Flood-Fill der Wasser-Komponenten) und passen in kein
# Pixel-Programm. Was hierher wandert, ist der SCHWANZ: räumlicher Blur,
# zeitliche EWMA, Quantisierung. GEMESSEN auf der CPU (n = 832, M4 Max):
# blurMax(sd,1) 1,36 ms + blurMax(lk,2) 2,52 ms + EWMA/Packen 0,44 ms = 4,3 ms
# der 14,4 ms des Passes. Mehr ist ohne Readback mitten in der Kette nicht zu
# holen, und ein Readback je Tick kostet mehr als er spart.
#
# Kette: CPU-Rohfeld → Blur(R+G) → Blur(nur G) → EWMA-Ping-Pong → water_tex.
# Alle vier Viewports laufen mit UPDATE_ONCE genau einmal pro Textur-Update;
# auf UPDATE_ALWAYS wäre die EWMA-Rate an die Bildrate gekoppelt und die
# Framerate-Unabhängigkeit (AGENTS.md) verletzt.
#
# STANDARDMÄSSIG AUS, und zwar aus Messgründen, nicht aus Vorsicht:
# in situ spart der Schnitt 14,8 → 13,0 ms (1,8 ms je Aufruf, nicht die 4,3 ms,
# die ein Standalone-Benchmark der Schwanzstufen vorhergesagt hatte), und im
# Zeitraffer laufen die Overlays nur alle ~0,5 s. Die Bildraten-Gegenprobe
# (RS_FPS, interleaved, n = 832, balanced, M4 Max) fand deshalb NICHTS:
# GPU 67,9 / 71,2 gegen CPU 69,3 / 68,4 — die Streuung innerhalb einer Variante
# ist größer als der Unterschied. Dafür bekommt die GPU drei zusätzliche
# 832²-Pässe und 22 MB Targets, und die war beim Zeitraffer nicht der
# Leerlaufende Teil (s. ACTIVE_FPS_CAP).
#
# Der Pfad bleibt drin, weil er auf einer Maschine mit schwacher CPU und freier
# GPU gewinnen KANN (Kandidat: die iPad-Frage) — und weil er belegt geprüft ist:
# Bildvergleich gegen den CPU-Pfad 1,09 von 255 mittlerer Abweichung.
# RS_WATER_GPU=1 schaltet ihn ein — A/B im selben Build, wie RS_WATER_STAMP
# für Geometrie ↔ Raster.
var water_gpu := false
var wf_raw_field := FieldTexture.new("src", Image.FORMAT_RGBA8)
var wf_blur_vp: Array[SubViewport] = []
var wf_blur_mat: Array[ShaderMaterial] = []
var wf_state_vp: Array[SubViewport] = []
var wf_ewma_mat: Array[ShaderMaterial] = []
var wf_state_index := 0
var wf_primed := false  # noch kein EWMA-Gedächtnis → erster Tick übernimmt sofort
var debug_difference_field := FieldTexture.new("debug_difference_tex", Image.FORMAT_RGBA8)

# Nur die CPU-Höhen braucht GDScript: Raycasts lesen daraus, alle anderen
# Renderfelder bleiben im nativen SimNode und vermeiden große FFI-Kopien.
# LAZY gezogen (Issue #53): die Höhen-TEXTUR kommt als rohe Bytes direkt aus
# SimNode, dieses Array braucht nur der Raycast — im Zeitraffer ohne Eingriff
# also gar nicht.
var h_cache: PackedFloat32Array
var h_cache_dirty := true

# Kamera-Orbit
var cam: Camera3D
var cam_yaw := 0.7
var cam_pitch := 0.85
var cam_dist := 135.0
var cam_target := Vector3.ZERO
var orbiting := false
const PAN_SPEED_FACTOR := 0.4 # WASD-Geschwindigkeit relativ zur Zoom-Distanz

# Leerlauf-Drossel (GPU): auch pausiert und ohne Eingabe zeichnet Godot die
# Szene sonst weiter (Wasser-Schimmer, Schatten, Retina-Viewport). Nach
# IDLE_FPS_DELAY_MSEC ohne Aktivität wird der Renderloop ganz abgeschaltet;
# die Spiellogik und Eingaben laufen laut Godot-Vertrag weiter. Jede Eingabe
# weckt ihn vor dem nächsten sichtbaren Frame wieder auf. Der FPS-Deckel bleibt
# als Rückfall und für die letzten aktiven Frames vor der Frist bestehen.
const IDLE_FPS_CAP := 30
const IDLE_FPS_DELAY_MSEC := 3000
var last_activity_msec := 0
var render_loop_suspended := false

# Aktiv-Deckel (GPU): auch WÄHREND Zeitraffer und Sculpting ist die Bildrate
# nicht die Rate, mit der sich etwas ändert. Ein Sim-Tick kommt alle
# SIM_TICK_SECONDS (0,25 s), die Wasser-Blend gleitet über ~2 s; dazwischen
# unterscheiden sich die Bilder nur im Schimmer (u_time). Ungedeckelt zeichnete
# Godot in dieser Zeit mit voller Display-Rate — auf einem 120-Hz-Panel ~30
# Bilder je Tick, von denen 29 praktisch dasselbe zeigen. Das war reine
# Lüfterlast, keine sichtbare Flüssigkeit.
#
# 60 liegt bewusst ÜBER der gemessenen Zeitraffer-Rate bei RS_QUALITY=quality
# (38,8–48,1 FPS, s. SIM_TICK_SECONDS): dort deckelt der Wert nichts, die Sim
# ist das Limit. Er greift in `balanced`/`performance`, beim Kamerafahren und in
# den ersten 3 s einer Pause, bevor IDLE_FPS_CAP übernimmt.
const ACTIVE_FPS_CAP := 60
# RS_FPS misst die Rate, die der Renderer HERGIBT — ein Deckel würde dort die
# Zahl messen, die er selbst setzt. Deshalb hebt die Messung ihn auf (_ready).
var active_fps_cap := ACTIVE_FPS_CAP

# Zeit & Eingabe
var year_rate := 0.0          # Jahre/Sekunde
var rebuild_timer := 0.0
var pending_years := 0.0     # über das Render-Intervall akkumulierte Sim-Jahre
var overlay_timer := 0.0
var last_river_rebuild_msec := -1
var sculpting := false
var sculpt_refresh_timer := 0.0
var sculpt_refresh_pending := false  # Teil 2 des Nachzugs steht aus (s. _process)
var pick_last := Vector2.INF  # Spitzhacke: Position des letzten Hiebs im Strich (INF = noch keiner)
var brush_radius := 10.0
var brush_strength := 1.0
var current_tool := 0         # Index in TOOLS (die Tabelle hält den Brush-Modus)
var flatten_target := 0.0     # Zielhöhe fürs Einebnen — beim Strich-Beginn gesampelt
var last_rate := 30.0         # für Leertaste: Pause ↔ letztes Tempo
var u_time := 0.0
var year_label: Label
# Start-Seed == RenderContract.defaultSeed (SimCore): dieselbe Zahl baut das
# erste Terrain in der GDExtension, sonst zeigte die Anzeige einen anderen Seed
# als die sichtbare Welt (Issue #51).
var sim_seed := 1337

# Entwicklungsdiagnose: Referenzvergleich macht sichtbar, ob Relief durch
# Abtragung nur freigelegt oder durch Hebung/Ablagerung tatsächlich aufgebaut wird.
var debug_stats_label: Label
var debug_warning_label: Label
var debug_legend_label: Label
var debug_difference_enabled := false
var debug_difference_scale := 0.01
var debug_refresh_timer := 0.0
var debug_dirty := true

const DBG_MIN := 0
const DBG_MEAN := 1
const DBG_MAX := 2
const DBG_RELIEF := 3
const DBG_DELTA_MEAN := 4
const DBG_DELTA_MAX := 5
const DBG_BELOW_REFERENCE_VOLUME := 6
const DBG_ABOVE_REFERENCE_VOLUME := 7
const DBG_NET_VOLUME := 8
const DBG_MAX_REMOVED := 9
const DBG_MAX_ADDED := 10
const DBG_SERVO := 11
const DBG_UPLIFT := 12
const DBG_RELIEF_TARGET := 13
const DBG_REFERENCE_YEAR := 14
const DBG_INVALID := 15
const DBG_RELIEF_SIGNAL := 16   # robustes Regelsignal des Servo-Bodens (p95 − Median der Landhöhen)
const DBG_RIDGE_CURVATURE := 17 # mittlere Grat-Krümmung: stark negativ = jung/spitz, → 0 = alt/rund
const DBG_RELIEF_LOW := 18      # Talseitenrelief (Median − p05) — Gegenprobe zum Regelsignal
const DEBUG_STATS_COUNT := 19
const DEBUG_REFRESH_SECONDS := 1.0

# UI-Referenzen (Toggle-Zustände & Slider-Wertanzeigen)
var speed_buttons: Array[Button] = []
var tool_buttons: Array[Button] = []
var radius_value: Label
var strength_value: Label
var radius_slider: HSlider

# --- Speichern/Laden (Issue #8) ---------------------------------------------
## EIN fester Speicherplatz statt Dateidialog: das Spiel führt genau eine Welt,
## und eine Welt ist groß (n=832 → ~109 MB, das ganze Zustands-Inventar). Mehrere
## Slots/Namen sind eine eigene UI-Frage (ROADMAP), nicht Teil von #8.
const SAVE_PATH := "user://saves/welt.rsworld"
var world_status_label: Label
var world_dialog: AcceptDialog

## Werkzeug-Vertrag (Issue #53): EINE Tabelle für Beschriftung, Brush-Modus und
## Verhalten. `mode` ist der Rohwert von `BrushTool` in SimCore (#79) — über die
## Brücke geht nur diese Zahl, also müssen beide Reihenfolgen übereinstimmen
## (Wächter: SimCoreTests/ToolContractTests.swift). Die Taste ist die
## Tabellen-Position (1…N), nicht noch eine dritte Kopie.
##
## Optionale Felder, jedes ersetzt eine vorher verstreute Magie-Zahl:
##   shift           — Werkzeug, auf das Shift umschaltet (Anheben ↔ Absenken)
##   samples_target  — braucht die Geländehöhe am Strich-Beginn (Einebnen)
##   stroke_spacing  — zeichnet EINZELHIEBE entlang des Strichs, Abstand in Zellen
##                     (Spitzhacke: auf der Stelle verharren gräbt nicht tiefer)
##   strength_factor — Faktor auf die Pinselstärke (Spitzhacke schlägt kräftiger)
##   radius_capped   — echte Breite ist auf `pick_radius_cap` gedeckelt (Ring-Visual)
## Neues Werkzeug = eine Zeile hier plus ein `case` in BrushTool.
const TOOLS := [
	{"icon": "⛰", "name": "Anheben", "mode": 0, "shift": 1},
	{"icon": "🕳", "name": "Absenken", "mode": 1, "shift": 0},
	{"icon": "〰", "name": "Glätten", "mode": 2},
	{"icon": "▭", "name": "Einebnen", "mode": 3, "samples_target": true},
	{"icon": "🌋", "name": "Aufrauen", "mode": 4},
	{"icon": "⛏", "name": "Spitzhacke", "mode": 5, "stroke_spacing": 1.5,
		"strength_factor": 1.5, "radius_capped": true},
]
const SPEEDS := [["⏸ Pause", 0.0], ["10 J/s", 10.0], ["30 J/s", 30.0], ["60 J/s", 60.0]]

func _ready() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("GDExtension 'SimNode' nicht geladen — .dylib/.gdextension prüfen.")
		return
	sim = ClassDB.instantiate("SimNode")
	add_child(sim)
	if OS.has_environment("RS_SEED"): # für Screenshot-Vergleiche verschiedener Terrains
		sim_seed = int(OS.get_environment("RS_SEED"))
		sim.generate(sim_seed)
	N = sim.gridSize()
	world_size = sim.worldSize()
	cam_dist = world_size * 1.35 # Start-Zoom skaliert mit der Weltgröße
	if OS.has_environment("RS_DIST"): # Kamera-Distanz für Zoom-Screenshots
		cam_dist = float(OS.get_environment("RS_DIST"))
	sea = sim.seaLevel()
	pick_radius_cap = sim.pickaxeMaxRadiusWorld()
	half = world_size / 2.0
	step = world_size / float(N - 1)
	# Die Simulation bleibt immer bei N×N. Nur das GPU-Displacement nutzt eine
	# adaptive Tessellation; per-pixel-Normalen und Heightmap bleiben unverändert.
	render_quality = OS.get_environment("RS_QUALITY").to_lower()
	if render_quality.is_empty():
		render_quality = "balanced"
	if OS.has_environment("RS_FPS"):
		active_fps_cap = 0  # s. ACTIVE_FPS_CAP
	var requested_grid := N if render_quality == "quality" else (
		PERFORMANCE_TERRAIN_GRID if render_quality == "performance" else BALANCED_TERRAIN_GRID)
	if OS.has_environment("RS_RENDER_GRID"):
		requested_grid = int(OS.get_environment("RS_RENDER_GRID"))
	terrain_grid = clampi(requested_grid, 64, N)
	# Die Band-Geometrie sampelt ihre Höhen von der SICHTBAREN Oberfläche
	# dieses Gitters (SimNode.setRenderGrid) — auf Sim-Höhen versank sie an
	# Steilstrecken im gröberen Mesh und ragte als blaue Zacken heraus.
	sim.setRenderGrid(terrain_grid)
	# A/B ohne Rebuild: SimNode liest dieselbe Env-Variable. Gesetzt = alter
	# Raster-Stempel (Mäander/Altarme ins Wasserfeld, keine Band-Geometrie).
	river_ribbons = not OS.has_environment("RS_WATER_STAMP")
	# Kamera für reproduzierbare A/B-Screenshots: Blickpunkt in WELT-Koordinaten
	# ("x,z") und Orbit-Winkel. Ohne sie zeigt jeder Lauf die Kartenmitte — für
	# eine Mündung/ein Delta ist das der falsche Ausschnitt.
	if OS.has_environment("RS_TARGET"):
		var parts := OS.get_environment("RS_TARGET").split(",")
		if parts.size() == 2:
			cam_target = Vector3(float(parts[0]), 0.0, float(parts[1]))
	if OS.has_environment("RS_YAW"):
		cam_yaw = float(OS.get_environment("RS_YAW"))
	if OS.has_environment("RS_PITCH"):
		cam_pitch = float(OS.get_environment("RS_PITCH"))

	_setup_scene()
	_setup_ui()
	sim.captureDebugReference()
	if OS.has_environment("RS_DEBUG_DIFF"): # automatisierte Diagnose-Screenshots
		_set_debug_difference(true)
	# REIHENFOLGE: erst einebnen, dann simulieren — nur so ist der Repro aus
	# Issue #26 (großflächige Einebnung, dann Zeitraffer) überhaupt abbildbar.
	if OS.has_environment("RS_FLATTEN"): # Debug: exakt flache Fläche
		# Gekachelt über die GANZE Karte mit den UI-Grenzwerten (Radius 30,
		# Stärke 3) — derselbe Aufbau wie `FlattenRegeneration` im SimCore-Test.
		var fr := 30.0
		var fstep := maxf(1.0, fr / (world_size / float(N - 1)) * 0.5)
		var last := float(N - 1)
		for round_i in 14:
			var gz := 0.0
			while gz <= last + fstep:
				var gx := 0.0
				while gx <= last + fstep:
					sim.brush(3, minf(gx, last), minf(gz, last), fr, 3.0, sea + 0.25)
					gx += fstep
				gz += fstep
		sim.recomputeFlow()
		# Bei diesem Repro interessiert nur die Entwicklung AB der flachen Fläche.
		sim.captureDebugReference()
	if OS.has_environment("RS_STEP"): # für Screenshots: erodiertes Terrain zeigen
		var total := float(OS.get_environment("RS_STEP"))
		var done := 0.0
		var chunk := 1000.0
		if OS.has_environment("RS_STEP_CHUNK"):
			chunk = maxf(1.0, float(OS.get_environment("RS_STEP_CHUNK")))
		while done < total: # in Schritten wie der Zeitraffer (repräsentativ)
			sim.step(chunk)
			done += chunk
	sim.recomputeFlow()
	_invalidate_h_cache()
	if OS.has_environment("RS_TARGET"):
		# Blickpunkt auf die GELÄNDEHÖHE heben: mit y = 0 zielt die Kamera unter
		# die Landschaft, und der Ausschnitt zeigt Himmel statt Mündung.
		cam_target.y = _sample_h((cam_target.x + half) / step, (cam_target.z + half) / step) * HSCALE
		_update_camera()
	_update_year()
	# Bänder VOR den Texturen: das Wasserfeld deckelt Korridore nur unter
	# Kanälen, die im letzten Ribbon-Build wirklich ein Band bekamen
	# (SimNode.waterFieldBytes liest bandChannelFlags) — andersherum malte es
	# diesen einen Upload mit leeren/alten Flags.
	_maybe_rebuild_rivers_throttled(true)
	_update_terrain_textures()
	_maybe_rebuild_trees()
	_refresh_debug()
	if OS.has_environment("RS_DIAG"):
		_diag()

func _diag() -> void:
	var land := 0
	_ensure_h_cache()
	for k in h_cache.size():
		if h_cache[k] > sea + 0.012:
			land += 1
	print("DIAG sim_cells=", h_cache.size(), " terrain_verts=", terrain_grid * terrain_grid, " land=", land)
	var step_t0 := Time.get_ticks_usec()
	sim.step(60.0)
	var step_ms := (Time.get_ticks_usec() - step_t0) / 1000.0
	_invalidate_h_cache()
	print("DIAG PERF step_60y_ms=", step_ms)
	var t0 := Time.get_ticks_usec()
	for r in 10:
		_update_terrain_textures()
	var t_terr := (Time.get_ticks_usec() - t0) / 10000.0
	print("DIAG PERF terrain_texupload_ms=", t_terr)

# ---------------------------------------------------------------- Szene / UI

## Wasser-Kalibrierung über die Brücke (Issue #91, Expand-Schritt): setzt jeden
## benannten Wert aus SimCore (SimRender.WaterUniforms) auf jedes übergebene
## Material. Ein Shader, der den Namen deklariert, bekommt damit den Wert; einen
## undeklarierten Namen ignoriert Godot. Statisch und ohne Szene, damit
## game/tests/water_uniforms.gd genau diese Funktion headless prüfen kann.
static func apply_water_calibration(sim_node: Object, mats: Array[ShaderMaterial]) -> void:
	var scalar_names: PackedStringArray = sim_node.waterScalarUniformNames()
	var scalar_values: PackedFloat32Array = sim_node.waterScalarUniformValues()
	var color_names: PackedStringArray = sim_node.waterColorUniformNames()
	var color_values: PackedVector3Array = sim_node.waterColorUniformValues()
	for mat in mats:
		for i in scalar_names.size():
			mat.set_shader_parameter(scalar_names[i], scalar_values[i])
		for i in color_names.size():
			mat.set_shader_parameter(color_names[i], color_values[i])


func _setup_scene() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	# Prozeduraler Himmel → liefert realistisches Ambient UND Reflexionen fürs Wasser.
	var sky_mat := ProceduralSkyMaterial.new()
	# Entsättigter, gedämpfter Himmel (grau-teal wie in der Referenz) → NEUTRALES
	# Ambient statt kräftig blauem Fülllicht, das grauen Fels blau einfärbt.
	sky_mat.sky_top_color = Color(0.50, 0.58, 0.66)
	sky_mat.sky_horizon_color = Color(0.74, 0.78, 0.80)
	sky_mat.ground_bottom_color = Color(0.30, 0.31, 0.31)
	sky_mat.ground_horizon_color = Color(0.66, 0.68, 0.70)
	sky_mat.sun_angle_max = 8.0
	sky_mat.energy_multiplier = 0.6
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.28
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# ACES bleibt für die Spitzlichter, aber ohne ausgefressenen Schnee und den
	# milchigen Glow des alten Materials.
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 0.68
	e.ssao_enabled = render_quality != "performance"
	e.ssao_intensity = 1.45
	e.glow_enabled = false
	e.adjustment_enabled = true
	e.adjustment_saturation = 0.98
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.76, 0.78, 0.79)
	e.fog_density = 0.0006
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	# Die Materialkontraste tragen das Gelände. Das Licht modelliert die Form,
	# ohne Fels und Schnee wie im alten 1.6-Energy-Setup weiß auszubrennen.
	sun.light_color = Color(1.0, 0.95, 0.88)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)
	sun.look_at_from_position(Vector3(-60, 120, 60), Vector3.ZERO, Vector3.UP)

	cam = Camera3D.new()
	cam.far = 1000.0
	cam.fov = 55.0
	add_child(cam)
	_update_camera()

	terrain_mi = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(world_size, world_size)
	pm.subdivide_width = terrain_grid - 2
	pm.subdivide_depth = terrain_grid - 2
	terrain_mi.mesh = pm
	terrain_mi.extra_cull_margin = 1000.0 # Displacement sprengt die Plan-AABB
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("hscale", HSCALE)
	terrain_mat.set_shader_parameter("world_size", world_size)
	terrain_mat.set_shader_parameter("grid_n", float(N))
	terrain_mat.set_shader_parameter("sea_level", sea)
	terrain_mat.set_shader_parameter("detail_enabled", render_quality != "performance")
	terrain_mat.set_shader_parameter("material_enabled", render_quality != "performance")
	terrain_mi.material_override = terrain_mat
	add_child(terrain_mi)

	if OS.has_environment("RS_WATER_GPU"):
		water_gpu = true
	if water_gpu:
		_setup_water_gpu()

	water_mi = MeshInstance3D.new()
	var wp := PlaneMesh.new()
	# Der Rand liegt selbst bei maximalem Zoom/Pan hinter `cam.far`; sichtbar
	# bleibt nur die Wasseroberfläche, keine quadratische Modellplatte.
	wp.size = Vector2(cam.far * 3.0, cam.far * 3.0)
	water_mi.mesh = wp
	ocean_mat = ShaderMaterial.new()
	ocean_mat.shader = load("res://shaders/ocean.gdshader")
	ocean_mat.set_shader_parameter("world_size", world_size)
	ocean_mat.set_shader_parameter("sea_level", sea)
	height_field.mirror_to(ocean_mat)
	water_mi.material_override = ocean_mat
	water_mi.position.y = sea * HSCALE
	add_child(water_mi)

	# Wasser-Geometrie (außer im RS_WATER_STAMP-Modus): EIN MeshInstance3D, dessen
	# ArrayMesh _rebuild_rivers aus den SimNode-Puffern füllt.
	if river_ribbons:
		river_mi = MeshInstance3D.new()
		river_mi.mesh = river_mesh
		river_mat = ShaderMaterial.new()
		river_mat.shader = load("res://shaders/water.gdshader")
		river_mi.material_override = river_mat
		river_mi.extra_cull_margin = 1000.0 # Geometrie ändert sich laufend
		river_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(river_mi)

	# Wasser-Kalibrierung aus SimCore (Issue #91) auf alle Wasser-Materialien;
	# das Band-Material fehlt im RS_WATER_STAMP-Modus.
	var water_mats: Array[ShaderMaterial] = [terrain_mat, ocean_mat]
	if river_mat != null:
		water_mats.append(river_mat)
	apply_water_calibration(sim, water_mats)

	# Baum-MultiMeshes (Instanzen kommen später aus _rebuild_trees).
	for v in TREE_VARIANTS:
		var mmi := MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _tree_mesh(v)
		mmi.multimesh = mm
		# Budget: zehntausende Schattenwerfer kosteten mehr als sie optisch
		# bringen (Bäume sind aus der Orbit-Distanz wenige Pixel groß).
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		tree_mmi.append(mmi)

	# Pinsel-Ring
	ring_mi = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.92
	torus.outer_radius = 1.0
	ring_mi.mesh = torus
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(1.0, 0.87, 0.4)
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.disable_receive_shadows = true
	ring_mi.material_override = rmat
	ring_mi.visible = false
	add_child(ring_mi)

func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	# Autonome Screenshots (RS_SHOT) zeigen die LANDSCHAFT: die Bedienleiste
	# verdeckt sonst die halbe linke Bildhälfte, und genau dort liegen in der
	# A/B-Serie die Mündungen. Die Diagnosewerte stehen ohnehin im Log.
	layer.visible = not OS.has_environment("RS_SHOT")
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(340, 0)
	var ui_theme := Theme.new()
	ui_theme.default_font_size = 20
	panel.theme = ui_theme
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.11, 0.9)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 7)
	panel.add_child(vb)

	year_label = Label.new()
	year_label.text = "Jahr 0"
	year_label.add_theme_font_size_override("font_size", 30) # Jahr prominent
	vb.add_child(year_label)

	_section(vb, "ZEIT")
	var speeds := HBoxContainer.new()
	speeds.add_theme_constant_override("separation", 6)
	vb.add_child(speeds)
	var speed_group := ButtonGroup.new()
	for pair in SPEEDS:
		var rate: float = pair[1]
		var b := _mk_button(pair[0], true, speed_group)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _set_rate(rate))
		speeds.add_child(b)
		speed_buttons.append(b)
	speed_buttons[0].set_pressed_no_signal(true)

	var jumps := GridContainer.new()
	jumps.columns = 2
	jumps.add_theme_constant_override("h_separation", 6)
	jumps.add_theme_constant_override("v_separation", 6)
	vb.add_child(jumps)
	for pair in [["+100 J.", 100.0], ["+1.000 J.", 1000.0],
			["+10.000 J.", 10000.0], ["+100.000 J.", 100000.0]]:
		var yrs: float = pair[1]
		var b := _mk_button(pair[0], false, null)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _jump(yrs))
		jumps.add_child(b)

	_section(vb, "WERKZEUG")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)
	var tool_group := ButtonGroup.new()
	for t in TOOLS.size():
		var b := _mk_button("%s %s" % [TOOLS[t]["icon"], TOOLS[t]["name"]], true, tool_group)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "Taste %d" % (t + 1)
		b.pressed.connect(func(): current_tool = t)
		grid.add_child(b)
		tool_buttons.append(b)
	tool_buttons[0].set_pressed_no_signal(true)

	_section(vb, "VEGETATION")
	tree_coverage_picker = OptionButton.new()
	tree_coverage_picker.add_item("Keine", TreeCoverage.NONE)
	tree_coverage_picker.add_item("Reduziert", TreeCoverage.REDUCED)
	tree_coverage_picker.add_item("Voll", TreeCoverage.FULL)
	tree_coverage_picker.select(TreeCoverage.REDUCED)
	tree_coverage_picker.tooltip_text = "Bäume ausblenden oder für bessere Geländelesbarkeit reduzieren (V)"
	tree_coverage_picker.focus_mode = Control.FOCUS_NONE
	tree_coverage_picker.item_selected.connect(_set_tree_coverage)
	vb.add_child(tree_coverage_picker)

	_section(vb, "PINSEL")
	radius_slider = _mk_slider(vb, "Radius", 3.0, 30.0, 1.0, brush_radius,
		func(v: float): brush_radius = v)
	radius_value = _slider_value_label
	_mk_slider(vb, "Stärke", 0.25, 3.0, 0.05, brush_strength,
		func(v: float): brush_strength = v)
	strength_value = _slider_value_label
	_refresh_slider_labels()

	_section(vb, "WELT")
	var regen_b := _mk_button("🌍 Neues Terrain", false, null)
	regen_b.pressed.connect(_regen)
	vb.add_child(regen_b)

	var world_io := HBoxContainer.new()
	world_io.add_theme_constant_override("separation", 6)
	vb.add_child(world_io)
	var save_b := _mk_button("💾 Speichern", false, null)
	save_b.tooltip_text = "Welt nach %s schreiben (F5)" % SAVE_PATH
	save_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_b.pressed.connect(_save_world)
	world_io.add_child(save_b)
	var load_b := _mk_button("📂 Laden", false, null)
	load_b.tooltip_text = "Gespeicherte Welt zurückholen (F9)"
	load_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_b.pressed.connect(_load_world)
	world_io.add_child(load_b)

	world_status_label = Label.new()
	world_status_label.add_theme_font_size_override("font_size", 15)
	world_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	world_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(world_status_label)

	# Fehlerdialog: Speichern/Laden kann echt scheitern (alte Formatversion,
	# beschädigte oder fremde Datei, volle Platte). Die Meldung kommt wörtlich aus
	# SimCore (`SnapshotError`) — kein zweiter Text, der auseinanderlaufen kann.
	world_dialog = AcceptDialog.new()
	world_dialog.title = "Welt"
	world_dialog.dialog_autowrap = true
	world_dialog.theme = ui_theme
	layer.add_child(world_dialog)

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	hint.text = "WASD: Kamera bewegen · Links: formen (Shift: ⛰↔🕳) · Rechts: drehen\nZoom: +/− · Werkzeug: 1–6 · Radius: [ ] · Vegetation: V · Pause: Leertaste\nSpeichern: F5 · Laden: F9"
	vb.add_child(hint)

	# Diagnose bewusst als eigene Karte: Die Werkzeugleiste bleibt auch auf kleinen
	# Fenstern vollständig sichtbar, während die Entwicklungswerte oben im Blick sind.
	var debug_panel := PanelContainer.new()
	debug_panel.position = Vector2(470, 16) # Platzhalter — dockt unten an die Werkzeug-Karte
	debug_panel.custom_minimum_size = Vector2(340, 0)
	# Rechts NEBEN der Werkzeug-Karte andocken statt festem x: deren Breite ist
	# inhaltsgetrieben (~540px bei Font 20) und überlappte das feste 470.
	panel.resized.connect(func() -> void:
		debug_panel.position.x = panel.position.x + panel.size.x + 16)
	debug_panel.theme = ui_theme
	debug_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(debug_panel)
	var debug_vb := VBoxContainer.new()
	debug_vb.add_theme_constant_override("separation", 7)
	debug_panel.add_child(debug_vb)
	var debug_title := Label.new()
	debug_title.text = "DIAGNOSE"
	debug_title.add_theme_font_size_override("font_size", 13)
	debug_title.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	debug_vb.add_child(debug_title)

	debug_stats_label = Label.new()
	debug_stats_label.add_theme_font_size_override("font_size", 15)
	debug_stats_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.72))
	debug_vb.add_child(debug_stats_label)
	debug_warning_label = Label.new()
	debug_warning_label.add_theme_font_size_override("font_size", 15)
	debug_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_vb.add_child(debug_warning_label)

	var debug_buttons := HBoxContainer.new()
	debug_buttons.add_theme_constant_override("separation", 6)
	debug_vb.add_child(debug_buttons)
	var difference_b := _mk_button("Δ-Karte", true, null)
	difference_b.tooltip_text = "Blau: abgetragen · Rot: aufgebaut"
	difference_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	difference_b.toggled.connect(_set_debug_difference)
	debug_buttons.add_child(difference_b)
	var reference_b := _mk_button("Referenz setzen", false, null)
	reference_b.tooltip_text = "Aktuelles Terrain als neuen Vergleichspunkt verwenden"
	reference_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reference_b.pressed.connect(_capture_debug_reference)
	debug_buttons.add_child(reference_b)

	debug_legend_label = Label.new()
	debug_legend_label.add_theme_font_size_override("font_size", 14)
	debug_legend_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.58))
	debug_legend_label.visible = false
	debug_vb.add_child(debug_legend_label)

# --- UI-Helfer -------------------------------------------------------------

var _slider_value_label: Label # letzte von _mk_slider erzeugte Wertanzeige

func _section(parent: VBoxContainer, title: String) -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	parent.add_child(sep)
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	parent.add_child(l)

func _mk_button(text: String, toggle: bool, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	if group:
		b.button_group = group
	# Kein Fokus: Leertaste soll Pause togglen, nie den zuletzt geklickten Button.
	b.focus_mode = Control.FOCUS_NONE
	return b

func _mk_slider(parent: VBoxContainer, title: String, minv: float, maxv: float,
		stepv: float, value: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var name_l := Label.new()
	name_l.text = title
	name_l.custom_minimum_size = Vector2(88, 0)
	name_l.add_theme_font_size_override("font_size", 18)
	row.add_child(name_l)
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = stepv
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var val_l := Label.new()
	val_l.custom_minimum_size = Vector2(52, 0)
	val_l.add_theme_font_size_override("font_size", 18)
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_l)
	_slider_value_label = val_l
	s.value_changed.connect(func(v: float):
		on_change.call(v)
		_refresh_slider_labels())
	return s

func _refresh_slider_labels() -> void:
	if radius_value:
		radius_value.text = str(int(brush_radius))
	if strength_value:
		strength_value.text = "%.2f" % brush_strength

func _set_rate(rate: float) -> void:
	year_rate = rate
	if rate > 0.0:
		last_rate = rate
	# Toggle-Zustand der Tempo-Buttons nachziehen (auch bei Leertaste/Code-Aufruf).
	for i in SPEEDS.size():
		speed_buttons[i].set_pressed_no_signal(SPEEDS[i][1] == rate)

func _set_tree_coverage(coverage: int) -> void:
	tree_coverage = coverage
	for mmi in tree_mmi:
		mmi.visible = coverage != TreeCoverage.NONE
	if coverage != TreeCoverage.NONE:
		_rebuild_trees()

# ---------------------------------------------------------------- Zeit

var _jumping := false
func _jump(years: float) -> void:
	if _jumping: # Doppelklicks während eines laufenden Sprungs schlucken
		return
	_jumping = true
	# In Zeitraffer-großen Chunks steppen und zwischendurch rendern: bei
	# +100.000 J. fräße EIN step() sonst ~1 Minute ohne jedes Feedback —
	# so sieht man die Welt im Schnelldurchlauf altern.
	var done := 0.0
	while done < years:
		var chunk := minf(2000.0, years - done)
		sim.step(chunk)
		done += chunk
		_after_sim()
		await get_tree().process_frame
	# Der Deckel darf den sichtbaren Endzustand nicht bis zum nächsten
	# Zeitraffer-Tick verzögern (der Sprung endet typischerweise pausiert).
	# Voller _after_sim-Endstand statt nur Ribbon-Rebuild: die Wasser-Textur
	# hängt am Bau-Ergebnis der Bänder und muss NACH ihnen entstehen.
	_after_sim(true)
	_jumping = false

func _regen() -> void:
	sim_seed = (sim_seed * 16807 + 1) % 2147483647
	sim.generate(sim_seed)
	sim.recomputeFlow()
	_after_sim(true)

# ------------------------------------------------- Speichern / Laden (Issue #8)

## Schreibt die laufende Welt. SimNode arbeitet auf BETRIEBSSYSTEM-Pfaden (SimCore
## kennt Godots `user://` nicht), deshalb `globalize_path`.
func _save_world() -> void:
	if _jumping: # mitten in einem Zeitsprung ist der Zustand noch in Bewegung
		world_status_label.text = "Zeitsprung läuft — später speichern"
		return
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	var err: String = sim.saveWorld(abs_path)
	if not err.is_empty():
		_show_world_error("Speichern fehlgeschlagen", err)
		return
	var mb := float(sim.lastWorldFileBytes()) / (1024.0 * 1024.0)
	world_status_label.text = "Gespeichert: Jahr %s · %.1f MB" % [
		_fmt(int(sim.currentYear())), mb]

## Holt die gespeicherte Welt zurück. Danach ist der Zustand vollständig (der
## Seespiegel kommt aus der Datei und schwingt NICHT ein, Issue #8) — es genügt,
## die Texturen neu zu ziehen; ein Sim-Schritt ist ausdrücklich nicht nötig.
func _load_world() -> void:
	if _jumping: # der laufende Sprung würde sofort auf die geladene Welt steppen
		world_status_label.text = "Zeitsprung läuft — später laden"
		return
	if not FileAccess.file_exists(SAVE_PATH):
		_show_world_error("Kein Spielstand",
			"Unter %s liegt noch keine Welt. Erst speichern (F5)." % SAVE_PATH)
		return
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	# Geometrie-Prüfung VOR dem Laden, solange die laufende Welt noch steht.
	var mismatch := _world_geometry_mismatch(
		sim.worldFileGridSize(abs_path), sim.worldFileWorldSize(abs_path))
	if not mismatch.is_empty():
		_show_world_error("Welt nicht darstellbar", mismatch)
		return
	var err: String = sim.loadWorld(abs_path)
	if not err.is_empty():
		_show_world_error("Laden fehlgeschlagen", err)
		return
	# Pausieren: nach dem Laden soll die zurückgeholte Welt stehen, nicht sofort
	# im zuletzt eingestellten Tempo weiterlaufen.
	_set_rate(0.0)
	# Konstanten, die aus der Datei-Config kommen können, nachziehen.
	sea = sim.seaLevel()
	pick_radius_cap = sim.pickaxeMaxRadiusWorld()
	terrain_mat.set_shader_parameter("sea_level", sea)
	ocean_mat.set_shader_parameter("sea_level", sea)
	water_mi.position.y = sea * HSCALE
	_after_sim(true) # water_blend = 1.0 → kein Überblenden aus der alten Welt
	_refresh_debug()
	world_status_label.text = "Geladen: Jahr %s · pausiert" % _fmt(int(sim.currentYear()))

## Passt die GEOMETRIE einer Welt-Datei zu dieser Sitzung? Rückgabe: leerer
## String = ja, sonst der Grund als fertige Meldung.
##
## Diese Sitzung ist in `_ready` auf EINE Geometrie festgelegt: Höhen-/Farb-/
## Wasser-Texturen und `h_cache` haben N × N Einträge, Mesh-Größe und
## -Tessellation, Kamera-Distanz, Wasserebene, Pinsel-Ring und die
## Welt→Zelle-Umrechnung von Raycast/Werkzeugen (`half`, `step`)
## hängen an `world_size`. Beides muss deshalb geprüft werden — `n` allein
## genügt NICHT: bei gleicher Auflösung, aber anderer Weltgröße liefe die
## geladene Simulation in anderen Weltkoordinaten als Darstellung und Pinsel
## (Zellgröße = world/(n−1)). Dass `n` und `world` in diesem Projekt nur
## zusammen geändert werden, ist eine Konvention für den QUELLCODE; eine
## Datei kann trotzdem jede Kombination mitbringen (die Datei-Config ist beim
## Laden autoritativ, s. `WorldSnapshot`).
##
## Ablehnen statt umbauen ist die bewusste Entscheidung: die abhängigen Render-
## und Interaktionsstrukturen komplett neu aufzubauen wäre ein zweiter, nur bei
## fremden Dateien überhaupt erreichbarer Aufbaupfad neben `_setup_scene` —
## mehr Code und mehr Bruchfläche als der Fall wert ist (Dokumentation:
## docs/world-save-format.md). −1 heißt „nicht lesbar"; die passende Meldung
## dazu liefert dann `loadWorld` selbst.
func _world_geometry_mismatch(file_grid: int, file_world: float) -> String:
	if file_grid > 0 and file_grid != N:
		return ("Diese Welt hat die Gitterauflösung %d × %d, die laufende Sitzung "
			+ "rendert %d × %d. Sie wurde NICHT geladen.") % [file_grid, file_grid, N, N]
	if file_world > 0.0 and not is_equal_approx(file_world, world_size):
		return ("Diese Welt ist %.3f Welteinheiten groß, die laufende Sitzung "
			+ "rendert %.3f. Sie wurde NICHT geladen (Darstellung, Kamera und "
			+ "Werkzeuge würden in anderen Koordinaten arbeiten als die Simulation)."
			) % [file_world, world_size]
	return ""

func _show_world_error(title: String, message: String) -> void:
	world_status_label.text = title
	push_warning("%s: %s" % [title, message])
	world_dialog.title = title
	world_dialog.dialog_text = message
	world_dialog.popup_centered(Vector2i(560, 0))

func _capture_debug_reference() -> void:
	sim.captureDebugReference()
	_refresh_debug()

func _set_debug_difference(enabled: bool) -> void:
	debug_difference_enabled = enabled
	debug_legend_label.visible = enabled
	terrain_mat.set_shader_parameter("debug_difference", enabled)
	if enabled:
		_refresh_debug()

func _after_sim(force_rivers := false) -> void:
	_invalidate_h_cache()
	_update_year()
	# Bänder VOR den Texturen (s. _ready): das Wasserfeld liest das
	# Bau-Ergebnis der Bänder (bandChannelFlags) für den Korridor-Deckel.
	_maybe_rebuild_rivers_throttled(force_rivers)
	_update_terrain_textures()
	_maybe_rebuild_trees()
	debug_dirty = true

var _shot_frame := 0
var _fps_accum := 0.0

## Ein Werkzeugstrich besitzt die Höhen, bis die Maustaste losgelassen wird.
## Sonst arbeitet der globale Sim-Schritt bei 60 J/s gleichzeitig gegen Brush,
## Höhen-Upload und Fluss-Nachzug. Das gewählte Tempo bleibt dabei unverändert;
## der nächste Prozess-Frame nach dem Loslassen setzt den Zeitraffer fort.
static func _simulation_should_step(rate: float, tool_active: bool) -> bool:
	return rate > 0.0 and not tool_active

func _process(delta: float) -> void:
	# Selbst-Screenshot für autonome visuelle Verifikation (nur mit RS_SHOT-Env).
	if OS.has_environment("RS_SHOT"):
		_shot_frame += 1
		if _shot_frame == 45:
			var img := get_viewport().get_texture().get_image()
			img.save_png(OS.get_environment("RS_SHOT"))
			get_tree().quit()
	# FPS-Messung im Zeitraffer (nur mit RS_FPS-Env).
	if OS.has_environment("RS_FPS"):
		if not OS.has_environment("RS_IDLE"): year_rate = 60.0
		_shot_frame += 1
		if _shot_frame > 60:
			_fps_accum += Engine.get_frames_per_second()
		if _shot_frame == 260:
			print("RS_FPS avg=", _fps_accum / 200.0)
			get_tree().quit()

	# Leerlauf-Drossel (s. IDLE_FPS_CAP): nur wenn wirklich nichts passiert —
	# Zeitraffer, Sprung und Sculpting zählen als Aktivität.
	var idle := year_rate == 0.0 and not _jumping and not sculpting \
		and Time.get_ticks_msec() - last_activity_msec > IDLE_FPS_DELAY_MSEC
	if idle:
		Engine.max_fps = IDLE_FPS_CAP
	else:
		Engine.max_fps = active_fps_cap
	if idle != render_loop_suspended:
		render_loop_suspended = idle
		if idle:
			RenderingServer.render_loop_enabled = false
		else:
			RenderingServer.render_loop_enabled = true

	# Ohne Bild gibt es auch keine unsichtbaren Shader-, Kamera- oder Raycast-
	# Aktualisierungen. Eingaben laufen im Engine-Loop weiter und wecken Main
	# über `_input`; danach setzt der nächste Prozess-Frame hier normal fort.
	if idle:
		return

	u_time += delta * (2.5 if year_rate > 0.0 else 0.7)
	if terrain_mat:
		terrain_mat.set_shader_parameter("u_time", u_time)
	if ocean_mat:
		ocean_mat.set_shader_parameter("u_time", u_time)
	if river_mat:
		river_mat.set_shader_parameter("u_time", u_time)
	if debug_dirty:
		debug_refresh_timer += delta
		if debug_refresh_timer >= DEBUG_REFRESH_SECONDS:
			_refresh_debug()

	if _simulation_should_step(year_rate, sculpting):
		# Jahre über das Render-Intervall AKKUMULIEREN und nur EINMAL pro Render
		# steppen — statt jeden Frame (die Sim-Schritte enthalten mehrere O(n²)-
		# Pässe: computeFlow, outletIncision, Hangdiffusion, wave). Zwischen zwei
		# Renders ~9 Schritte à 1 Jahr wären 9× diese Pässe für dasselbe Ergebnis;
		# ein Schritt à 9 Jahre ist gleichwertig und ~9× billiger.
		pending_years += year_rate * delta
		rebuild_timer += delta
		if rebuild_timer > SIM_TICK_SECONDS:
			var elapsed := rebuild_timer
			rebuild_timer = 0.0
			# Jahre/Schritt deckeln → hält jeden Schritt billig (keine Todesspirale).
			var years := minf(pending_years, 240.0)
			pending_years = 0.0
			sim.step(years)
			_invalidate_h_cache()
			_update_year()
			debug_dirty = true
			overlay_timer += elapsed
			var update_overlays := overlay_timer >= 0.30
			if update_overlays:
				overlay_timer = 0.0
			# Zeitraffer: Wasserfeld weich blenden → kein Springen zwischen den
			# diskreten D8-Netzen (die ~27% je Update umwürfeln). 0.15 statt 0.35:
			# bei 60 J/s sind 0.3 s schon 18 Sim-Jahre — mit 0.35 schnappten
			# Läufe/Seeufer sichtbar um (User: „super schlimm"), mit 0.15 gleiten
			# sie über ~2 s in die neue Lage.
			_update_terrain_textures(0.15, update_overlays)
			if update_overlays:
				_maybe_rebuild_trees()
				_maybe_rebuild_rivers_throttled()

	if sculpting:
		var hit := _raycast_terrain()
		if hit != Vector3.INF:
			var gx := (hit.x + half) / step
			var gz := (hit.z + half) / step
			# Shift kehrt Anheben/Absenken um — welches Werkzeug das Gegenstück
			# ist, sagt die Tabelle (`shift`), nicht eine Zahl hier.
			var tool: Dictionary = TOOLS[current_tool]
			if Input.is_key_pressed(KEY_SHIFT):
				tool = TOOLS[tool.get("shift", current_tool)]
			var mode: int = tool["mode"]
			var strength: float = brush_strength * tool.get("strength_factor", 1.0)
			var spacing: float = tool.get("stroke_spacing", 0.0)
			if spacing > 0.0:
				# Kerben ZEICHNEN — ein Hieb pro neu überstrichener Position, das
				# Segment zum letzten Hieb wird lückenlos aufgefüllt (Abstand ≈
				# halbe Hieb-Breite). Auf der Stelle verharren gräbt NICHT tiefer
				# (kein Dauerbohren).
				var p := Vector2(gx, gz)
				if pick_last == Vector2.INF:
					sim.brush(mode, gx, gz, brush_radius, strength, 0.0)
					pick_last = p
				else:
					while pick_last.distance_to(p) >= spacing:
						pick_last += (p - pick_last).normalized() * spacing
						sim.brush(mode, pick_last.x, pick_last.y, brush_radius, strength, 0.0)
			else:
				# Framerate-unabhängig: Wirkung ∝ Zeit statt ∝ Frames (60-FPS-
				# Referenz; delta-Deckel hält Ruckler-Frames von Riesen-Hieben ab).
				sim.brush(mode, gx, gz, brush_radius, strength * minf(delta, 0.05) * 60.0,
					flatten_target)
			_invalidate_h_cache()
			debug_dirty = true
			# Höhe sofort (billig): der Strich muss dem Zeiger ohne Verzögerung
			# folgen. Flussnetz, Overlays und Bänder laufen im gedrosselten Takt
			# nach (s. SCULPT_REFRESH_SECONDS).
			_update_terrain_textures(1.0, false)
			sculpt_refresh_timer += delta
			# Nachzug auf ZWEI Frames verteilt. GEMESSEN je Aufruf (n = 832,
			# M4 Max, Aug 2026, res://tests/sculpt_cost.gd):
			#   Teil 1  recomputeFlow        34,6 ms
			#   Teil 2  waterFieldBytes      14,4 ms
			#           terrainColor/Surface  0,9 ms je, filled-/heightsBytes 0,15
			#           buildRiverRibbons    11,6 ms — aber höchstens 1×/s,
			#                                s. RIVER_REBUILD_SECONDS
			# In EINEM Frame waren das 51 ms (mit Band-Rebuild 63) alle 0,15 s —
			# genau das Stocken unter dem Pinsel. Getrennt bleibt die
			# Gesamtarbeit gleich, die schlechteste Frame-Zeit sinkt auf die
			# 35 ms von Teil 1, und das Wasserfeld hängt einen Frame hinter der
			# Höhe: unsichtbar. Weiter zerlegen bringt nichts — recomputeFlow
			# allein dominiert und ist von hier aus nicht teilbar (es ist EIN
			# globaler Pass; ein lokaler Inkrement-Update wäre SimCore-Arbeit).
			# Der Takt selbst bleibt bei SCULPT_REFRESH_SECONDS — der ist auf das
			# Strich-GEFÜHL kalibriert, nicht auf die Frame-Zeit.
			if sculpt_refresh_pending:
				sculpt_refresh_pending = false
				_refresh_stroke_upload()
			elif sculpt_refresh_timer >= SCULPT_REFRESH_SECONDS:
				sculpt_refresh_timer = 0.0
				_refresh_stroke_flow()
				sculpt_refresh_pending = true

	_update_camera_pan(delta)
	_update_ring()
	_update_camera()

## Vollständige Aufbereitung nach einem Pinsel-Eingriff: Flussnetz neu rechnen,
## Overlays hochladen, Bänder neu bauen. Teuer (~51 ms bei n = 832, Aufschlüsselung
## am Aufruf im _process), deshalb gedrosselt aufgerufen — nicht pro Frame.
## Beim LOSLASSEN läuft sie in einem Zug: dort darf nichts auf einen Folgeframe
## warten, sonst bliebe ein beendeter Strich mit halb altem Flussnetz stehen.
func _refresh_after_stroke() -> void:
	_refresh_stroke_flow()
	_refresh_stroke_upload()

## Teil 1 des Nachzugs (teuer, ~35 ms): das Flussnetz reagiert auf den Eingriff.
func _refresh_stroke_flow() -> void:
	sim.recomputeFlow()
	_invalidate_h_cache()

## Teil 2 des Nachzugs (~17 ms): Overlays hochladen, Bänder nachziehen.
func _refresh_stroke_upload() -> void:
	_update_terrain_textures()
	_maybe_rebuild_rivers_throttled(true) # Sculpting droppt gestörte Kanäle → Struktur-Delta

## Strich beendet: einmal vollständig nachziehen, damit der fertige Eingriff nie
## mit einem halb alten Flussnetz stehen bleibt (der gedrosselte Takt kann
## mitten im Intervall aufgehört haben).
func _finish_stroke() -> void:
	sculpt_refresh_timer = 0.0
	sculpt_refresh_pending = false  # der vollständige Nachzug erledigt Teil 2 mit
	_refresh_after_stroke()
	_maybe_rebuild_trees()
	debug_dirty = true

func _update_camera_pan(delta: float) -> void:
	# Bewegung bleibt auf der Terrain-Ebene und folgt der Blickrichtung statt den
	# Weltachsen. Die Zoom-abhängige Geschwindigkeit hält sie in Nah- und Fernsicht
	# gleich gut kontrollierbar.
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
	if move == Vector2.ZERO:
		return
	last_activity_msec = Time.get_ticks_msec()
	var forward := Vector3(-sin(cam_yaw), 0.0, -cos(cam_yaw))
	var right := Vector3(cos(cam_yaw), 0.0, -sin(cam_yaw))
	var direction := (right * move.x + forward * move.y).normalized()
	var max_target := half * 0.92
	cam_target += direction * cam_dist * PAN_SPEED_FACTOR * delta
	cam_target.x = clampf(cam_target.x, -max_target, max_target)
	cam_target.z = clampf(cam_target.z, -max_target, max_target)

func _update_year() -> void:
	year_label.text = "Jahr %s" % _fmt(int(sim.currentYear()))

func _refresh_debug() -> void:
	_update_debug_ui()
	if debug_difference_enabled:
		_update_debug_difference_texture()
	debug_dirty = false
	debug_refresh_timer = 0.0

func _update_debug_ui() -> void:
	if debug_stats_label == null:
		return
	var stats: PackedFloat32Array = sim.debugTerrainStats()
	if stats.size() != DEBUG_STATS_COUNT:
		push_warning("Unerwartetes Diagnoseformat: %d statt %d Werte" % [stats.size(), DEBUG_STATS_COUNT])
		return
	debug_difference_scale = clampf(maxf(stats[DBG_MAX_REMOVED], stats[DBG_MAX_ADDED]), 0.005, 0.25)
	# Gratkrümmung ist die Alterungs-Kennzahl: stark negativ = junge spitze Grate,
	# gegen 0 = alt/rund (SimCore: Terrain.ridgeCurvature).
	debug_stats_label.text = (
		"Höhe  min %.3f  Ø %.3f  max %.3f\n" % [stats[DBG_MIN], stats[DBG_MEAN], stats[DBG_MAX]]
		+ "Relief %.3f (hoch %.3f / tal %.3f)  Δmax %+.3f  ΔØ %+.3f\n" % [
			stats[DBG_RELIEF], stats[DBG_RELIEF_SIGNAL], stats[DBG_RELIEF_LOW],
			stats[DBG_DELTA_MAX], stats[DBG_DELTA_MEAN]]
		+ "Gratkrümmung %+.3f\n" % stats[DBG_RIDGE_CURVATURE]
		+ "Unter/über Ref. %.1f / %.1f\n" % [
			stats[DBG_BELOW_REFERENCE_VOLUME], stats[DBG_ABOVE_REFERENCE_VOLUME]]
		+ "ΔVol %+.1f  ·  Ref. Jahr %s" % [stats[DBG_NET_VOLUME], _fmt(int(stats[DBG_REFERENCE_YEAR]))])
	debug_legend_label.text = "Blau −  Grau 0  Rot +   Skala ±%.3f" % debug_difference_scale
	if stats[DBG_INVALID] > 0:
		debug_warning_label.text = "⚠ %d ungültige Höhenwerte (Magenta)" % int(stats[DBG_INVALID])
		debug_warning_label.add_theme_color_override("font_color", Color(1.0, 0.25, 0.8))
	elif stats[DBG_SERVO] > stats[DBG_UPLIFT]:
		# Der Servo ist nur noch UNTERGRENZE: er übernimmt erst, wenn die
		# abklingende Hebung U(t) das Relief nicht mehr über dem Ziel hält.
		# Regelsignal ist p95 − Median der Landhöhen, nicht max − min.
		debug_warning_label.text = "⚠ Relief-Untergrenze aktiv: +%.5f / 100 J.\nReliefsignal hoch %.3f / tal %.3f / Ziel %.3f (Hebung U(t) %.5f)" % [
			stats[DBG_SERVO], stats[DBG_RELIEF_SIGNAL], stats[DBG_RELIEF_LOW],
			stats[DBG_RELIEF_TARGET], stats[DBG_UPLIFT]]
		debug_warning_label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.22))
	else:
		debug_warning_label.text = "Abklingende Hebung U(t) %.5f / 100 J. · Untergrenze inaktiv" % stats[DBG_UPLIFT]
		debug_warning_label.add_theme_color_override("font_color", Color(0.55, 0.82, 0.58))

func _fmt(v: int) -> String:
	var s := str(v)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "." + out
	return out

# ---------------------------------------------------------------- Felder

## Markiert die CPU-Höhen als veraltet. Gezogen werden sie erst, wenn ein
## Raycast sie braucht (`_sample_h`) — die Textur liest SimNode direkt.
func _invalidate_h_cache() -> void:
	h_cache_dirty = true

func _ensure_h_cache() -> void:
	if h_cache_dirty:
		h_cache = sim.heights()
		h_cache_dirty = false

# ---------------------------------------------------------------- Terrain-Textur

## Lädt Höhen (R32F) und Farben (RGBA8) als Texturen hoch — GPU macht Displacement
## und Färbung. Pro Tick nur ein Upload statt kompletter Mesh-Rebuild.
## Alle Puffer kommen als ROHE Bytes aus SimNode (Issue #53): `heights()` +
## `to_byte_array()` kostete je Update eine zusätzliche ~2,7-MB-Kopie.
func _update_terrain_textures(water_blend: float = 1.0, update_overlays: bool = true) -> void:
	height_field.upload(terrain_mat, N, sim.heightsBytes())
	terrain_mat.set_shader_parameter("detail_strength", terrain_detail_strength(sim.currentYear()))
	if not update_overlays:
		return

	# Seespiegel-Feld (hf): der Vertex-Shader hebt See-Zellen auf diese Höhe →
	# Seen liegen als horizontale Flächen im Becken statt den Hang anzumalen.
	hf_field.upload(terrain_mat, N, sim.filledBytes())

	# Höhenbänder (Issue #4) an den Shader durchreichen: die Vegetations-Grenzen
	# sind Perzentile der aktuellen Landhöhen und wandern mit der alternden
	# Landschaft — der Shader darf dafür keine eigenen absoluten Werte halten.
	var bands: PackedFloat32Array = sim.heightBands()
	if bands.size() >= 2:
		terrain_mat.set_shader_parameter("veg_alt_lo", bands[0])
		terrain_mat.set_shader_parameter("veg_alt_hi", bands[1])

	# Makrofarbe und Materialgewichte kommen aus EINER Swift-Auswertung; der
	# Material-Cache in SimRender.RenderState verhindert doppelte
	# slope-/Habitat-Arbeit (bis Issue #93 lag er in SimNode).
	color_field.upload(terrain_mat, N, sim.terrainColorBytes())
	surface_field.upload(terrain_mat, N, sim.terrainSurfaceBytes())
	# Wasser-Feld (Flüsse/Seen/Altarme) als glattes Overlay-Textur.
	# water_blend < 1 → zeitliche EWMA-Glättung (Läufe blenden statt zu springen).
	if water_gpu:
		_update_water_gpu(water_blend)
	else:
		water_field.upload(terrain_mat, N, sim.waterFieldBytes(water_blend))

## Alterungsabhängige Stärke der rein kosmetischen Shader-Rinnen. Smoothstep
## vermeidet einen sichtbaren Knick am Anfang und bei 100k; danach bleibt der
## alte Zustand stabil, statt immer kontrastreicher zu werden.
static func terrain_detail_strength(years: float) -> float:
	var age := clampf(years / TERRAIN_DETAIL_AGE_YEARS, 0.0, 1.0)
	age = age * age * (3.0 - 2.0 * age)
	return lerpf(TERRAIN_DETAIL_YOUNG, TERRAIN_DETAIL_OLD, age)

## Baut die GPU-Kette des Wasserfelds auf (s. `water_gpu`). Vier SubViewports in
## Baum-Reihenfolge: zwei Blur-Pässe, dann zwei Zustands-Targets fürs Ping-Pong
## der EWMA. Godot rendert SubViewports vor dem Hauptviewport; hängt ein Pass
## dennoch einen Frame zurück, konvergiert die Kette trotzdem — sie wird nur um
## Frames träger, nicht falsch.
func _setup_water_gpu() -> void:
	var blur_shader: Shader = load("res://shaders/water_field_blur.gdshader")
	var ewma_shader: Shader = load("res://shaders/water_field_ewma.gdshader")
	# Erst R und G glätten, dann nur noch G: der See-Kanal braucht zwei Pässe
	# (er muss den seichten Ufersaum überdecken), der Fluss-Kanal einen — genau
	# wie blurMax(sd, 1) und blurMax(lk, 2) auf der CPU.
	var masks := [Vector2(1.0, 1.0), Vector2(0.0, 1.0)]
	var upstream: Texture2D = null   # erster Pass liest die CPU-Rohtextur
	for pass_index in masks.size():
		var mat := ShaderMaterial.new()
		mat.shader = blur_shader
		mat.set_shader_parameter("blur_channels", masks[pass_index])
		if upstream != null:
			mat.set_shader_parameter("src", upstream)
		var vp := _make_field_viewport(true)
		vp.add_child(_make_field_rect(mat))
		add_child(vp)
		wf_blur_vp.append(vp)
		wf_blur_mat.append(mat)
		upstream = vp.get_texture()
	for _state_index in 2:
		var mat := ShaderMaterial.new()
		mat.shader = ewma_shader
		mat.set_shader_parameter("fresh", upstream)
		# CLEAR_MODE_NEVER: diese beiden Targets SIND das EWMA-Gedächtnis.
		var vp := _make_field_viewport(false)
		vp.add_child(_make_field_rect(mat))
		add_child(vp)
		wf_state_vp.append(vp)
		wf_ewma_mat.append(mat)

func _make_field_viewport(clear_each_pass: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(N, N)
	vp.disable_3d = true
	# Half-Float-Target: in 8 Bit bliebe die EWMA bei kleinem `blend` STEHEN, weil
	# das Inkrement bl*(ziel − zustand) unter 1/255 rundet (bei 0.15 schon ab
	# ~0.026 Abstand). Der Zustand braucht die Auflösung, die Eingabe nicht.
	vp.use_hdr_2d = true
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS if clear_each_pass 		else SubViewport.CLEAR_MODE_NEVER
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return vp

func _make_field_rect(mat: ShaderMaterial) -> ColorRect:
	var rect := ColorRect.new()
	rect.size = Vector2(N, N)
	rect.material = mat
	return rect

## Ein Durchlauf der GPU-Kette. `blend` hat dieselbe Bedeutung wie im CPU-Pfad:
## 1 = frischen Zustand sofort übernehmen (Sprung, Sculpting), klein = weich
## blenden im Zeitraffer.
func _update_water_gpu(blend: float) -> void:
	wf_raw_field.upload(wf_blur_mat[0], N, sim.waterFieldRawBytes())
	# Ping-Pong: aus dem aktuellen Zustand lesen, in das andere Target schreiben.
	# Dasselbe Target zu lesen und zu beschreiben ist undefiniert.
	var previous := wf_state_index
	wf_state_index = 1 - wf_state_index
	var mat := wf_ewma_mat[wf_state_index]
	mat.set_shader_parameter("state", wf_state_vp[previous].get_texture())
	# Erster Tick: es gibt kein Gedächtnis, sonst blendete das Feld aus Schwarz auf.
	mat.set_shader_parameter("blend", blend if wf_primed else 1.0)
	wf_primed = true
	# GENAU EIN Durchlauf je Textur-Update (nicht je Frame): sonst hinge die
	# Glättungsrate an der Bildrate. Das gelesene Zustands-Target bleibt dabei
	# bewusst auf UPDATE_DISABLED.
	for vp in wf_blur_vp:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	wf_state_vp[wf_state_index].render_target_update_mode = SubViewport.UPDATE_ONCE
	terrain_mat.set_shader_parameter("water_tex", wf_state_vp[wf_state_index].get_texture())

func _update_debug_difference_texture() -> void:
	debug_difference_field.upload(terrain_mat, N,
		sim.heightDifferenceBytes(debug_difference_scale))


# ---------------------------------------------------------------- Bäume (Stufe 1)

## Low-Poly-Baum je Variante als ArrayMesh: Stamm + Krone als getrennte
## Surfaces mit eigenem Material (kein Vertex-Color-Umweg). Größen sind in die
## Primitive gebacken (Transforms nur Translation → Normalen bleiben gültig).
func _tree_mesh(variant: int) -> ArrayMesh:
	var am := ArrayMesh.new()
	var trunk_mat := _tree_material(Color(0.32, 0.23, 0.15))
	match variant:
		0: # Laubbaum: kurzer Stamm + gestauchte Kugel-Krone
			var trunk := CylinderMesh.new()
			trunk.top_radius = 0.05
			trunk.bottom_radius = 0.09
			trunk.height = 0.6
			trunk.radial_segments = 5
			trunk.rings = 1
			_add_surface(am, trunk, Vector3(0, 0.3, 0), trunk_mat)
			var crown := SphereMesh.new()
			crown.radius = 0.52
			crown.height = 0.9
			crown.radial_segments = 7
			crown.rings = 4
			_add_surface(am, crown, Vector3(0, 0.95, 0), _tree_material(Color(0.20, 0.38, 0.14)))
		1: # Nadelbaum: Stamm + Kegel
			var trunk2 := CylinderMesh.new()
			trunk2.top_radius = 0.05
			trunk2.bottom_radius = 0.08
			trunk2.height = 0.45
			trunk2.radial_segments = 5
			trunk2.rings = 1
			_add_surface(am, trunk2, Vector3(0, 0.22, 0), trunk_mat)
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.4
			cone.height = 1.5
			cone.radial_segments = 6
			cone.rings = 1
			_add_surface(am, cone, Vector3(0, 1.1, 0), _tree_material(Color(0.12, 0.29, 0.15)))
		_: # Busch: flache Kugel, kein Stamm
			var bush := SphereMesh.new()
			bush.radius = 0.32
			bush.height = 0.42
			bush.radial_segments = 6
			bush.rings = 3
			_add_surface(am, bush, Vector3(0, 0.16, 0), _tree_material(Color(0.25, 0.40, 0.17)))
	return am

func _tree_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m

## Hängt die (nur verschobene) Surface 0 von `src` an `am` an.
func _add_surface(am: ArrayMesh, src: Mesh, offset: Vector3, mat: Material) -> void:
	var arr: Array = src.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for vi in verts.size():
		verts[vi] += offset
	arr[Mesh.ARRAY_VERTEX] = verts
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.surface_set_material(am.get_surface_count() - 1, mat)

## Rebuild-Heuristik: Bäume nur neu setzen, wenn sich das veg-Feld seit dem
## letzten Build merklich geändert hat (Max-Delta > 0.1) — nicht jeden Frame.
## Vor dem ersten Build liefert SimNode immer 1.0 → Initial-Build garantiert.
func _maybe_rebuild_trees() -> void:
	if sim.treeVegMaxDelta() > TREE_REBUILD_DELTA:
		_rebuild_trees()

func _rebuild_trees() -> void:
	if tree_coverage == TreeCoverage.NONE:
		return
	for v in tree_mmi.size():
		var buf: PackedFloat32Array = sim.treeInstanceBuffer(v, HSCALE, tree_coverage)
		var mm: MultiMesh = tree_mmi[v].multimesh
		mm.instance_count = buf.size() / 12
		if buf.size() > 0:
			mm.buffer = buf
	sim.markTreesBuilt()

## Fluss-Ribbons: Rebuild nur, wenn sich die Mäander-Zentrumslinien seit dem
## letzten Build bewegt haben (Dirty-Vertrag wie bei den Bäumen; Struktur-
## Änderungen wie Cutoffs melden ein Riesen-Delta → sofortiger Rebuild).
## Gemeinsamer 1-Hz-Deckel für Echtzeit UND `_jump`: der alte reine
## `_process`-Timer ließ jeden 2000-Jahre-Sprung-Chunk ein Mesh bauen. `force`
## gilt nur für diskrete Nutzeraktionen (Neu/Laden/Sculpt) und den Sprung-Endstand.
func _maybe_rebuild_rivers_throttled(force := false) -> void:
	if not river_ribbons:
		return
	var now := Time.get_ticks_msec()
	if not _river_rebuild_due(now, force):
		return
	if sim.riversMaxDelta() > RIVER_REBUILD_DELTA:
		_rebuild_rivers()
	last_river_rebuild_msec = now

func _river_rebuild_due(now_msec: int, force: bool) -> bool:
	return (force or last_river_rebuild_msec < 0
		or now_msec - last_river_rebuild_msec >= int(RIVER_REBUILD_SECONDS * 1000.0))

func _rebuild_rivers() -> void:
	sim.buildRiverRibbons(HSCALE, RIVER_LIFT)
	river_mesh.clear_surfaces()
	var verts: PackedVector3Array = sim.riverRibbonVerts()
	if verts.size() >= 3:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = sim.riverRibbonColors()
		arrays[Mesh.ARRAY_TEX_UV] = sim.riverRibbonUVs()
		# UV2.x = Typ (Fluss/Delta/Altarm, Issue #34) — der Shader färbt danach
		# und schaltet für Altarme die Strömung ab.
		arrays[Mesh.ARRAY_TEX_UV2] = sim.riverRibbonUV2s()
		arrays[Mesh.ARRAY_INDEX] = sim.riverRibbonIndices()
		river_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	sim.markRiversBuilt()

# ---------------------------------------------------------------- Kamera & Eingabe

func _update_camera() -> void:
	var cp := cos(cam_pitch)
	var offset := Vector3(sin(cam_yaw) * cp, sin(cam_pitch), cos(cam_yaw) * cp) * cam_dist
	cam.position = cam_target + offset
	cam.look_at(cam_target, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	last_activity_msec = Time.get_ticks_msec()
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				var was_sculpting := sculpting
				sculpting = event.pressed
				if not event.pressed:
					pick_last = Vector2.INF # Strich beendet → nächster Klick beginnt neu
					if was_sculpting:
						_finish_stroke()
				if event.pressed and TOOLS[current_tool].get("samples_target", false):
					# Einebnen: Zielhöhe = Terrainhöhe am Strich-Beginn
					var hit := _raycast_terrain()
					if hit != Vector3.INF:
						flatten_target = _sample_h((hit.x + half) / step, (hit.z + half) / step)
			MOUSE_BUTTON_RIGHT:
				orbiting = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				cam_dist = max(30.0, cam_dist - 8.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				cam_dist = min(world_size * 4.0, cam_dist + 8.0)
	elif event is InputEventMouseMotion and orbiting:
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clamp(cam_pitch + event.relative.y * 0.005, 0.15, 1.5)
	# Zoom ohne Maus: Trackpad-Zwei-Finger-Wisch …
	elif event is InputEventPanGesture:
		cam_dist = clamp(cam_dist + event.delta.y * 6.0, 30.0, world_size * 4.0)
	# … Pinch-Geste …
	elif event is InputEventMagnifyGesture:
		cam_dist = clamp(cam_dist / event.factor, 30.0, world_size * 4.0)
	# … und +/− auf der Tastatur.
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				cam_dist = max(30.0, cam_dist - 12.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				cam_dist = min(world_size * 4.0, cam_dist + 12.0)
			KEY_SPACE: # Pause ↔ letztes Tempo
				_set_rate(0.0 if year_rate > 0.0 else last_rate)
			KEY_BRACKETLEFT:
				radius_slider.value = max(radius_slider.min_value, brush_radius - 2.0)
			KEY_BRACKETRIGHT:
				radius_slider.value = min(radius_slider.max_value, brush_radius + 2.0)
			KEY_F5: # Welt speichern (Issue #8)
				_save_world()
			KEY_F9: # Welt laden
				_load_world()
			KEY_V:
				if not event.echo:
					_set_tree_coverage((tree_coverage + 1) % 3)
					tree_coverage_picker.select(tree_coverage)
			_:
				# Werkzeug-Tasten 1…N in Tabellen-Reihenfolge (Issue #53): ein
				# neues Werkzeug braucht hier keine eigene Zeile mehr.
				var t: int = event.keycode - KEY_1
				if t >= 0 and t < TOOLS.size():
					current_tool = t
					tool_buttons[t].set_pressed_no_signal(true)

## Auch von Controls konsumierte Ereignisse müssen den Renderer wecken. Nur in
## `_unhandled_input` käme etwa ein Klick auf „10 J/s" hier nie an, solange das
## letzte Pausebild eingefroren ist.
func _input(_event: InputEvent) -> void:
	_wake_render_loop()

## Fensterleisten-Aktionen — Maximieren, Wiederherstellen, Resize am Rand —
## erzeugen KEIN InputEvent. Ohne eigenen Weckruf bliebe das eingefrorene
## Pausebild danach skaliert im neuen Fenster stehen, ausgerechnet beim
## Maximieren fürs Messprozedere (s. AGENTS.md, Fenstergröße ist Teil des
## Tests). Größen- und Fokuswechsel wecken den Renderloop deshalb selbst.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_wake_render_loop()

func _wake_render_loop() -> void:
	last_activity_msec = Time.get_ticks_msec()
	if render_loop_suspended:
		render_loop_suspended = false
		RenderingServer.render_loop_enabled = true

func _update_ring() -> void:
	if OS.has_environment("RS_SHOT"): # autonome Screenshots: kein Pinsel-Ring
		ring_mi.visible = false
		return
	if sculpting or year_rate == 0.0:
		var hit := _raycast_terrain()
		if hit != Vector3.INF:
			ring_mi.visible = true
			ring_mi.position = hit + Vector3(0, 0.4, 0)
			# Spitzhacke: Ring zeigt die echte (gedeckelte) Hieb-Breite.
			var r := minf(brush_radius, pick_radius_cap) \
				if TOOLS[current_tool].get("radius_capped", false) else brush_radius
			ring_mi.scale = Vector3(r, 1.0, r)
			return
	ring_mi.visible = false

## Heightfield-Raymarch (three.js-Dreieckstest wäre bei 128² zu teuer).
func _raycast_terrain() -> Vector3:
	var mpos := get_viewport().get_mouse_position()
	var ro := cam.project_ray_origin(mpos)
	var rd := cam.project_ray_normal(mpos)
	var prev_t := 0.0
	var t := 0.8
	while t < world_size * 6.0:
		var p := ro + rd * t
		var gx := (p.x + half) / step
		var gz := (p.z + half) / step
		if gx >= 0 and gx <= N - 1 and gz >= 0 and gz <= N - 1 and p.y <= _sample_h(gx, gz) * HSCALE:
			var lo := prev_t
			var hi := t
			for b in 12:
				var mid := (lo + hi) * 0.5
				var m := ro + rd * mid
				if m.y <= _sample_h((m.x + half) / step, (m.z + half) / step) * HSCALE:
					hi = mid
				else:
					lo = mid
			return ro + rd * hi
		prev_t = t
		t += 0.8
	return Vector3.INF

func _sample_h(gx: float, gz: float) -> float:
	_ensure_h_cache()
	var xi := clampi(int(floor(gx)), 0, N - 2)
	var yi := clampi(int(floor(gz)), 0, N - 2)
	var fx := clampf(gx - xi, 0.0, 1.0)
	var fy := clampf(gz - yi, 0.0, 1.0)
	var i00 := yi * N + xi
	return h_cache[i00] * (1 - fx) * (1 - fy) + h_cache[i00 + 1] * fx * (1 - fy) \
		+ h_cache[i00 + N] * (1 - fx) * fy + h_cache[i00 + N + 1] * fx * fy
