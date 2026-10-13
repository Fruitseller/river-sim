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
const Lighting = preload("res://scripts/Lighting.gd")
# Render-Gitter der billigsten Stufe; `balanced` und `quality` zeigen seit #153
# das volle Sim-Gitter (`terrain_grid_for`).
const PERFORMANCE_TERRAIN_GRID := 256
# Back-Auflösung der Render-Verschiebung in Vielfachen des Sim-Gitters: die
# Pixel-Stufe liest Steigung und Rinnen aus der doppelt so feinen Textur, damit
# ihr Detail nicht an der Mesh-Dichte hängt (Flusstal-Studie #116).
const RELIEF_BAKE_FACTOR := 2

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
var pick_radius_cap := 0.5 # effektive Spitzhacken-Breite (aus SimNode, für die Pinselkuppel)

var terrain_mi: MeshInstance3D
var water_mi: MeshInstance3D
# Pinselkuppel (s. BRUSH_FALLOFF_POWER): Linien-Mesh, nur bei Änderung neu
# gebaut (`brush_key`: Treffer, Radius, Profil, Flächen-Stand).
var brush_mi: MeshInstance3D
var brush_mesh := ArrayMesh.new()
var brush_key := []
# Zählt jede Änderung der sichtbaren Fläche (Höhe, Verschiebung, Kronendach).
var surface_version := 0

# Wasser-Geometrie (Issues #31/#34): Mäander, Delta-Distributäre und Altarme als
# Band-Geometrie aus SimNode.buildRiverRibbons statt Textur-Stempel. Seit #34 der
# STANDARD; `RS_WATER_STAMP` schaltet für den A/B-Vergleich auf den alten
# Raster-Stempel-Pfad zurück (ohne Rebuild, SimNode liest dieselbe Variable).
# Wann neu gebaut wird (Dirty-Vertrag, 1-Hz-Deckel), entscheidet RenderState.frame.
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

# Auslöser eines Render-Frames (Issue #94) == SimRender.FrameTrigger. WAS ein
# Frame liefert, in welcher Reihenfolge (Bänder vor dem Wasserfeld) und wie es
# gedrosselt wird (Overlays 0,30 s, Bänder 1 Hz, Wasser-Blend 0.15, Rebuild-
# Schwellen), steht in RenderState.frame; hier wird nur hochgeladen.
const FRAME_SETTLED := 0     # Start, Neu, Laden, Sprung-Ende, Strich-Ende
const FRAME_JUMP_CHUNK := 1  # ein Chunk eines Zeitsprungs
const FRAME_TIMELAPSE := 2   # ein Zeitraffer-Takt
const FRAME_STROKE := 3      # Nachzug während eines Pinselstrichs
# Welt-Y über Gelände (die Bänder baut RenderState.frame mit RenderContract.riverLift;
# die Godot-Wächter lesen den Wert hier): deckt den Chord-Fehler des gröberen Render-Gitters im
# Talgrund (384er-Gitter auf 832er-Feld). Seit #153 hat nur noch `performance`
# ein gröberes Gitter (256 auf 720); der Wert ist dafür nicht neu kalibriert.
# == RenderContract.riverLift (SimCore);
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
##
## `keeps_previous` (#172): vor jedem Upload wandert der alte Stand nach
## `<param>_prev`, über den der Terrain-Shader im Zeitraffer hinüberblendet
## (s. `Crossfade`).
class FieldTexture:
	var _param: StringName
	var _prev_param: StringName
	var _format: int
	var _img: Image
	var _tex: ImageTexture
	var _prev_tex: ImageTexture
	var _mirror_mat: ShaderMaterial

	func _init(param: StringName, format: int, keeps_previous := false) -> void:
		_param = param
		_format = format
		if keeps_previous:
			_prev_param = StringName(String(param).replace("_tex", "_prev_tex"))

	## Bindet denselben GPU-Texturzustand an einen zweiten Shader. Die Höhenkarte
	## schneidet damit auch die Ozeanplatte ab, ohne einen zweiten Image-Upload.
	func mirror_to(mat: ShaderMaterial) -> void:
		_mirror_mat = mat
		if _tex != null:
			_bind(_mirror_mat)

	func upload(mat: ShaderMaterial, n: int, bytes: PackedByteArray) -> void:
		if _img == null:
			_img = Image.create_from_data(n, n, false, _format, bytes)
			_tex = ImageTexture.create_from_image(_img)
			if _prev_param != &"":
				_prev_tex = ImageTexture.create_from_image(_img)
			_bind(mat)
			if _mirror_mat != null:
				_bind(_mirror_mat)
		elif _prev_tex != null:
			# Der neue Stand bekommt ein EIGENES Image: der alte bleibt damit
			# unverändert, auch wenn der Renderer die Bytes erst später liest
			# (separater Render-Thread).
			_prev_tex.update(_img)
			_img = Image.create_from_data(n, n, false, _format, bytes)
			_tex.update(_img)
		else:
			_img.set_data(n, n, false, _format, bytes)
			_tex.update(_img)

	func _bind(mat: ShaderMaterial) -> void:
		mat.set_shader_parameter(_param, _tex)
		if _prev_tex != null:
			mat.set_shader_parameter(_prev_param, _prev_tex)

## Überblende vom Vorgängerstand zum neuen (#172), als Shader-Parameter
## (`height_blend`, `overlay_blend`). JEDE Blende gehört zu GENAU einem
## Upload-Takt: eine geteilte Blende über zwei Takte ließ den Wald an jedem
## Takt ohne neue Maske zurückspringen (#170). Jeder Upload startet neu und
## dauert so lange wie der Abstand zum vorigen: bei gleichmäßigem Takt
## gleitet die Fläche damit ohne Halt von Stand zu Stand, statt erst zu
## springen und dann zu stehen. Ohne `fade` (Pinsel, Sprung, Laden) gilt der
## neue Stand sofort.
class Crossfade:
	const MIN_SECONDS := 0.1
	const MAX_SECONDS := 0.6  # nach einer Pause nicht ewig blenden
	var _param: StringName
	var _mats: Array[ShaderMaterial] = []
	var mix := 1.0
	var seconds := MAX_SECONDS
	var _last := -1.0

	func _init(param: StringName) -> void:
		_param = param

	func bind(mat: ShaderMaterial) -> void:
		_mats.append(mat)
		mat.set_shader_parameter(_param, mix)

	func start(now: float, fade: bool) -> void:
		if fade and _last >= 0.0:
			seconds = clampf(now - _last, MIN_SECONDS, MAX_SECONDS)
		_last = now
		_apply(0.0 if fade else 1.0)

	func advance(delta: float) -> void:
		if mix < 1.0:
			_apply(minf(mix + delta / seconds, 1.0))

	func _apply(value: float) -> void:
		mix = value
		for mat in _mats:
			mat.set_shader_parameter(_param, mix)

var height_field := FieldTexture.new("height_tex", Image.FORMAT_RF, true)
# gefüllte Oberfläche (Seespiegel) → echte horizontale Seeflächen
var hf_field := FieldTexture.new("hf_tex", Image.FORMAT_RF, true)
var color_field := FieldTexture.new("color_tex", Image.FORMAT_RGBA8, true)
var surface_field := FieldTexture.new("surface_tex", Image.FORMAT_RGBA8, true)
# Bodenbedeckung (#174 D): Schutthalde, Gletschereis, Rohboden, Talboden.
var cover_field := FieldTexture.new("cover_tex", Image.FORMAT_RGBA8, true)
var water_field := FieldTexture.new("water_tex", Image.FORMAT_RGBA8)
# Abfluss-Dichte fürs Shader-Detail: bündelt die kosmetischen Erosionsrinnen in
# echten Abflussbahnen statt als uniformes Muster (WaterRender.flowDetailIntensity).
var flow_field := FieldTexture.new("flow_tex", Image.FORMAT_R8, true)
# Zeitraffer-Überblenden (#172): die Höhe im Sim-Takt, alles Gedrosselte
# (Farbe, Material, Rinnen-Detail, Seespiegel, Wald) im Overlay-Takt.
var height_fade := Crossfade.new(&"height_blend")
# Auslöser des Frames, der gerade hochlädt (s. `_timelapse_fading`).
var _frame_trigger := FRAME_SETTLED
var overlay_fade := Crossfade.new(&"overlay_blend")

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

