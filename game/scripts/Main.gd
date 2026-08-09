extends Node3D
## river-sim — Godot-Frontend (M2).
## Der Simulationskern (Erosion/Flüsse/Tektonik) lebt in der GDExtension `SimNode`
## (Swift/SimCore, headless getestet). Dieses Skript macht nur Rendering, Kamera,
## Eingabe und Zeitsteuerung — die Physik-Logik wird NICHT hier dupliziert.

const HSCALE := 24.0          # Höhen-Skalierung fürs Mesh (von 30 gesenkt: weniger vertikale Überhöhung → sanfterer Look, ergänzt das gesenkte baseRelief)
const BALANCED_TERRAIN_GRID := 384
const PERFORMANCE_TERRAIN_GRID := 256

var sim: Object
var N: int
var world_size: float
var half: float
var step: float
var sea: float
var floor_level: float
var cell_area: float
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

# Terrain wird per Textur-Displacement gerendert: statisches Gitter, Höhen/Farben/
# Wasser als Texturen (pro Tick nur Upload, kein Mesh-Rebuild). Wasser ist ein
# glattes Feld-Overlay im Terrain-Shader — keine Fluss-Geometrie mehr.
var terrain_mat: ShaderMaterial
var height_img: Image
var height_tex: ImageTexture
var hf_img: Image      # gefüllte Oberfläche (Seespiegel) → echte horizontale Seeflächen
var hf_tex: ImageTexture
var color_img: Image
var color_tex: ImageTexture
var water_img: Image
var water_tex: ImageTexture
var debug_difference_img: Image
var debug_difference_tex: ImageTexture

# Nur die CPU-Höhen braucht GDScript: Raycasts lesen daraus, alle anderen
# Renderfelder bleiben im nativen SimNode und vermeiden große FFI-Kopien.
var h_cache: PackedFloat32Array

# Kamera-Orbit
var cam: Camera3D
var cam_yaw := 0.7
var cam_pitch := 0.85
var cam_dist := 135.0
var cam_target := Vector3.ZERO
var orbiting := false
const PAN_SPEED_FACTOR := 0.4 # WASD-Geschwindigkeit relativ zur Zoom-Distanz

# Zeit & Eingabe
var year_rate := 0.0          # Jahre/Sekunde
var droplet_carry := 0.0
var rebuild_timer := 0.0
var pending_years := 0.0     # über das Render-Intervall akkumulierte Sim-Jahre
var overlay_timer := 0.0
var sculpting := false
var pick_last := Vector2.INF  # Spitzhacke: Position des letzten Hiebs im Strich (INF = noch keiner)
var brush_radius := 10.0
var brush_strength := 1.0
var current_tool := 0         # Brush-Modus (siehe SimNode.brush): 0 ⛰ 1 🕳 2 〰 3 ▭ 4 🌋 5 ⛏
var flatten_target := 0.0     # Zielhöhe fürs Einebnen — beim Strich-Beginn gesampelt
var last_rate := 30.0         # für Leertaste: Pause ↔ letztes Tempo
var u_time := 0.0
var year_label: Label
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
const DEBUG_STATS_COUNT := 18
const DEBUG_REFRESH_SECONDS := 1.0

# UI-Referenzen (Toggle-Zustände & Slider-Wertanzeigen)
var speed_buttons: Array[Button] = []
var tool_buttons: Array[Button] = []
var radius_value: Label
var strength_value: Label
var radius_slider: HSlider

