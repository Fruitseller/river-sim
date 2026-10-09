extends "res://scripts/Main.gd"
## Bildstudie #116, zweite Runde: dieselbe Simulationswelt, ein Hebel.
##
##  canopy    Maßstab 1 Einheit ≈ 100 m: Kronendach im Terrain-Shader statt
##            übergroßer Instanzbäume
##
## Die übrigen Hebel der Abnahme sind Produktion und gelten damit in
## beiden Varianten; die Studie hat für sie keinen Schalter mehr:
## `light` (tiefe Sonne, Schatten, Luftperspektive, Talnebel, Wolkenschatten)
## seit #151 in scripts/Lighting.gd, `frame` (Ozean ohne Streifen,
## Schelf-Farbe, Brandung) seit #155 in shaders/ocean.gdshader, `geometry`
## (Render-Gitter in Sim-Auflösung, grobe Erosionsrinnen und geschärfte Grate
## als echte Verschiebung) seit #153 in Main.gd und shaders/relief_bake.gdshader.
##
## Alles prozedural aus den Sim-Feldern, keine Handplatzierung: die Studie gilt
## damit für jeden Seed und bleibt im Zeitraffer, nach Pinselstrichen und nach
## dem Laden aktiv. `RS_STUDY_LEVERS` schaltet einzelne Hebel für die
## Wirkungsleiter (Komma-Liste, Standard: alle).

const STUDY_LEVERS := ["canopy"]
var study_variant := OS.get_environment("RS_STUDY_VARIANT")
var study_enabled := study_variant == "prototype"
var study_mode := OS.get_environment("RS_STUDY_MODE")
var study_output := OS.get_environment("RS_STUDY_OUTPUT")
var study_levers := {}
var study_elapsed := 0.0
var study_frames := 0
var study_last_draw := 0
var study_intervals: Array[float] = []
var study_start_yaw := 0.0

func _ready() -> void:
	# Nur die zwei dokumentierten Varianten sind gültig: ein Tippfehler oder eine
	# leere Umgebung landete vorher still im Prototyp (Review zu #121).
	if study_variant != "prototype" and study_variant != "baseline":
		push_error("RS_STUDY_VARIANT muss 'prototype' oder 'baseline' sein, ist: '"
			+ study_variant + "'. Start über scripts/graphics-study.sh.")
		get_tree().quit(1)
		return
	if not _parse_levers():
		get_tree().quit(1)
		return
	super._ready()
	if sim == null:
		get_tree().quit(1)
		return
	study_start_yaw = cam_yaw
	for child in get_children():
		if child is CanvasLayer:
			child.visible = study_mode.is_empty()
	if not study_mode.is_empty():
		active_fps_cap = 0
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.frame_post_draw.connect(_study_drawn)
	print("STUDY ", JSON.stringify({"variant": "prototype" if study_enabled else "baseline",
		"levers": study_levers.keys(), "seed": sim_seed, "year": sim.currentYear(),
		"viewport": str(get_viewport().size), "quality": render_quality,
		"terrain_grid": terrain_grid,
		"target": str(cam_target), "distance": cam_dist, "yaw": cam_yaw,
		"pitch": cam_pitch, "mode": study_mode}))

## Hebel aus `RS_STUDY_LEVERS`; ein unbekannter Name bricht ab statt still
## ignoriert zu werden (gleiche Regel wie bei RS_STUDY_VARIANT).
func _parse_levers() -> bool:
	if not study_enabled:
		return true
	var raw := OS.get_environment("RS_STUDY_LEVERS")
	var names: PackedStringArray = STUDY_LEVERS if raw.is_empty() else raw.split(",", false)
	for name in names:
		if not STUDY_LEVERS.has(name.strip_edges()):
			push_error("RS_STUDY_LEVERS: unbekannter Hebel '%s' (erlaubt: %s)"
				% [name, ",".join(STUDY_LEVERS)])
			return false
		study_levers[name.strip_edges()] = true
	return true

func _lever(name: String) -> bool:
	return study_enabled and study_levers.has(name)