# Render-Verschiebung von Rinnen und Graten (#153): ein Float-SubViewport backt
# sie einmal je Terrain-Update (`_bake_relief`), der Terrain-Shader liest nur.
# Pinselkuppel und Kameraziel liegen auf der SICHTBAREN Fläche; dafür liest
# `_relief_cpu` die Backtextur zurück, lazy und nie während eines Strichs (der
# Rückweg ist ein GPU-Sync, gemessen 22 ms bei n = 720, M4 Max).
# `relief_lift_cache` ist der kodierte Höhenzuschlag auf dem Sim-Gitter
# (Dekodierung in `_surface_y`), leer = keine Verschiebung bekannt.
# Zwei Back-Ziele im Wechsel: im Zeitraffer blendet der Terrain-Shader über
# einen Sim-Takt vom alten zum neuen Stand (`relief_mix`), statt viermal je
# Sekunde zu springen; sonst (Pinsel, Sprung, Laden) gilt der neue sofort.
var relief_vps: Array[SubViewport] = []
var relief_vp: SubViewport  # das Ziel mit dem neuesten Stand
var relief_mix := 1.0
var relief_mat: ShaderMaterial
var relief_height_code := 0.0
var relief_geometry_age := 0.0  # Sim-Jahre bis zur vollen Verformung
var relief_lift_cache: PackedFloat32Array
var relief_bake_frame := -1  # Frame des noch nicht zurückgelesenen Auftrags
var relief_bakes := 0  # Zähler für den Wächter: nur Terrain-Updates backen
# Kameraziel auf die sichtbare Fläche nachziehen, sobald die erste
# Verschiebung zurückgelesen ist (RS_TARGET).
var cam_target_on_surface := false
# Schutzmaske (#154): endet die Verschiebung an Wasser.
var protect_tex: ImageTexture
# Kronendach (#152): Waldmaske aus SimRender (R8). `forest_lift_cache` ist die
# Maske als Float auf dem Sim-Gitter für den Raycast, lazy aus `forest_img`
# (leer = veraltet).
var forest_tex: ImageTexture
var forest_prev_tex: ImageTexture
var forest_img: Image
# Quellen der Sedimentfahnen (#174 C): RF mit Mip-Kette, nur am Ozean-Material.
var plume_tex: ImageTexture
var forest_lift_cache: PackedFloat32Array
var canopy_calib := {}
# Wolkenkörper (#174 D, Lighting.make_cloud_bodies) und alle Materialien mit
# Wolkenschatten oder -körper.
var cloud_bodies: Node3D
var cloud_mats: Array[ShaderMaterial] = []

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
var hud: Control
var rate_label: Label
var seed_label: Label
var pause_button: Button
var play_button: Button
var tool_buttons: Array[Button] = []
var debug_panel: Control
var camera_tween: Tween
var rs_camera := -1 # RS_CAMERA: Preset-Index, folgt der Fenstergröße bis zur ersten Eingabe
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
## Pflichtfeld neben `name` und `mode`:
##   icon            — Name des gezeichneten Icons (scripts/UiIcon.gd, #174)
## Optionale Felder, jedes ersetzt eine vorher verstreute Magie-Zahl:
##   shift           — Werkzeug, auf das Shift umschaltet (Anheben ↔ Absenken)
##   samples_target  — braucht die Geländehöhe am Strich-Beginn (Einebnen)
##   stroke_spacing  — zeichnet EINZELHIEBE entlang des Strichs, Abstand in Zellen
##                     (Spitzhacke: auf der Stelle verharren gräbt nicht tiefer)
##   strength_factor — Faktor auf die Pinselstärke (Spitzhacke schlägt kräftiger)
##   radius_capped   — echte Breite ist auf `pick_radius_cap` gedeckelt (Kuppel)
##   falloff_power   — Exponent p des Pinselgewichts (1 − d²)^p für die Kuppel,
##                     Standard BRUSH_FALLOFF_POWER (s. dort)
## Neues Werkzeug = eine Zeile hier plus ein `case` in BrushTool.
const TOOLS := [
	{"icon": "raise", "name": "Anheben", "mode": 0, "shift": 1},
	{"icon": "lower", "name": "Absenken", "mode": 1, "shift": 0},
	{"icon": "smooth", "name": "Glätten", "mode": 2},
	{"icon": "flatten", "name": "Einebnen", "mode": 3, "samples_target": true},
	{"icon": "roughen", "name": "Aufrauen", "mode": 4},
	{"icon": "pickaxe", "name": "Spitzhacke", "mode": 5, "stroke_spacing": 1.5,
		"strength_factor": 1.5, "radius_capped": true, "falloff_power": 4},
]
## Zeitraffer-Stufen in Jahren je Sekunde. ▶ spielt die zuletzt gewählte,
## ⏩ schaltet reihum eine weiter (nach der schnellsten wieder die langsamste).
const SPEEDS := [10.0, 30.0, 60.0]
const JUMPS := [["+100 J.", 100.0], ["+1.000 J.", 1000.0],
	["+10.000 J.", 10000.0], ["+100.000 J.", 100000.0]]

## Kamera-Presets der Vorlagen (Issue #174, Paket E), Tasten F1–F3 in
## Tabellen-Reihenfolge: Diorama = ganze Insel schräg (Vorlage C), Tal = Blick
## über die Aue bis zum Horizont (B), Nah = Schrägsicht auf Hang, Fluss und
## Küste (A). Die Tasten-Presets sind ADAPTIV, einmal beim Drücken für die
## laufende Welt gerechnet (`camera_preset_view`):
##  - Diorama (`fill`): Landzellen mittig im Bild, in der knapperen Richtung
##    bis `fill` (`frame_land`, aus FOV und Seitenverhältnis); Yaw bleibt.
##  - Tal und Nah (`upstream`): Ziel = Zelle des größten Laufs, `upstream`
##    Welteinheiten oberhalb seiner Küstenmündung, Kamera auf der Meerseite
##    der Mündung mit Blick talaufwärts (`river_view`). Das Ziel ist damit
##    immer eine Landzelle, nie das offene Meer. Verdeckt Gelände die
##    Sichtlinie (Talbiegung, Kamera im Hang), steigt der Pitch, bis sie frei
##    ist (`_clear_pitch`).
## Pitch (alle) und Distanz (Tal, Nah) sind dieselben wie bei den
## Matrix-Kameras gleicher `id`; die Matrix (scripts/graphics-matrix.sh) hält
## dagegen feste Ziele und Distanzen je Seed, damit Abnahmebilder
## reproduzierbar bleiben (Wächter:
## GraphicsMatrixTests.testCameraPresetsMatchTheMatrix).
const CAMERA_PRESETS := [
	{"id": "diorama", "name": "Diorama", "fill": 0.85, "pitch": 0.62},
	{"id": "valley", "name": "Tal", "dist": 30.0, "pitch": 0.40, "upstream": 12.0},
	{"id": "close", "name": "Nah", "dist": 22.0, "pitch": 0.52, "upstream": 4.0},
]
const CAMERA_PRESET_SECONDS := 0.6
## Kleinster Kamera-Abstand (Zoom und Presets). Bis #174 standen hier 30
## Einheiten als Zahl an jeder Zoom-Stelle; „Tal" und „Nah" (Vorlagen B, A)
## brauchen näher heran: aus 60 zeigte „Tal" die ganze Insel, das Tal war klein.
const CAM_DIST_MIN := 20.0

## Pinsel als Gitterkuppel (#174, Paket E) statt des flachen Rings: die Kuppel
## ist die sichtbare Fläche (Sim-Höhe plus Verschiebung #153 plus Kronendach),
## angehoben um das Gewichtsprofil des Pinsels w(d) = (1 − d²)^p, d = Abstand
## zum Zentrum / Radius. p = 2 ist das Gewicht ALLER Werkzeuge
## (Terrain.forEachBrushCell), die Spitzhacke quadriert es (p = 4,
## Terrain.pickaxe, Feld `falloff_power`). Wächter:
## ToolContractTests.testBrushDomeFollowsTheBrushFalloff (Profil gegen die
## gemessene Wirkung von Anheben und Spitzhacke).
const BRUSH_FALLOFF_POWER := 2.0
const BRUSH_DOME_HEIGHT := 0.5   # Scheitelhöhe relativ zum Radius, rein visuell
const BRUSH_DOME_LIFT := 0.08    # Abstand über der Fläche gegen Z-Fighting
const BRUSH_DOME_RINGS := 5      # Breitenkreise, der äußerste ist der Rand
const BRUSH_DOME_MERIDIANS := 12
## Segmente je Breitenkreis. 96 statt 48: der Rand liegt auf der Fläche, und
## eine Sehne über 2πr/48 tauchte bei r = 10 alle ~8 Zellen ins Gelände.
const BRUSH_DOME_SEGMENTS := 96
## Aussehen (shaders/brush_dome.gdshaderinc): Linien als Bänder in logischen
## Bildschirm-Pixeln, heller Kern in der Akzentfarbe des Glas-Themes, dunkler
## Halo je Seite. Der Rand trägt, das Gitter zeigt nur die Wölbung.
const BRUSH_RIM_COLOR := Color(0.85, 0.97, 1.0, 1.0)
const BRUSH_RIM_WIDTH_PX := 3.0
const BRUSH_RIM_HALO_PX := 1.5
const BRUSH_GRID_COLOR := Color(0.78, 0.94, 1.0, 0.6)
const BRUSH_GRID_WIDTH_PX := 1.5
const BRUSH_GRID_HALO_PX := 0.75

## Gemeinsames Glas-Theme aller Bedienelemente (#174): Farben, Rahmen,
## Schriftgrößen und die Typ-Varianten (`TitleLabel`, `ToolButton`, …) stehen
## dort, nicht als Overrides im Code (Wächter: SimCoreTests/UiContractTests).
const UI_THEME := "res://ui/glass_theme.tres"
const UiIcon = preload("res://scripts/UiIcon.gd")
const UI_MARGIN := 16.0

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
	var requested_grid := terrain_grid_for(render_quality, N)
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
	# Pinselkuppel im Screenshot (RS_BRUSH=<Radius>, Welteinheiten wie der
	# Regler): steht dann in der Bildmitte, auch unter RS_SHOT.
	if OS.has_environment("RS_BRUSH"):
		brush_radius = float(OS.get_environment("RS_BRUSH"))
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
		cam_target.y = _surface_y_at(cam_target)
		cam_target_on_surface = true
		_update_camera()
	_update_year()
	_render_frame(FRAME_SETTLED)
	if OS.has_environment("RS_CAMERA"): # Tasten-Preset per id, für Screenshots
		var id := OS.get_environment("RS_CAMERA")
		for c in CAMERA_PRESETS.size():
			if CAMERA_PRESETS[c]["id"] == id:
				rs_camera = c
		if rs_camera >= 0:
			_apply_camera_preset(rs_camera, false)
			# Das Diorama rahmt nach dem Seitenverhältnis. Auf dem Referenz-Mac
			# hat das Fenster mit `--maximized` schon in _ready die Endgröße
			# (gemessen 3456×2104); greift das Maximieren auf einer anderen
			# Plattform später, folgt das Preset bis zur ersten Eingabe jeder
			# Größenänderung. RS_SHOT zeigt so dasselbe wie F1–F3.
			get_viewport().size_changed.connect(func():
				if rs_camera >= 0:
					_apply_camera_preset(rs_camera, false))
	_refresh_debug()
	if OS.has_environment("RS_DIAG"):
		_diag()

## Render-Gitter je Qualitätsstufe (#153). Erst das Sim-Gitter trägt die
## Silhouette der Render-Verschiebung; ein doppelt so dichtes Gitter kostete in
## der Studie doppelt so viel ohne sichtbaren Gewinn (die Dreiecke liegen in der
## Übersicht unter einem Pixel), Normalen und Rinnen kommen ohnehin aus der
## feineren Backtextur. Messreihe: docs/graphics-quality.md, Abschnitt #153.
static func terrain_grid_for(quality: String, n: int) -> int:
	return PERFORMANCE_TERRAIN_GRID if quality == "performance" else n

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
		_render_frame(FRAME_SETTLED)
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