const TOOLS := [
	["⛰", "Anheben", "1"], ["🕳", "Absenken", "2"], ["〰", "Glätten", "3"],
	["▭", "Einebnen", "4"], ["🌋", "Aufrauen", "5"], ["⛏", "Spitzhacke", "6"],
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
	floor_level = sim.floorLevel()
	pick_radius_cap = sim.pickaxeMaxRadiusWorld()
	half = world_size / 2.0
	step = world_size / float(N - 1)
	cell_area = step * step
	# Die Simulation bleibt immer bei N×N. Nur das GPU-Displacement nutzt eine
	# adaptive Tessellation; per-pixel-Normalen und Heightmap bleiben unverändert.
	render_quality = OS.get_environment("RS_QUALITY").to_lower()
	if render_quality.is_empty():
		render_quality = "balanced"
	var requested_grid := N if render_quality == "quality" else (
		PERFORMANCE_TERRAIN_GRID if render_quality == "performance" else BALANCED_TERRAIN_GRID)
	if OS.has_environment("RS_RENDER_GRID"):
		requested_grid = int(OS.get_environment("RS_RENDER_GRID"))
	terrain_grid = clampi(requested_grid, 64, N)

	_setup_scene()
	_setup_ui()
	sim.captureDebugReference()
	if OS.has_environment("RS_DEBUG_DIFF"): # automatisierte Diagnose-Screenshots
		_set_debug_difference(true)
	if OS.has_environment("RS_STEP"): # für Screenshots: erodiertes Terrain zeigen
		var total := float(OS.get_environment("RS_STEP"))
		var done := 0.0
		while done < total: # in Schritten wie der Zeitraffer (repräsentativ)
			sim.step(1000.0)
			done += 1000.0
	if OS.has_environment("RS_FLATTEN"): # Debug: exakt flache Fläche (Shader-NaN-Repro)
		for i in 300:
			sim.brush(3, N * 0.5, N * 0.5, 30.0, 10.0, sea + 0.25)
		# Bei diesem Repro interessiert nur die Entwicklung AB der flachen Fläche.
		sim.captureDebugReference()
	sim.recomputeFlow()
	_pull_fields()
	_update_year()
	_update_terrain_textures()
	_maybe_rebuild_trees()
	_refresh_debug()
	if OS.has_environment("RS_DIAG"):
		_diag()

func _diag() -> void:
	var land := 0
	for k in h_cache.size():
		if h_cache[k] > sea + 0.012:
			land += 1
	print("DIAG sim_cells=", h_cache.size(), " terrain_verts=", terrain_grid * terrain_grid, " land=", land)
	var step_t0 := Time.get_ticks_usec()
	sim.step(60.0)
	var step_ms := (Time.get_ticks_usec() - step_t0) / 1000.0
	_pull_fields()
	print("DIAG PERF step_60y_ms=", step_ms)
	var t0 := Time.get_ticks_usec()
	for r in 10:
		_update_terrain_textures()
	var t_terr := (Time.get_ticks_usec() - t0) / 10000.0
	print("DIAG PERF terrain_texupload_ms=", t_terr)

# ---------------------------------------------------------------- Szene / UI

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
	e.ambient_light_energy = 0.18
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Filmischer Look + Tiefe.
	e.tonemap_mode = Environment.TONE_MAPPER_ACES
	e.tonemap_exposure = 0.78
	e.ssao_enabled = render_quality != "performance"
	e.ssao_intensity = 1.8 # kräftigere Ambient-Occlusion → Tiefe in den Rinnen
	e.glow_enabled = render_quality != "performance"
	e.glow_intensity = 0.2
	e.glow_bloom = 0.08
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.06 # dezenter Sättigungs-Boost (Moos/Wasser tragen mehr Farbe)
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.76, 0.78, 0.79)
	e.fog_density = 0.0006
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	# warmes, kräftiges Sonnenlicht dominiert das neutrale Ambient → naturalistischer Fels
	sun.light_color = Color(1.0, 0.96, 0.90)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	add_child(sun)
	# Eindeutig von schräg oben aufs Terrain scheinen lassen (statt mehrdeutiger Euler).
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
	terrain_mi.material_override = terrain_mat
	add_child(terrain_mi)

	water_mi = MeshInstance3D.new()
	var wp := PlaneMesh.new()
	wp.size = Vector2(world_size * 1.05, world_size * 1.05)
	water_mi.mesh = wp
	# Durchscheinend wie im Prototyp (Terrain scheint durch), aber mit dezenter
	# Himmelsspiegelung durch niedrige Roughness + etwas Metallic.
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.10, 0.28, 0.50, 0.5)
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.roughness = 0.08
	wmat.metallic = 0.2
	water_mi.material_override = wmat
	water_mi.position.y = sea * HSCALE
	add_child(water_mi)

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
		var b := _mk_button("%s %s" % [TOOLS[t][0], TOOLS[t][1]], true, tool_group)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = "Taste %s" % TOOLS[t][2]
		b.pressed.connect(func(): current_tool = t)
		grid.add_child(b)
		tool_buttons.append(b)
	tool_buttons[0].set_pressed_no_signal(true)

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

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	hint.text = "WASD: Kamera bewegen · Links: formen (Shift: ⛰↔🕳) · Rechts: drehen\nZoom: +/− · Werkzeug: 1–6 · Radius: [ ] · Pause: Leertaste"
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
	_jumping = false

func _regen() -> void:
	sim_seed = (sim_seed * 16807 + 1) % 2147483647
	sim.generate(sim_seed)
	sim.recomputeFlow()
	_after_sim()

func _capture_debug_reference() -> void:
	sim.captureDebugReference()
	_refresh_debug()

func _set_debug_difference(enabled: bool) -> void:
	debug_difference_enabled = enabled
	debug_legend_label.visible = enabled
	terrain_mat.set_shader_parameter("debug_difference", enabled)
	if enabled:
		_refresh_debug()