## Zur Laufzeit gebaute Studien-Fassung eines Produktions-Shaders: Godot 4.7
## lehnt #include einer Datei mit shader_type ab, deshalb wird das Define vor
## die Quelle gestellt (der Präprozessor läuft auf dem zusammengesetzten Code;
## alle Uniform-Namen bleiben gleich, gesetzte Werte bleiben am Material).
static func study_shader(path: String) -> Shader:
	var shader := Shader.new()
	shader.code = "#define FLUSSTAL_STUDY\n" + FileAccess.get_file_as_string(path)
	return shader

func _setup_scene() -> void:
	super._setup_scene()
	if not study_enabled:
		return
	terrain_mat.shader = study_shader("res://shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("study_enabled", true)
	for kind in ["rock", "ground"]:
		for channel in ["color", "normal", "roughness"]:
			terrain_mat.set_shader_parameter("study_" + kind + "_" + channel,
				load("res://studies/flusstal/assets/" + kind + "_" + channel + ".jpg"))
	var debug := OS.get_environment("RS_STUDY_DEBUG")
	terrain_mat.set_shader_parameter("study_debug",
		{"protect": 1, "forest": 2, "cavity": 3}.get(debug, 0))
	if _lever("canopy"):
		terrain_mat.set_shader_parameter("study_canopy_enabled", true)
		# Das Kronendach ersetzt die Instanzbäume (in diesem Maßstab ~90 m breit).
		for mmi in tree_mmi:
			mmi.visible = false

func _rebuild_trees() -> void:
	if _lever("canopy"):
		return
	super._rebuild_trees()

func _update_ring() -> void:
	if not study_mode.is_empty():
		ring_mi.visible = false
	else:
		super._update_ring()

func _process(delta: float) -> void:
	if not study_mode.is_empty():
		# Echte gerenderte Standbilder messen; Main darf den Renderloop nicht anhalten.
		last_activity_msec = Time.get_ticks_msec()
		study_elapsed += delta
		if study_mode == "orbit":
			cam_yaw = study_start_yaw + maxf(0, study_elapsed - 2.0) * 0.08
			_update_camera()
		elif study_mode == "simulation" and study_elapsed > 2.0:
			year_rate = 60.0
	super._process(delta)
	if study_mode == "shot":
		# Gleiche Wasser-Animationsphase unabhängig von Shader-Kompilierzeiten.
		u_time = 1.0
		for mat in [terrain_mat, ocean_mat, river_mat]:
			if mat != null:
				mat.set_shader_parameter("u_time", u_time)

func _study_drawn() -> void:
	var now := Time.get_ticks_usec()
	study_frames += 1
	if study_elapsed > 2.0 and study_last_draw != 0:
		study_intervals.append(float(now - study_last_draw) / 1000.0)
	study_last_draw = now
	var finished := study_frames >= 60 if study_mode == "shot" else study_elapsed >= 12.0
	if not finished:
		return
	RenderingServer.frame_post_draw.disconnect(_study_drawn)
	# Bei Movie-Läufen schreibt Godot selbst den Film; kein zusätzliches PNG
	# (Review zu #121, konsistent mit dem Timing-Zweig darunter).
	if not study_output.is_empty() and Engine.get_write_movie_path().is_empty():
		var err := get_viewport().get_texture().get_image().save_png(study_output + ".png")
		if err != OK:
			push_error("Studienaufnahme konnte nicht gespeichert werden")
			get_tree().quit(1)
			return
	if not study_intervals.is_empty() and Engine.get_write_movie_path().is_empty():
		study_intervals.sort()
		var total := 0.0
		var over_budget := 0
		for interval in study_intervals:
			total += interval
			if interval > 33.3:
				over_budget += 1
		print("STUDY_TIMING ", JSON.stringify({"rendered_frames": study_intervals.size(),
			"mean_ms": total / study_intervals.size(),
			"p95_ms": study_intervals[int((study_intervals.size() - 1) * 0.95)],
			"p99_ms": study_intervals[int((study_intervals.size() - 1) * 0.99)],
			"max_ms": study_intervals.back(), "over_budget_frames": over_budget,
			"viewport": str(get_viewport().size), "mode": study_mode,
			"movie": false }))
	get_tree().quit()