## Kalibrierung der Render-Verschiebung über die Brücke (#153): Name → Wert aus
## SimCore.ReliefRender. Statisch, damit game/tests/relief.gd sie headless prüft.
static func relief_calibration(sim_node: Object) -> Dictionary:
	var names: PackedStringArray = sim_node.reliefUniformNames()
	var values: PackedFloat32Array = sim_node.reliefUniformValues()
	var calib := {}
	for i in names.size():
		calib[names[i]] = values[i]
	return calib

## Back-Pass der Render-Verschiebung (#153): ein Float-SubViewport in
## RELIEF_BAKE_FACTOR-facher Sim-Auflösung, der nur nach einem Terrain-Update
## einmal zeichnet (UPDATE_ONCE, `_bake_relief`).
func _setup_relief() -> void:
	var calib := relief_calibration(sim)
	relief_height_code = calib["relief_height_code"]
	relief_geometry_age = calib["relief_geometry_age"]
	var size := N * RELIEF_BAKE_FACTOR
	relief_mat = ShaderMaterial.new()
	relief_mat.shader = load("res://shaders/relief_bake.gdshader")
	relief_mat.set_shader_parameter("grid_n", float(N))
	relief_mat.set_shader_parameter("hscale", HSCALE)
	relief_mat.set_shader_parameter("sea_level", sea)
	for mat in [relief_mat, terrain_mat]:
		for name in calib:
			mat.set_shader_parameter(name, calib[name])
	for i in 2:
		var vp := SubViewport.new()
		vp.size = Vector2i(size, size)
		vp.use_hdr_2d = true
		# Transparent, sonst verwirft der Viewport den Alpha-Kanal (Rinnen/Rippen).
		vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var rect := ColorRect.new()
		rect.size = Vector2(size, size)
		rect.material = relief_mat
		vp.add_child(rect)
		add_child(vp)
		relief_vps.append(vp)
	relief_vp = relief_vps[0]
	terrain_mat.set_shader_parameter("relief_tex", relief_vp.get_texture())
	terrain_mat.set_shader_parameter("relief_prev_tex", relief_vp.get_texture())
	terrain_mat.set_shader_parameter("bake_blend", 1.0)
	terrain_mat.set_shader_parameter("relief_enabled", true)

## Kalibrierung des Kronendachs über die Brücke (#152): Name → Wert aus
## SimCore.CanopyRender. Statisch, damit game/tests/canopy.gd sie headless prüft.
static func canopy_calibration(sim_node: Object) -> Dictionary:
	var names: PackedStringArray = sim_node.canopyUniformNames()
	var values: PackedFloat32Array = sim_node.canopyUniformValues()
	var calib := {}
	for i in names.size():
		calib[names[i]] = values[i]
	return calib

## Kronendach (#152): Kalibrierung aufs Terrain-Material, die Waldmaske kommt
## mit jedem Overlay-Frame (`_update_forest_mask`).
func _setup_canopy() -> void:
	canopy_calib = canopy_calibration(sim)
	for name in canopy_calib:
		terrain_mat.set_shader_parameter(name, canopy_calib[name])
	terrain_mat.set_shader_parameter("canopy_enabled", true)

## Material-Kalibrierung über die Brücke (#174 D): Name → Wert aus
## SimCore.MaterialRender. Statisch, damit game/tests/canopy.gd sie headless
## prüft. Die Gewichte kommen mit jedem Overlay-Frame (`cover`, `surface`).
static func material_calibration(sim_node: Object) -> Dictionary:
	var names: PackedStringArray = sim_node.materialUniformNames()
	var values: PackedFloat32Array = sim_node.materialUniformValues()
	var calib := {}
	for i in names.size():
		calib[names[i]] = values[i]
	return calib

func _setup_scene() -> void:
	# Licht und Atmosphäre (#151): feste Welt-Sonne, Werte und Qualitätsstufen
	# stehen in Lighting.gd.
	var env := WorldEnvironment.new()
	env.environment = Lighting.make_environment(render_quality, sea * HSCALE)
	add_child(env)

	var sun := DirectionalLight3D.new()
	add_child(sun)
	Lighting.configure_sun(sun, render_quality)

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
	_setup_relief()
	_setup_canopy()
	var material_calib := material_calibration(sim)
	for name in material_calib:
		terrain_mat.set_shader_parameter(name, material_calib[name])

	if OS.has_environment("RS_WATER_GPU"):
		water_gpu = true
	if water_gpu:
		_setup_water_gpu()
	sim.setDeferWaterTail(water_gpu)

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
	height_fade.bind(terrain_mat)
	height_fade.bind(ocean_mat)
	overlay_fade.bind(terrain_mat)
	water_mi.material_override = ocean_mat
	water_mi.position.y = sea * HSCALE
	add_child(water_mi)

	# Wasser-Geometrie (außer im RS_WATER_STAMP-Modus): EIN MeshInstance3D, dessen
	# ArrayMesh _upload_ribbon_mesh aus den SimNode-Puffern füllt.
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
	# Wolkenkörper über dem Kamm (#174 D) teilen Rauschen und Basis mit den
	# Wolkenschatten; `cloud_mats` sind alle Materialien, die beides lesen.
	cloud_bodies = Lighting.make_cloud_bodies(render_quality, world_size, HSCALE)
	add_child(cloud_bodies)
	cloud_mats.assign(water_mats)
	cloud_mats.append_array(Lighting.cloud_body_materials(cloud_bodies))
	Lighting.apply_clouds(cloud_mats, render_quality)

	# Pinselkuppel: Bildschirm-Bänder (s. brush_dome.gdshaderinc). Erst der
	# verdeckte Teil gedämpft ohne Tiefentest, darüber der sichtbare. Die
	# Priorität legt beide hinter alle übrigen transparenten Flächen (Wasser,
	# Meer, Wolken), sonst überdeckten die den gedämpften Teil.
	brush_mi = MeshInstance3D.new()
	brush_mi.mesh = brush_mesh
	var bmat := ShaderMaterial.new()
	bmat.shader = load("res://shaders/brush_dome_hidden.gdshader")
	var bmat_visible := ShaderMaterial.new()
	bmat_visible.shader = load("res://shaders/brush_dome.gdshader")
	bmat.next_pass = bmat_visible
	for m: ShaderMaterial in [bmat, bmat_visible]:
		m.render_priority = Material.RENDER_PRIORITY_MAX
		m.set_shader_parameter("px_scale", DisplayServer.screen_get_scale())
	brush_mi.material_override = bmat
	brush_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	brush_mi.visible = false
	add_child(brush_mi)