func _after_sim() -> void:
	_pull_fields()
	_update_year()
	_update_terrain_textures()
	_maybe_rebuild_trees()
	debug_dirty = true

var _shot_frame := 0
var _fps_accum := 0.0
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

	u_time += delta * (2.5 if year_rate > 0.0 else 0.7)
	if terrain_mat:
		terrain_mat.set_shader_parameter("u_time", u_time)
	if debug_dirty:
		debug_refresh_timer += delta
		if debug_refresh_timer >= DEBUG_REFRESH_SECONDS:
			_refresh_debug()

	if year_rate > 0.0:
		# Jahre über das Render-Intervall AKKUMULIEREN und nur EINMAL pro Render
		# steppen — statt jeden Frame (die Sim-Schritte enthalten mehrere O(n²)-
		# Pässe: computeFlow, outletIncision, Hangdiffusion, wave). Zwischen zwei
		# Renders ~9 Schritte à 1 Jahr wären 9× diese Pässe für dasselbe Ergebnis;
		# ein Schritt à 9 Jahre ist gleichwertig und ~9× billiger.
		pending_years += year_rate * delta
		rebuild_timer += delta
		if rebuild_timer > 0.15:
			var elapsed := rebuild_timer
			rebuild_timer = 0.0
			# Jahre/Schritt deckeln → hält jeden Schritt billig (keine Todesspirale).
			var years := minf(pending_years, 240.0)
			pending_years = 0.0
			sim.step(years)
			_pull_fields()
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

	if sculpting:
		var hit := _raycast_terrain()
		if hit != Vector3.INF:
			var gx := (hit.x + half) / step
			var gz := (hit.z + half) / step
			var mode := current_tool
			if Input.is_key_pressed(KEY_SHIFT): # Shift kehrt Anheben/Absenken um
				if mode == 0: mode = 1
				elif mode == 1: mode = 0
			if mode == 5:
				# Spitzhacke: Kerben ZEICHNEN — ein Hieb pro neu überstrichener
				# Position, das Segment zum letzten Hieb wird lückenlos aufgefüllt.
				# Auf der Stelle verharren gräbt NICHT tiefer (kein Dauerbohren).
				var p := Vector2(gx, gz)
				if pick_last == Vector2.INF:
					sim.brush(5, gx, gz, brush_radius, brush_strength * 1.5, 0.0)
					pick_last = p
				else:
					var spacing := 1.5 # Zellen zwischen Hieben ≈ halbe Hieb-Breite
					while pick_last.distance_to(p) >= spacing:
						pick_last += (p - pick_last).normalized() * spacing
						sim.brush(5, pick_last.x, pick_last.y, brush_radius, brush_strength * 1.5, 0.0)
			else:
				# Framerate-unabhängig: Wirkung ∝ Zeit statt ∝ Frames (60-FPS-
				# Referenz; delta-Deckel hält Ruckler-Frames von Riesen-Hieben ab).
				var stroke := brush_strength * minf(delta, 0.05) * 60.0
				sim.brush(mode, gx, gz, brush_radius, stroke, flatten_target)
			sim.recomputeFlow() # Flüsse reagieren sofort auf den Eingriff
			_pull_fields()
			debug_dirty = true
			_update_terrain_textures()

	_update_camera_pan(delta)
	_update_ring()
	_update_camera()

func _update_camera_pan(delta: float) -> void:
	# Bewegung bleibt auf der Terrain-Ebene und folgt der Blickrichtung statt den
	# Weltachsen. Die Zoom-abhängige Geschwindigkeit hält sie in Nah- und Fernsicht
	# gleich gut kontrollierbar.
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S)))
	if move == Vector2.ZERO:
		return
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
		+ "Relief %.3f (Signal %.3f)  Δmax %+.3f  ΔØ %+.3f\n" % [
			stats[DBG_RELIEF], stats[DBG_RELIEF_SIGNAL], stats[DBG_DELTA_MAX], stats[DBG_DELTA_MEAN]]
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
		debug_warning_label.text = "⚠ Relief-Untergrenze aktiv: +%.5f / 100 J.\nReliefsignal %.3f / Ziel %.3f (Hebung U(t) %.5f)" % [
			stats[DBG_SERVO], stats[DBG_RELIEF_SIGNAL], stats[DBG_RELIEF_TARGET], stats[DBG_UPLIFT]]
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

func _pull_fields() -> void:
	h_cache = sim.heights() # Höhentextur + Raycast

# ---------------------------------------------------------------- Terrain-Textur