## Bedienung nach Vorlage B/C (Issue #174, Paket E): vier Ecken auf einer
## Vollbild-Ebene, die selbst keine Maus fängt (Klicks daneben formen das
## Gelände). Oben links Titel, Jahr und Tempo, darunter die Werkzeugpalette;
## oben rechts die Zeitsprünge; unten rechts Diagnose, Welt und Kamera; unten
## Mitte die Tastenhilfe. Aussehen nur über das Theme (UI_THEME).
func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	# Autonome Screenshots (RS_SHOT) zeigen die LANDSCHAFT: die Bedienleiste
	# verdeckt sonst die halbe linke Bildhälfte, und genau dort liegen in der
	# A/B-Serie die Mündungen. Die Diagnosewerte stehen ohnehin im Log.
	# RS_SHOT_UI behält sie für Aufnahmen der Bedienung selbst.
	layer.visible = not OS.has_environment("RS_SHOT") or OS.has_environment("RS_SHOT_UI")
	add_child(layer)
	var ui_theme: Theme = load(UI_THEME)
	hud = Control.new()
	hud.theme = ui_theme
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(hud)

	# --- oben links: Titel, Jahr, Tempo; darunter die Werkzeugpalette
	var top_left := _corner(Control.PRESET_TOP_LEFT)
	var head := _panel(top_left)
	_label(head, "river-sim", &"TitleLabel")
	year_label = _label(head, "", &"YearLabel")
	rate_label = _label(head, "", &"RateLabel")
	var transport := HBoxContainer.new()
	head.add_child(transport)
	pause_button = _icon_button(transport, "pause", "Pause (Leertaste)", true)
	pause_button.pressed.connect(func(): _set_rate(0.0))
	play_button = _icon_button(transport, "play", "Abspielen (Leertaste)", true)
	play_button.pressed.connect(func(): _set_rate(last_rate))
	var faster := _icon_button(transport, "faster",
		"Schneller: %s J./Sek. reihum" % " → ".join(SPEEDS.map(func(r): return str(int(r)))), false)
	faster.pressed.connect(_faster)

	var tools := _panel(top_left)
	_label(tools, "GELÄNDE FORMEN", &"SectionLabel")
	var tool_group := ButtonGroup.new()
	for t in TOOLS.size():
		var b := _mk_button(TOOLS[t]["name"], true, tool_group)
		b.theme_type_variation = &"ToolButton"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "Taste %d" % (t + 1)
		b.pressed.connect(func(): current_tool = t)
		var icon := UiIcon.new(TOOLS[t]["icon"])
		icon.set_anchors_preset(Control.PRESET_CENTER_LEFT)
		icon.position = Vector2(11, -15)
		icon.size = Vector2(30, 30)
		b.add_child(icon)
		tools.add_child(b)
		tool_buttons.append(b)
	tool_buttons[0].set_pressed_no_signal(true)
	tools.add_child(HSeparator.new())
	radius_slider = _mk_slider(tools, "Radius", 3.0, 30.0, 1.0, brush_radius,
		func(v: float): brush_radius = v)
	radius_value = _slider_value_label
	_mk_slider(tools, "Stärke", 0.25, 3.0, 0.05, brush_strength,
		func(v: float): brush_strength = v)
	strength_value = _slider_value_label
	_refresh_slider_labels()

	# --- oben rechts: Zeitsprung-Leiste
	var jumps := _panel(_corner(Control.PRESET_TOP_RIGHT))
	_label(jumps, "ZEITSPRUNG", &"SectionLabel")
	var jump_row := HBoxContainer.new()
	jumps.add_child(jump_row)
	for pair in JUMPS:
		var yrs: float = pair[1]
		var b := _mk_button(pair[0], false, null)
		b.pressed.connect(func(): _jump(yrs))
		jump_row.add_child(b)

	# --- unten rechts: Diagnose (aufklappbar), Welt, Kamera, Seed
	var bottom_right := _corner(Control.PRESET_BOTTOM_RIGHT)
	var debug_vb := _panel(bottom_right)
	debug_panel = debug_vb.get_parent()
	debug_panel.visible = false
	_label(debug_vb, "DIAGNOSE", &"SectionLabel")
	debug_stats_label = _label(debug_vb, "", &"StatsLabel")
	debug_warning_label = _label(debug_vb, "", &"OkLabel")
	debug_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_warning_label.custom_minimum_size = Vector2(380, 0)
	var debug_buttons := HBoxContainer.new()
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
	debug_legend_label = _label(debug_vb, "", &"StatsLabel")
	debug_legend_label.visible = false

	var world := _panel(bottom_right)
	world.custom_minimum_size = Vector2(320, 0)
	var debug_toggle := _mk_button("Diagnose-Ansicht", true, null)
	debug_toggle.tooltip_text = "Kennzahlen, Δ-Karte und Referenzpunkt ein- und ausblenden"
	debug_toggle.toggled.connect(func(on: bool): debug_panel.visible = on)
	world.add_child(debug_toggle)
	var world_io := HBoxContainer.new()
	world.add_child(world_io)
	var save_b := _mk_button("Welt speichern", false, null)
	save_b.tooltip_text = "Welt nach %s schreiben (F5)" % SAVE_PATH
	save_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_b.pressed.connect(_save_world)
	world_io.add_child(save_b)
	var load_b := _mk_button("Laden", false, null)
	load_b.tooltip_text = "Gespeicherte Welt zurückholen (F9)"
	load_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_b.pressed.connect(_load_world)
	world_io.add_child(load_b)
	var regen_b := _mk_button("Neue Insel", false, null)
	regen_b.tooltip_text = "Neue Welt aus dem nächsten Seed erzeugen"
	regen_b.pressed.connect(_regen)
	world.add_child(regen_b)
	_label(world, "KAMERA", &"SectionLabel")
	var cams := HBoxContainer.new()
	world.add_child(cams)
	for c in CAMERA_PRESETS.size():
		var b := _mk_button(CAMERA_PRESETS[c]["name"], false, null)
		b.tooltip_text = "F%d" % (c + 1)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _apply_camera_preset(c))
		cams.add_child(b)
	world_status_label = _label(world, "", &"StatusLabel")
	world_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	world_status_label.visible = false
	seed_label = _label(world, "", &"SectionLabel")
	seed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_update_seed()

	# --- unten Mitte: Tastenhilfe, ohne Panel. Schmal umbrochen, damit sie
	# auch im kleinen Standardfenster (1152 × 648) zwischen Werkzeugpalette und
	# Welt-Karte passt.
	var hint := _label(_corner(Control.PRESET_CENTER_BOTTOM),
		"Links: formen (Shift kehrt um) · Rechts: drehen · WASD: bewegen · +/−: Zoom · "
		+ "1–6: Werkzeug · [ ]: Radius · Leertaste: Pause · F1–F3: Kamera · "
		+ "F5/F9: Speichern/Laden", &"HintLabel")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.custom_minimum_size = Vector2(400, 0)

	# Fehlerdialog: Speichern/Laden kann echt scheitern (alte Formatversion,
	# beschädigte oder fremde Datei, volle Platte). Die Meldung kommt wörtlich aus
	# SimCore (`SnapshotError`) — kein zweiter Text, der auseinanderlaufen kann.
	world_dialog = AcceptDialog.new()
	world_dialog.title = "Welt"
	world_dialog.dialog_autowrap = true
	world_dialog.theme = ui_theme
	layer.add_child(world_dialog)
	_set_rate(year_rate)

# --- UI-Helfer -------------------------------------------------------------

var _slider_value_label: Label # letzte von _mk_slider erzeugte Wertanzeige

## Spalte an einem Bildschirmrand (Ecke oder unten Mitte), UI_MARGIN vom Rand.
## Sie wächst vom Rand weg und schrumpft wieder, wenn ein Teil ausgeblendet
## wird (`_fit_corner`); sonst bliebe nach dem Zuklappen der Diagnose ein
## leerer Streifen stehen.
func _corner(preset: int) -> VBoxContainer:
	var c := VBoxContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_anchors_preset(preset)
	var right := preset == Control.PRESET_TOP_RIGHT or preset == Control.PRESET_BOTTOM_RIGHT
	var center := preset == Control.PRESET_CENTER_BOTTOM
	var bottom := center or preset == Control.PRESET_BOTTOM_LEFT \
		or preset == Control.PRESET_BOTTOM_RIGHT
	if center:
		c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	else:
		c.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN if bottom else Control.GROW_DIRECTION_END
	if bottom:
		c.alignment = BoxContainer.ALIGNMENT_END
	var ox := 0.0 if center else (-UI_MARGIN if right else UI_MARGIN)
	var oy := -UI_MARGIN if bottom else UI_MARGIN
	c.offset_left = ox
	c.offset_right = ox
	c.offset_top = oy
	c.offset_bottom = oy
	hud.add_child(c)
	c.minimum_size_changed.connect(_fit_corner.bind(c))
	return c

## Hält die Ecken-Spalte genau so groß wie ihren Inhalt, an der Ecke verankert.
func _fit_corner(c: Control) -> void:
	var m := c.get_combined_minimum_size()
	if c.grow_horizontal == Control.GROW_DIRECTION_BOTH:
		c.offset_left = -m.x * 0.5
		c.offset_right = m.x * 0.5
	elif c.grow_horizontal == Control.GROW_DIRECTION_BEGIN:
		c.offset_left = c.offset_right - m.x
	else:
		c.offset_right = c.offset_left + m.x
	if c.grow_vertical == Control.GROW_DIRECTION_BEGIN:
		c.offset_top = c.offset_bottom - m.y
	else:
		c.offset_bottom = c.offset_top + m.y

## Glas-Panel (Stil aus dem Theme) mit senkrechter Spalte; gibt die Spalte zurück.
func _panel(parent: Control) -> VBoxContainer:
	var panel := PanelContainer.new()
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	return vb

## Statuszeile der Welt-Karte; leer belegt sie keinen Platz.
func _set_status(text: String) -> void:
	world_status_label.text = text
	world_status_label.visible = not text.is_empty()

func _label(parent: Control, text: String, variation: StringName) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

## Knopf mit gezeichnetem Icon statt Text (Tempo-Leiste).
func _icon_button(parent: Control, icon_id: String, tip: String, toggle: bool) -> Button:
	var b := _mk_button("", toggle, null)
	b.custom_minimum_size = Vector2(46, 40)
	b.tooltip_text = tip
	var icon := UiIcon.new(icon_id)
	icon.set_anchors_preset(Control.PRESET_CENTER)
	icon.position = Vector2(-11, -11)
	icon.size = Vector2(22, 22)
	b.add_child(icon)
	parent.add_child(b)
	return b

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
	parent.add_child(row)
	var name_l := _label(row, title, &"")
	name_l.custom_minimum_size = Vector2(88, 0)
	var s := HSlider.new()
	s.custom_minimum_size = Vector2(150, 0)
	s.min_value = minv
	s.max_value = maxv
	s.step = stepv
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var val_l := _label(row, "", &"")
	val_l.custom_minimum_size = Vector2(52, 0)
	val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
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
	if pause_button == null:
		return
	pause_button.set_pressed_no_signal(rate == 0.0)
	play_button.set_pressed_no_signal(rate > 0.0)
	if rate > 0.0:
		rate_label.text = "ZEITRAFFER (%s J./Sek.)" % _fmt(int(rate))
	else:
		rate_label.text = "PAUSE (weiter mit %s J./Sek.)" % _fmt(int(last_rate))

## ⏩: nächste Zeitraffer-Stufe (SPEEDS), nach der schnellsten wieder die
## langsamste. Aus der Pause heraus zählt das zuletzt gespielte Tempo.
func _faster() -> void:
	var from := year_rate if year_rate > 0.0 else last_rate
	var i := SPEEDS.find(from)
	_set_rate(SPEEDS[(i + 1) % SPEEDS.size()])

## Kamera-Preset aus CAMERA_PRESETS anfahren (F1–F3 oder Knopf). Weich über
## CAMERA_PRESET_SECONDS, `animate = false` springt (Tests, RS_CAMERA).
func _apply_camera_preset(index: int, animate := true) -> void:
	var v := camera_preset_view(index)
	# Yaw über den kürzeren Bogen anfahren, nicht einmal um die Insel herum.
	var yaw: float = cam_yaw + wrapf(v["yaw"] - cam_yaw, -PI, PI)
	if camera_tween != null:
		camera_tween.kill()
		camera_tween = null
	if not animate:
		cam_dist = v["dist"]
		cam_pitch = v["pitch"]
		cam_yaw = yaw
		cam_target = v["target"]
		_update_camera()
		return
	camera_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE) \
		.set_ease(Tween.EASE_IN_OUT)
	camera_tween.tween_property(self, "cam_dist", v["dist"], CAMERA_PRESET_SECONDS)
	camera_tween.tween_property(self, "cam_pitch", v["pitch"], CAMERA_PRESET_SECONDS)
	camera_tween.tween_property(self, "cam_yaw", yaw, CAMERA_PRESET_SECONDS)
	camera_tween.tween_property(self, "cam_target", v["target"], CAMERA_PRESET_SECONDS)

## Ansicht eines Presets für die laufende Welt: {target, dist, pitch, yaw}.
## Ohne Land (Diorama) bzw. ohne Lauf (Tal, Nah) bleiben Blickpunkt und Yaw.
func camera_preset_view(index: int) -> Dictionary:
	var p: Dictionary = CAMERA_PRESETS[index]
	_ensure_h_cache()
	var target := Vector3(cam_target.x, 0.0, cam_target.z)
	var view := {"dist": p.get("dist", cam_dist), "pitch": p["pitch"], "yaw": cam_yaw}
	if p.has("fill"):
		var vp := get_viewport().get_visible_rect().size
		var f := frame_land(h_cache, N, sea, world_size, cam_yaw, p["pitch"], cam.fov,
			vp.x / maxf(vp.y, 1.0), p["fill"])
		if not f.is_empty():
			# Drehpunkt auf die Fläche in der Bildmitte legen; Auge, Blickrichtung
			# und Rahmen bleiben. Orbit und Zoom wirken dann auf das, was man sieht.
			var cp := cos(float(p["pitch"]))
			var back := Vector3(sin(cam_yaw) * cp, sin(float(p["pitch"])), cos(cam_yaw) * cp)
			var eye: Vector3 = f["target"] + back * float(f["dist"])
			var hit := _raycast_surface(eye, -back)
			view["target"] = f["target"] if hit == Vector3.INF else hit
			view["dist"] = clampf(eye.distance_to(view["target"]), CAM_DIST_MIN, world_size * 4.0)
			return view
	else:
		var r := river_view(h_cache, sim.flowArea(), sim.receivers(), N, sea, world_size,
			p["upstream"])
		if not r.is_empty():
			target = r["target"]
			view["yaw"] = r["yaw"]
	target.y = _surface_y_at(target)
	view["target"] = target
	view["pitch"] = _clear_pitch(target, view["yaw"], view["pitch"], view["dist"])
	return view

## Kleinster Pitch ab `pitch` (Schritte 0,05, höchstens 1,3), bei dem Auge und
## Sichtlinie zum Ziel frei sind (`sight_block`). Ohne Hindernis bleibt
## `pitch` unverändert.
func _clear_pitch(target: Vector3, yaw: float, pitch: float, dist: float) -> float:
	while pitch < 1.3 and sight_block(target, yaw, pitch, dist) >= 0.0:
		pitch += 0.05
	return pitch

## Erster verdeckter Anteil t der Sichtlinie Ziel → Auge (−1 = frei), 24
## Proben ab t = 0,25: die nahe Umgebung des Ziels (Ufer, Kronendach am
## Fluss) ist das, worauf die Kamera blickt, kein Hindernis davor. Luft über
## der sichtbaren Fläche wächst bis 1 Einheit am Auge. Außerhalb des Gitters
## liegt nur das Meer (sonst zöge die Rand-Klemme von `_sample_grid` das
## Randgelände endlos weiter).
func sight_block(target: Vector3, yaw: float, pitch: float, dist: float) -> float:
	var cp := cos(pitch)
	var eye := target + Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp) * dist
	for s in range(6, 25):
		var t := s / 24.0
		var p := target.lerp(eye, t)
		var ground := sea * HSCALE if maxf(absf(p.x), absf(p.z)) > half \
			else _surface_y_at(p)
		if p.y < ground + t:
			return t
	return -1.0

## Diorama-Rahmen: Kamera mit Blickrichtung `yaw`/`pitch`, die die Landzellen
## (Raster `n/180`) MITTIG zeigt und in der knapperen Bildrichtung genau bis
## `fill` füllt. Bis zum Folgebefund zu #176 stand das Ziel auf der Mitte der
## Land-Box: in Schrägsicht projiziert die nahe Kante größer als die ferne,
## die Insel saß unten und füllte nur ~60 % der Höhe (unten 0,84, oben 0,38).
## Rechnung je Bildrichtung in der Ebene (Querachse, Rückachse b), Punkte als
## (x, y) = (p·u, p·b) bzw. (p·r, p·b), Auge (c, D), Kegel-Steigung k: ein
## Punkt liegt in der Kante, wenn ±(x − c) ≤ k·(D − y), d. h. a±(k) =
## max(±x + k·y) ≤ ±c + k·D. Beide Kanten knapp: D(k) = (a+ + a−)/(2k),
## c(k) = (a+ − a−)/2. Die Richtung mit dem größeren D(k_voll) begrenzt; die
## andere sucht per Bisektion das k mit D(k) = D und ist damit ebenfalls
## mittig. a± laufen nur über die konvexe Hülle (`Geometry2D.convex_hull`).
## k_voll = fill·tan(fov/2) (vertikal, Godot KEEP_HEIGHT), horizontal mal
## `aspect`. Ziel (Orbit-Drehpunkt) ist der Punkt der Bildachse in der Tiefe
## der Inselmitte, `dist` sein Abstand zum Auge. Leer ohne Land.
static func frame_land(h: PackedFloat32Array, n: int, sea_level: float, world: float,
		yaw: float, pitch: float, fov_deg: float, aspect: float, fill: float) -> Dictionary:
	var cell := world / float(n - 1)
	var stride := maxi(1, n / 180)
	var cp := cos(pitch)
	var back := Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp)
	var right := Vector3.UP.cross(back).normalized()
	var up := back.cross(right)
	var pu := PackedVector2Array()
	var pr := PackedVector2Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var y_sum := 0.0
	for j in range(0, n, stride):
		for i in range(0, n, stride):
			var y := h[j * n + i]
			if y <= sea_level:
				continue
			var p := Vector3(i * cell - world * 0.5, y * HSCALE, j * cell - world * 0.5)
			pu.append(Vector2(p.dot(up), p.dot(back)))
			pr.append(Vector2(p.dot(right), p.dot(back)))
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.z))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.z))
			y_sum += p.y
	if pu.is_empty():
		return {}
	var hull_u := Geometry2D.convex_hull(pu)
	var hull_r := Geometry2D.convex_hull(pr)
	var k_v := tan(deg_to_rad(fov_deg) * 0.5) * fill
	var k_h := k_v * aspect
	var fit_u := _edge_fit(hull_u, k_v)
	var fit_r := _edge_fit(hull_r, k_h)
	var depth := maxf(fit_u.y, fit_r.y)
	if fit_u.y < depth:
		fit_u = _edge_fit_at(hull_u, depth, k_v)
	else:
		fit_r = _edge_fit_at(hull_r, depth, k_h)
	var eye: Vector3 = up * fit_u.x + right * fit_r.x + back * depth
	var center := Vector3((lo.x + hi.x) * 0.5, y_sum / pu.size(), (lo.y + hi.y) * 0.5)
	var dist := (eye - center).dot(back)
	return {"target": eye - back * dist, "dist": dist, "land_box": Rect2(lo, hi - lo)}

## (c, D) der knappen Kanten mit Steigung k für Punkte (x, y), s. frame_land.
static func _edge_fit(pts: PackedVector2Array, k: float) -> Vector2:
	var a_pos := -INF
	var a_neg := -INF
	for q in pts:
		a_pos = maxf(a_pos, q.x + k * q.y)
		a_neg = maxf(a_neg, -q.x + k * q.y)
	return Vector2((a_pos - a_neg) * 0.5, (a_pos + a_neg) / (2.0 * k))

## (c, D) mit vorgegebener Tiefe D ≥ D(k_max): Bisektion über k, D(k) fällt in k.
static func _edge_fit_at(pts: PackedVector2Array, depth: float, k_max: float) -> Vector2:
	var k_lo := 0.0
	var k_hi := k_max
	for _i in 40:
		var k := (k_lo + k_hi) * 0.5
		if _edge_fit(pts, k).y > depth:
			k_lo = k
		else:
			k_hi = k
	return Vector2(_edge_fit(pts, k_hi).x, depth)

## Größter Lauf für Tal und Nah, auf dem D8-Netz (`flowArea`/`receivers`):
## Landzelle mit dem größten Einzugsgebiet, abwärts bis zur letzten Landzelle
## (Mündung; an der Küste oder, ohne Randabstand, am Kartenrand), von dort je Schritt zum Zufluss mit dem größten Einzugsgebiet,
## bis `upstream` Welteinheiten gelaufen sind oder die Quelle erreicht ist.
## Yaw stellt die Kamera auf die Mündungsseite (Blick talaufwärts). Ziel und
## Mündung sind Landzellen (h > Meeresspiegel). Leer ohne Land.
static func river_view(h: PackedFloat32Array, area: PackedFloat32Array,
		receivers: PackedInt32Array, n: int, sea_level: float, world: float,
		upstream: float) -> Dictionary:
	var mouth := -1
	var best := -1.0
	for k in h.size():
		if area[k] > best and h[k] > sea_level:
			best = area[k]
			mouth = k
	if mouth < 0:
		return {}
	for _guard in h.size():
		var r := receivers[mouth]
		if r < 0 or h[r] <= sea_level:
			break
		mouth = r
	var cell := world / float(n - 1)
	var cur := mouth
	var walked := 0.0
	while walked < upstream:
		var ci := cur % n
		var cj := cur / n
		var next := -1
		var next_area := -1.0
		for dj in range(-1, 2):
			for di in range(-1, 2):
				var i := ci + di
				var j := cj + dj
				if (di == 0 and dj == 0) or i < 0 or j < 0 or i >= n or j >= n:
					continue
				var k := j * n + i
				if receivers[k] == cur and h[k] > sea_level and area[k] > next_area:
					next_area = area[k]
					next = k
		if next < 0:
			break
		walked += cell * (1.0 if (next % n == ci or next / n == cj) else sqrt(2.0))
		cur = next
	var at := func(k: int) -> Vector2:
		return Vector2((k % n) * cell - world * 0.5, (k / n) * cell - world * 0.5)
	var target: Vector2 = at.call(cur)
	var seaward: Vector2 = at.call(mouth) - target
	if seaward.length() < cell: # Lauf zu kurz: von der Kartenmitte nach außen
		seaward = at.call(mouth)
	return {"target": Vector3(target.x, 0.0, target.y), "yaw": atan2(seaward.x, seaward.y),
		"mouth": mouth, "cell": cur}