## Lädt Höhen (R32F) und Farben (RGBA8) als Texturen hoch — GPU macht Displacement
## und Färbung. Pro Tick nur ein Upload statt kompletter Mesh-Rebuild.
func _update_terrain_textures(water_blend: float = 1.0, update_overlays: bool = true) -> void:
	var hbytes := h_cache.to_byte_array() # PackedFloat32Array → rohe float32-Bytes
	if height_img == null:
		height_img = Image.create_from_data(N, N, false, Image.FORMAT_RF, hbytes)
		height_tex = ImageTexture.create_from_image(height_img)
		terrain_mat.set_shader_parameter("height_tex", height_tex)
	else:
		height_img.set_data(N, N, false, Image.FORMAT_RF, hbytes)
		height_tex.update(height_img)
	if not update_overlays:
		return

	# Seespiegel-Feld (hf): der Vertex-Shader hebt See-Zellen auf diese Höhe →
	# Seen liegen als horizontale Flächen im Becken statt den Hang anzumalen.
	var fbytes: PackedByteArray = (sim.filled() as PackedFloat32Array).to_byte_array()
	if hf_img == null:
		hf_img = Image.create_from_data(N, N, false, Image.FORMAT_RF, fbytes)
		hf_tex = ImageTexture.create_from_image(hf_img)
		terrain_mat.set_shader_parameter("hf_tex", hf_tex)
	else:
		hf_img.set_data(N, N, false, Image.FORMAT_RF, fbytes)
		hf_tex.update(hf_img)

	var cbytes: PackedByteArray = sim.terrainColorBytes()
	if color_img == null:
		color_img = Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, cbytes)
		color_tex = ImageTexture.create_from_image(color_img)
		terrain_mat.set_shader_parameter("color_tex", color_tex)
	else:
		color_img.set_data(N, N, false, Image.FORMAT_RGBA8, cbytes)
		color_tex.update(color_img)
	# Wasser-Feld (Flüsse/Seen/Altarme) als glattes Overlay-Textur.
	# water_blend < 1 → zeitliche EWMA-Glättung (Läufe blenden statt zu springen).
	var wbytes: PackedByteArray = sim.waterFieldBytes(water_blend)
	if water_img == null:
		water_img = Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, wbytes)
		water_tex = ImageTexture.create_from_image(water_img)
		terrain_mat.set_shader_parameter("water_tex", water_tex)
	else:
		water_img.set_data(N, N, false, Image.FORMAT_RGBA8, wbytes)
		water_tex.update(water_img)

func _update_debug_difference_texture() -> void:
	var bytes: PackedByteArray = sim.heightDifferenceBytes(debug_difference_scale)
	if debug_difference_img == null:
		debug_difference_img = Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, bytes)
		debug_difference_tex = ImageTexture.create_from_image(debug_difference_img)
		terrain_mat.set_shader_parameter("debug_difference_tex", debug_difference_tex)
	else:
		debug_difference_img.set_data(N, N, false, Image.FORMAT_RGBA8, bytes)
		debug_difference_tex.update(debug_difference_img)


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
	for v in tree_mmi.size():
		var buf: PackedFloat32Array = sim.treeInstanceBuffer(v, HSCALE)
		var mm: MultiMesh = tree_mmi[v].multimesh
		mm.instance_count = buf.size() / 12
		if buf.size() > 0:
			mm.buffer = buf
	sim.markTreesBuilt()

# ---------------------------------------------------------------- Kamera & Eingabe

func _update_camera() -> void:
	var cp := cos(cam_pitch)
	var offset := Vector3(sin(cam_yaw) * cp, sin(cam_pitch), cos(cam_yaw) * cp) * cam_dist
	cam.position = cam_target + offset
	cam.look_at(cam_target, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				sculpting = event.pressed
				if not event.pressed:
					pick_last = Vector2.INF # Strich beendet → nächster Klick beginnt neu
				if event.pressed and current_tool == 3:
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
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				var t: int = event.keycode - KEY_1
				current_tool = t
				tool_buttons[t].set_pressed_no_signal(true)

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
			var r := minf(brush_radius, pick_radius_cap) if current_tool == 5 else brush_radius
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
	var xi := clampi(int(floor(gx)), 0, N - 2)
	var yi := clampi(int(floor(gz)), 0, N - 2)
	var fx := clampf(gx - xi, 0.0, 1.0)
	var fy := clampf(gz - yi, 0.0, 1.0)
	var i00 := yi * N + xi
	return h_cache[i00] * (1 - fx) * (1 - fy) + h_cache[i00 + 1] * fx * (1 - fy) \
		+ h_cache[i00 + N] * (1 - fx) * fy + h_cache[i00 + N + 1] * fx * fy