## Seed der laufenden Welt. Eine geladene Welt trägt ihren Seed nicht über die
## Brücke; die Anzeige sagt dann das, statt den alten Seed stehen zu lassen.
func _update_seed(loaded := false) -> void:
	seed_label.text = "SEED: geladene Welt" if loaded else "SEED: %s" % _fmt(sim_seed)

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
		_after_sim(FRAME_JUMP_CHUNK)
		await get_tree().process_frame
	# Der Band-Deckel darf den sichtbaren Endzustand nicht bis zum nächsten
	# Zeitraffer-Tick verzögern (der Sprung endet typischerweise pausiert).
	_after_sim(FRAME_SETTLED)
	_jumping = false

func _regen() -> void:
	sim_seed = (sim_seed * 16807 + 1) % 2147483647
	sim.generate(sim_seed)
	sim.recomputeFlow()
	_after_sim(FRAME_SETTLED)
	_update_seed()

# ------------------------------------------------- Speichern / Laden (Issue #8)

## Schreibt die laufende Welt. SimNode arbeitet auf BETRIEBSSYSTEM-Pfaden (SimCore
## kennt Godots `user://` nicht), deshalb `globalize_path`.
func _save_world() -> void:
	if _jumping: # mitten in einem Zeitsprung ist der Zustand noch in Bewegung
		_set_status("Zeitsprung läuft — später speichern")
		return
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	var err: String = sim.saveWorld(abs_path)
	if not err.is_empty():
		_show_world_error("Speichern fehlgeschlagen", err)
		return
	var mb := float(sim.lastWorldFileBytes()) / (1024.0 * 1024.0)
	_set_status("Gespeichert: Jahr %s · %.1f MB" % [
		_fmt(int(sim.currentYear())), mb])

## Holt die gespeicherte Welt zurück. Danach ist der Zustand vollständig (der
## Seespiegel kommt aus der Datei und schwingt NICHT ein, Issue #8) — es genügt,
## die Texturen neu zu ziehen; ein Sim-Schritt ist ausdrücklich nicht nötig.
## `path` überschreiben nur Tests, damit sie den Spielstand nicht antasten.
func _load_world(path: String = SAVE_PATH) -> void:
	if _jumping: # der laufende Sprung würde sofort auf die geladene Welt steppen
		_set_status("Zeitsprung läuft — später laden")
		return
	if not FileAccess.file_exists(path):
		_show_world_error("Kein Spielstand",
			"Unter %s liegt noch keine Welt. Erst speichern (F5)." % path)
		return
	var abs_path := ProjectSettings.globalize_path(path)
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
	_after_sim(FRAME_SETTLED) # Wasser-Blend 1.0 → kein Überblenden aus der alten Welt
	_refresh_debug()
	_set_status("Geladen: Jahr %s · pausiert" % _fmt(int(sim.currentYear())))
	_update_seed(true)

## Passt die GEOMETRIE einer Welt-Datei zu dieser Sitzung? Rückgabe: leerer
## String = ja, sonst der Grund als fertige Meldung.
##
## Diese Sitzung ist in `_ready` auf EINE Geometrie festgelegt: Höhen-/Farb-/
## Wasser-Texturen und `h_cache` haben N × N Einträge, Mesh-Größe und
## -Tessellation, Kamera-Distanz, Wasserebene, Pinselkuppel und die
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
	_set_status(title)
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

func _after_sim(trigger: int) -> void:
	_invalidate_h_cache()
	_update_year()
	_render_frame(trigger)
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
	if relief_mix < 1.0:
		relief_mix = minf(relief_mix + delta / SIM_TICK_SECONDS, 1.0)
		terrain_mat.set_shader_parameter("bake_blend", relief_mix)
	height_fade.advance(delta)
	overlay_fade.advance(delta)
	if terrain_mat:
		terrain_mat.set_shader_parameter("u_time", u_time)
	if ocean_mat:
		ocean_mat.set_shader_parameter("u_time", u_time)
	if river_mat:
		river_mat.set_shader_parameter("u_time", u_time)
	for mat in Lighting.cloud_body_materials(cloud_bodies):
		mat.set_shader_parameter("u_time", u_time)
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
			rebuild_timer = 0.0
			# Jahre/Schritt deckeln → hält jeden Schritt billig (keine Todesspirale).
			var years := minf(pending_years, 240.0)
			pending_years = 0.0
			sim.step(years)
			_invalidate_h_cache()
			_update_year()
			debug_dirty = true
			# Höhe jeden Takt; Overlays gedrosselt und das Wasser weich
			# geblendet (kein Springen zwischen den diskreten D8-Netzen) —
			# Werte und Begründung in RenderState.
			_render_frame(FRAME_TIMELAPSE)

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
			_upload_heights()
			_bake_relief()
			sculpt_refresh_timer += delta
			# Nachzug auf ZWEI Frames verteilt. GEMESSEN je Aufruf (n = 832,
			# M4 Max, Aug 2026, res://tests/sculpt_cost.gd):
			#   Teil 1  recomputeFlow        34,6 ms
			#   Teil 2  waterFieldBytes      14,4 ms
			#           terrainColor/Surface  0,9 ms je, filled-/heightsBytes 0,15
			#           buildRiverRibbons    11,6 ms — aber höchstens 1×/s,
			#                                s. RenderState.ribbonRebuildSeconds
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
	if cam_target_on_surface:
		_relief_cpu()
		if not relief_lift_cache.is_empty():
			# RS_TARGET: das Ziel lag bisher auf der Sim-Fläche.
			cam_target_on_surface = false
			cam_target.y = _surface_y_at(cam_target)
	_update_brush()
	_update_camera()

## Teil 1 des Nachzugs (teuer, ~35 ms): das Flussnetz reagiert auf den Eingriff.
func _refresh_stroke_flow() -> void:
	sim.recomputeFlow()
	_invalidate_h_cache()

## Teil 2 des Nachzugs (~17 ms): Bänder nachziehen (Sculpting droppt gestörte
## Kanäle → Struktur-Delta), Overlays hochladen.
func _refresh_stroke_upload() -> void:
	_render_frame(FRAME_STROKE)

## Strich beendet: einmal vollständig nachziehen (Flussnetz, Bänder, Overlays,
## Bäume) in einem Zug, damit der fertige Eingriff nie mit einem halb alten
## Flussnetz stehen bleibt (der gedrosselte Takt kann mitten im Intervall
## aufgehört haben).
func _finish_stroke() -> void:
	sculpt_refresh_timer = 0.0
	sculpt_refresh_pending = false  # der vollständige Nachzug erledigt Teil 2 mit
	_refresh_stroke_flow()
	_render_frame(FRAME_SETTLED)
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
	year_label.text = "JAHR %s" % _fmt(int(sim.currentYear()))

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
		debug_warning_label.theme_type_variation = &"AlertLabel"
	elif stats[DBG_SERVO] > stats[DBG_UPLIFT]:
		# Der Servo ist nur noch UNTERGRENZE: er übernimmt erst, wenn die
		# abklingende Hebung U(t) das Relief nicht mehr über dem Ziel hält.
		# Regelsignal ist p95 − Median der Landhöhen, nicht max − min.
		debug_warning_label.text = "⚠ Relief-Untergrenze aktiv: +%.5f / 100 J.\nReliefsignal hoch %.3f / tal %.3f / Ziel %.3f (Hebung U(t) %.5f)" % [
			stats[DBG_SERVO], stats[DBG_RELIEF_SIGNAL], stats[DBG_RELIEF_LOW],
			stats[DBG_RELIEF_TARGET], stats[DBG_UPLIFT]]
		debug_warning_label.theme_type_variation = &"WarnLabel"
	else:
		debug_warning_label.text = "Abklingende Hebung U(t) %.5f / 100 J. · Untergrenze inaktiv" % stats[DBG_UPLIFT]
		debug_warning_label.theme_type_variation = &"OkLabel"

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
	surface_version += 1

func _ensure_h_cache() -> void:
	if h_cache_dirty:
		h_cache = sim.heights()
		h_cache_dirty = false

# ---------------------------------------------------------------- Terrain-Textur

## Ein Render-Frame (Issue #94): Höhe hochladen, die Puffer des Frames aus
## RenderState.frame holen und hochladen, Verschiebung neu backen. WAS der Frame
## liefert und in welcher Reihenfolge es entsteht, entscheidet SimRender.
func _render_frame(trigger: int) -> void:
	_frame_trigger = trigger
	_upload_heights()
	_apply_frame(sim.renderFrame(trigger, _now()))
	_bake_relief()
	_frame_trigger = FRAME_SETTLED

## Uhr der Frame-Drosseln (Sekunden, monoton).
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## Lädt hoch, was ein Frame mitbringt; fehlende Schlüssel = unverändert.
func _apply_frame(frame: Dictionary) -> void:
	if frame.has("ribbons"):
		_upload_ribbon_mesh()
	if frame.has("water"):
		_upload_overlays(frame)

## Höhen (R32F) hochladen — billig (~0,2 ms), läuft auch jeden Pinsel-Frame.
## Alle Puffer kommen als ROHE Bytes aus SimNode (Issue #53): `heights()` +
## `to_byte_array()` kostete je Update eine zusätzliche ~2,7-MB-Kopie.
func _upload_heights() -> void:
	height_fade.start(_now(), _timelapse_fading())
	height_field.upload(terrain_mat, N, sim.heightsBytes())
	# Die Wolkenkörper erscheinen nur über dem Kamm und lesen dafür die Höhe.
	for mat in Lighting.cloud_body_materials(cloud_bodies):
		mat.set_shader_parameter("height_tex", height_field._tex)
	terrain_mat.set_shader_parameter("detail_strength", terrain_detail_strength(sim.currentYear()))
	terrain_mat.set_shader_parameter("sim_year", sim.currentYear())

## Im Zeitraffer gleiten die Texturen von Stand zu Stand (#172); Pinsel,
## Sprung, Laden und Neugenerieren zeigen den neuen Stand sofort. Geblendet
## wird nur ein Zeitraffer-TAKT (`_frame_trigger`), nicht schon ein laufender
## Zeitraffer: Neugenerieren pausiert ihn nicht, und die neue Welt glitt sonst
## aus der alten herein.
func _timelapse_fading() -> bool:
	return _frame_trigger == FRAME_TIMELAPSE and year_rate > 0.0 \
		and not sculpting and not _jumping

## Alles außer der Höhe: im Zeitraffer gedrosselt (RenderState.frame).
func _upload_overlays(frame: Dictionary) -> void:
	overlay_fade.start(_now(), _timelapse_fading())
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
	if bands.size() >= 8:
		# Nadelbaum-Anteil des Kronendachs (#152, HeightBands.coniferShare).
		terrain_mat.set_shader_parameter("conifer_lo", bands[6])
		terrain_mat.set_shader_parameter("conifer_hi", bands[7])
		# Wolkenbasis knapp über dem Kamm (#174 D): rockStart/rockFull.
		Lighting.place_clouds(cloud_mats, bands[2] * HSCALE, bands[3] * HSCALE, cloud_bodies)

	# Makrofarbe und Materialgewichte kommen aus EINER Swift-Auswertung.
	color_field.upload(terrain_mat, N, frame["color"])
	surface_field.upload(terrain_mat, N, frame["surface"])
	cover_field.upload(terrain_mat, N, frame["cover"])
	flow_field.upload(terrain_mat, N, frame["flow"])
	# Wasser-Feld (Flüsse/Seen/Altarme): im Zeitraffer zeitlich geglättet
	# (`water_blend` < 1), sonst der frische Stand.
	if water_gpu:
		_update_water_gpu(frame["water"], frame["water_blend"])
	else:
		water_field.upload(terrain_mat, N, frame["water"])
	# Schutz- und Waldmaske gehören zusammen: der Wald endet an der Schutzmaske
	# desselben Frames (in SimRender fallen beide gemeinsam, `dropMasks`).
	_update_protect_mask(frame["protect"])
	_update_forest_mask(frame["forest"])
	_update_plume(frame["plume"])

## Schutzmaske (#154): godot-freie Render-Ableitung aus SimRender
## (sichtbares Rasterwasser + gebaute Flussbänder + Saum von
## `WaterRender.protectSeamCells` Zellen), binär als R8. Entsteht im Frame NACH
## Bändern und Wasser; hier nur Kopieren und Hochladen.
func _update_protect_mask(bytes: PackedByteArray) -> void:
	var img := _protect_mask(bytes)
	if protect_tex == null:
		protect_tex = ImageTexture.create_from_image(img)
	else:
		protect_tex.update(img)

func _protect_mask(bytes: PackedByteArray) -> Image:
	return Image.create_from_data(N, N, false, Image.FORMAT_R8, bytes)

## Sedimentfahnen (#174 C): EINE Zelle je Mündung aus SimRender.SedimentPlume.
## Die Mip-Kette ist die Weichzeichnung: ocean.gdshader liest die Quelle auf
## gröberen Stufen und rechnet deren Mittelung zurück. Ohne Überblende — die
## Quellen wandern mit den Mündungen nur zellweise, die Weichzeichnung glättet.
func _update_plume(bytes: PackedByteArray) -> void:
	if ocean_mat == null:
		return
	var img := Image.create_from_data(N, N, false, Image.FORMAT_RF, bytes)
	img.generate_mipmaps()
	if plume_tex == null:
		plume_tex = ImageTexture.create_from_image(img)
		ocean_mat.set_shader_parameter("plume_tex", plume_tex)
	else:
		plume_tex.update(img)

## Waldmaske des Kronendachs (#152): SimRender.ForestCanopyMask aus
## Materialgewichten, Steigung und Schutzmaske, kommt mit dem Frame.
## Hier nur Hochladen; den Raycast-Zuschlag rechnet `_forest_lift_at` lazy.
## Der alte Stand wandert nach `forest_prev_tex`: im Zeitraffer blendet der
## Terrain-Shader mit der Overlay-Blende (`overlay_fade`, #172) hinüber, wie
## Farbe und Material. NICHT mit `bake_blend`: die Verschiebung backt jeden
## Sim-Takt, die Maske kommt nur mit den Overlays; geteilt sprang der Wald an
## jedem Takt ohne neue Maske auf den alten Stand zurück (#170).
func _update_forest_mask(bytes: PackedByteArray) -> void:
	var previous := forest_img
	forest_img = Image.create_from_data(N, N, false, Image.FORMAT_R8, bytes)
	forest_lift_cache = PackedFloat32Array()
	surface_version += 1
	if forest_tex == null:
		forest_tex = ImageTexture.create_from_image(forest_img)
		forest_prev_tex = ImageTexture.create_from_image(forest_img)
		terrain_mat.set_shader_parameter("forest_tex", forest_tex)
		terrain_mat.set_shader_parameter("forest_prev_tex", forest_prev_tex)
		return
	forest_prev_tex.update(previous)
	forest_tex.update(forest_img)

## Render-Verschiebung neu backen (#153), einmal je Terrain-Update: der
## Back-Pass zeichnet genau einen Frame, danach steht die Textur bis zum
## nächsten Update. Kein Update, kein Back-Pass — der Zeitraffer bleibt damit
## ruhig, und das Standbild kostet nur das Lesen der Textur.
## Im Zeitraffer backt das andere Ziel, und der Terrain-Shader blendet über
## einen Sim-Takt hinüber. Kommt mitten in der Blende ein zweiter Auftrag
## (Band-Bau im selben Takt), backt das neue Ziel erneut, und die Blende läuft
## weiter, statt zurück auf den alten Stand zu springen.
func _bake_relief() -> void:
	if relief_vp == null or height_field._tex == null or protect_tex == null:
		return
	relief_mat.set_shader_parameter("height_tex", height_field._tex)
	relief_mat.set_shader_parameter("protect_tex", protect_tex)
	var fade := _timelapse_fading()
	if relief_mix >= 1.0 or not fade:
		terrain_mat.set_shader_parameter("relief_prev_tex", relief_vp.get_texture())
		relief_vp = relief_vps[1] if relief_vp == relief_vps[0] else relief_vps[0]
		terrain_mat.set_shader_parameter("relief_tex", relief_vp.get_texture())
		relief_mix = 0.0 if fade else 1.0
		terrain_mat.set_shader_parameter("bake_blend", relief_mix)
	relief_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	relief_bake_frame = Engine.get_frames_drawn()
	relief_bakes += 1

## Holt den Höhenzuschlag der zuletzt gebackenen Verschiebung auf die CPU,
## verkleinert aufs Sim-Gitter (gleiche Indizierung wie `h_cache`). Lesbar erst
## NACH dem gezeichneten Back-Frame. Während eines Strichs backt jeder Frame
## neu; dort bleibt der Stand vom Strich-Beginn stehen (die Sim-Höhe darunter
## ist immer aktuell), gelesen wird erst nach dem Loslassen. Im Zeitraffer
## braucht niemand die Fläche, also wird auch nichts gelesen. Headless
## (Dummy-Renderer) bleibt der Puffer leer; die sichtbare Fläche ist dann die
## Sim-Fläche.
func _relief_cpu() -> void:
	if sculpting or relief_bake_frame < 0 or Engine.get_frames_drawn() <= relief_bake_frame:
		return
	relief_bake_frame = -1
	var img := relief_vp.get_texture().get_image()
	if img == null or img.is_empty():
		return
	img.convert(Image.FORMAT_RF)
	img.resize(N, N, Image.INTERPOLATE_BILINEAR)
	# Kodiert (Kanal = Höhe × Code + 0.5), dekodiert wird in `_surface_y`.
	relief_lift_cache = img.get_data().to_float32_array()
	surface_version += 1

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
func _update_water_gpu(raw: PackedByteArray, blend: float) -> void:
	wf_raw_field.upload(wf_blur_mat[0], N, raw)
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


## Fluss-Ribbons aus dem letzten Band-Bau des Frames ins Mesh. Die Schutzmaske
## dazu bringt derselbe Frame mit.
func _upload_ribbon_mesh() -> void:
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

# ---------------------------------------------------------------- Kamera & Eingabe

func _update_camera() -> void:
	var cp := cos(cam_pitch)
	var offset := Vector3(sin(cam_yaw) * cp, sin(cam_pitch), cos(cam_yaw) * cp) * cam_dist
	cam.position = cam_target + offset
	cam.look_at(cam_target, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	last_activity_msec = Time.get_ticks_msec()
	if not event is InputEventMouseMotion:
		rs_camera = -1 # ab jetzt führt der Spieler die Kamera (s. RS_CAMERA)
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
				cam_dist = max(CAM_DIST_MIN, cam_dist - 8.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				cam_dist = min(world_size * 4.0, cam_dist + 8.0)
	elif event is InputEventMouseMotion and orbiting:
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clamp(cam_pitch + event.relative.y * 0.005, 0.15, 1.5)
	# Zoom ohne Maus: Trackpad-Zwei-Finger-Wisch …
	elif event is InputEventPanGesture:
		cam_dist = clamp(cam_dist + event.delta.y * 6.0, CAM_DIST_MIN, world_size * 4.0)
	# … Pinch-Geste …
	elif event is InputEventMagnifyGesture:
		cam_dist = clamp(cam_dist / event.factor, CAM_DIST_MIN, world_size * 4.0)
	# … und +/− auf der Tastatur.
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				cam_dist = max(CAM_DIST_MIN, cam_dist - 12.0)
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
			_:
				# Werkzeug-Tasten 1…N in Tabellen-Reihenfolge (Issue #53): ein
				# neues Werkzeug braucht hier keine eigene Zeile mehr.
				var t: int = event.keycode - KEY_1
				if t >= 0 and t < TOOLS.size():
					current_tool = t
					# Über den Setter, nicht set_pressed_no_signal: nur er löst den
					# vorher aktiven Knopf der ButtonGroup (sonst leuchteten zwei).
					tool_buttons[t].button_pressed = true
				# Kamera-Presets ebenso: F1…F3 in Tabellen-Reihenfolge.
				var c: int = event.keycode - KEY_F1
				if c >= 0 and c < CAMERA_PRESETS.size():
					_apply_camera_preset(c)

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

func _update_brush() -> void:
	# Autonome Screenshots zeigen keinen Pinsel, außer RS_BRUSH verlangt ihn:
	# dann steht die Kuppel in der Bildmitte statt am Mauszeiger.
	var fixed := OS.has_environment("RS_BRUSH")
	if OS.has_environment("RS_SHOT") and not fixed:
		brush_mi.visible = false
		return
	if sculpting or year_rate == 0.0:
		var hit := _raycast_at(get_viewport().get_visible_rect().size * 0.5) \
			if fixed else _raycast_terrain()
		if hit != Vector3.INF:
			var tool: Dictionary = TOOLS[current_tool]
			# Spitzhacke: die Kuppel zeigt die echte (gedeckelte) Hieb-Breite.
			var r := minf(brush_radius, pick_radius_cap) \
				if tool.get("radius_capped", false) else brush_radius
			var power: float = tool.get("falloff_power", BRUSH_FALLOFF_POWER)
			var key := [hit, r, power, surface_version]
			if key != brush_key:
				brush_key = key
				brush_mesh.clear_surfaces()
				brush_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
					brush_bands(brush_dome(hit, r, power)), [], {},
					Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			brush_mi.position = hit
			brush_mi.visible = true
			return
	brush_mi.visible = false

## Gewicht des Pinsels im Abstand `d` (Anteil am Radius): (1 − d²)^p wie in
## Terrain.forEachBrushCell (p = 2) und Terrain.pickaxe (p = 4).
static func brush_weight(d: float, power: float) -> float:
	if d >= 1.0:
		return 0.0
	return pow(1.0 - d * d, power)

## Linienpaare der Gitterkuppel um `center` (Koordinaten relativ zu `center`)
## samt Vertex-Farben und Breiten (Kern, Halo in px): BRUSH_DOME_RINGS
## Breitenkreise bei d = k / RINGS (der äußerste ist der Rand) und
## BRUSH_DOME_MERIDIANS Meridiane vom Rand zum Scheitel. Jeder Punkt liegt auf
## der sichtbaren Fläche plus BRUSH_DOME_LIFT plus Profil
## r · BRUSH_DOME_HEIGHT · w(d). Gezeichnet wird daraus `brush_bands`.
func brush_dome(center: Vector3, radius: float, power: float) -> Array:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var widths := PackedVector2Array()
	var rim_w := Vector2(BRUSH_RIM_WIDTH_PX, BRUSH_RIM_HALO_PX)
	var grid_w := Vector2(BRUSH_GRID_WIDTH_PX, BRUSH_GRID_HALO_PX)
	for k in range(BRUSH_DOME_RINGS, 0, -1):  # erst der Rand: Punkt 0 liegt auf ihm
		var d := float(k) / BRUSH_DOME_RINGS
		var rim := k == BRUSH_DOME_RINGS
		var color := BRUSH_RIM_COLOR if rim else BRUSH_GRID_COLOR
		var w := rim_w if rim else grid_w
		var prev := _dome_point(center, radius, power, d, 0.0)
		for s in range(1, BRUSH_DOME_SEGMENTS + 1):
			var p := _dome_point(center, radius, power, d, TAU * s / BRUSH_DOME_SEGMENTS)
			verts.append_array([prev, p])
			colors.append_array([color, color])
			widths.append_array([w, w])
			prev = p
	var steps := BRUSH_DOME_RINGS * 2
	for m in BRUSH_DOME_MERIDIANS:
		var a := TAU * m / BRUSH_DOME_MERIDIANS
		var prev := _dome_point(center, radius, power, 1.0, a)
		for s in range(1, steps + 1):
			var p := _dome_point(center, radius, power, 1.0 - float(s) / steps, a)
			verts.append_array([prev, p])
			colors.append_array([BRUSH_GRID_COLOR, BRUSH_GRID_COLOR])
			widths.append_array([grid_w, grid_w])
			prev = p
	return [verts, colors, widths]

## Mesh-Arrays (PRIMITIVE_TRIANGLES, CUSTOM0 als RGBA-Float) aus den
## Linienpaaren von `brush_dome`: je Paar ein Band aus vier Ecken, das
## shaders/brush_dome.gdshaderinc in Bildschirm-Pixeln aufspannt (Belegung der
## Kanäle dort). Ecken 0/1 sitzen auf dem Anfang, 2/3 auf dem Ende; das Ende
## sieht den Anfang als „anderen" Punkt, also dreht CUSTOM0.w seine Normale.
static func brush_bands(lines: Array) -> Array:
	var src: PackedVector3Array = lines[0]
	var src_colors: PackedColorArray = lines[1]
	var src_widths: PackedVector2Array = lines[2]
	var verts := PackedVector3Array()
	var other := PackedFloat32Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var index := PackedInt32Array()
	for i in range(0, src.size(), 2):
		var a := src[i]
		var b := src[i + 1]
		var w := src_widths[i]
		var base := verts.size()
		verts.append_array([a, a, b, b])
		other.append_array([b.x, b.y, b.z, 1.0, b.x, b.y, b.z, 1.0,
			a.x, a.y, a.z, -1.0, a.x, a.y, a.z, -1.0])
		colors.append_array([src_colors[i], src_colors[i], src_colors[i + 1], src_colors[i + 1]])
		uv.append_array([Vector2(-1.0, w.x), Vector2(1.0, w.x),
			Vector2(-1.0, w.x), Vector2(1.0, w.x)])
		var halo := Vector2(w.y, 0.0)
		uv2.append_array([halo, halo, halo, halo])
		index.append_array([base, base + 1, base + 2, base + 2, base + 1, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_CUSTOM0] = other
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = index
	return arrays

func _dome_point(center: Vector3, radius: float, power: float, d: float, a: float) -> Vector3:
	var x := center.x + cos(a) * d * radius
	var z := center.z + sin(a) * d * radius
	var y := _surface_y((x + half) / step, (z + half) / step) + BRUSH_DOME_LIFT \
		+ radius * BRUSH_DOME_HEIGHT * brush_weight(d, power)
	return Vector3(x, y, z) - center

func _raycast_terrain() -> Vector3:
	return _raycast_at(get_viewport().get_mouse_position())

## Treffer der sichtbaren Fläche unter einem Bildschirmpunkt.
func _raycast_at(screen_pos: Vector2) -> Vector3:
	return _raycast_surface(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos))

## Heightfield-Raymarch gegen die SICHTBARE Fläche (Sim-Höhe plus
## Render-Verschiebung, #153): Pinselkuppel und Strich-Beginn liegen auf dem, was
## man sieht. Der Pinsel selbst wirkt weiter auf die Sim-Zelle unter dem
## Treffer (x/z des Treffers → Gitterposition).
func _raycast_surface(ro: Vector3, rd: Vector3) -> Vector3:
	_relief_cpu()
	var prev_t := 0.0
	var t := 0.8
	while t < world_size * 6.0:
		var p := ro + rd * t
		var gx := (p.x + half) / step
		var gz := (p.z + half) / step
		if gx >= 0 and gx <= N - 1 and gz >= 0 and gz <= N - 1 and p.y <= _surface_y(gx, gz):
			var lo := prev_t
			var hi := t
			for b in 12:
				var mid := (lo + hi) * 0.5
				var m := ro + rd * mid
				if m.y <= _surface_y((m.x + half) / step, (m.z + half) / step):
					hi = mid
				else:
					lo = mid
			return ro + rd * hi
		prev_t = t
		t += 0.8
	return Vector3.INF

## Sim-Höhe (0…1) an einer Gitterposition.
func _sample_h(gx: float, gz: float) -> float:
	_ensure_h_cache()
	return _sample_grid(h_cache, gx, gz)

## Sichtbare Höhe (Welt-Y): Sim-Höhe plus Render-Verschiebung (#153) plus
## Kronendach (#152). Seen tragen beides nicht (Schutzmaske), dort bleibt es
## die Sim-Höhe.
func _surface_y(gx: float, gz: float) -> float:
	var y := _sample_h(gx, gz) * HSCALE
	if not relief_lift_cache.is_empty():
		y += (_sample_grid(relief_lift_cache, gx, gz) - 0.5) / relief_height_code \
			* relief_geometry_fade(sim.currentYear(), relief_geometry_age)
	return y + _forest_lift_at(gx, gz)

## Dachzuschlag in Welt-Y wie im Terrain-Shader: Waldmaske bilinear, dann
## das Anhebe-Fenster. Die Maske wird erst beim ersten Raycast nach einem
## Upload in Floats gewandelt.
func _forest_lift_at(gx: float, gz: float) -> float:
	if forest_img == null:
		return 0.0
	if forest_lift_cache.is_empty():
		var img: Image = forest_img.duplicate()
		img.convert(Image.FORMAT_RF)
		forest_lift_cache = img.get_data().to_float32_array()
	return smoothstep(canopy_calib["canopy_lift_lo"], canopy_calib["canopy_lift_hi"],
		_sample_grid(forest_lift_cache, gx, gz)) * canopy_calib["canopy_height"]

## Anteil der echten Verformung nach Geländealter, wie im Terrain-Shader
## (`relief_lift`): auf jungem Relief nur Schattierung, ab `age` voll.
static func relief_geometry_fade(year: float, age: float) -> float:
	return smoothstep(0.0, age, year)

## Sichtbare Höhe unter einem Weltpunkt (nur x/z zählen).
func _surface_y_at(p: Vector3) -> float:
	return _surface_y((p.x + half) / step, (p.z + half) / step)

## Bilinear auf einem n×n-Feld, row-major wie die Sim-Felder.
func _sample_grid(field: PackedFloat32Array, gx: float, gz: float) -> float:
	var xi := clampi(int(floor(gx)), 0, N - 2)
	var yi := clampi(int(floor(gz)), 0, N - 2)
	var fx := clampf(gx - xi, 0.0, 1.0)
	var fy := clampf(gz - yi, 0.0, 1.0)
	var i00 := yi * N + xi
	return field[i00] * (1 - fx) * (1 - fy) + field[i00 + 1] * fx * (1 - fy) \
		+ field[i00 + N] * (1 - fx) * fy + field[i00 + N + 1] * fx * fy
