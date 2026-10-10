extends "res://scripts/Main.gd"
## Bildstudie #116, seit Spec #156 Mess- und Referenzbühne, kein
## Produktionsweg: `baseline` IST die Anwendung (Main.gd erbt alles),
## `prototype` legt nur die nicht übernommenen PBR-Materialien der ersten
## Runde darüber (historische Referenz, s. docs/graphics-quality.md).
##
## Alle Hebel der zweiten Runde sind Produktion und gelten in beiden
## Varianten: `light` (tiefe Sonne, Schatten, Luftperspektive, Talnebel,
## Wolkenschatten) seit #151 in scripts/Lighting.gd, `frame` (Ozean ohne
## Streifen, Schelf-Farbe, Brandung) seit #155 in shaders/ocean.gdshader,
## `geometry` (Render-Gitter in Sim-Auflösung, grobe Erosionsrinnen und
## geschärfte Grate als echte Verschiebung) seit #153 in Main.gd und
## shaders/relief_bake.gdshader, `canopy` (Kronendach statt Instanzbäumen)
## seit #152 in shaders/terrain.gdshader. Die Studie dient als Mess- und
## Vergleichsbühne (scripts/graphics-matrix.sh) und für die Debug-Ansichten
## der Kalibrierung (`RS_STUDY_DEBUG`).
var study_variant := OS.get_environment("RS_STUDY_VARIANT")
var study_enabled := study_variant == "prototype"
var study_mode := OS.get_environment("RS_STUDY_MODE")
var study_output := OS.get_environment("RS_STUDY_OUTPUT")
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
	if not _reject_levers():
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
		"seed": sim_seed, "year": sim.currentYear(),
		"viewport": str(get_viewport().size), "quality": render_quality,
		"terrain_grid": terrain_grid,
		"target": str(cam_target), "distance": cam_dist, "yaw": cam_yaw,
		"pitch": cam_pitch, "mode": study_mode}))

## `RS_STUDY_LEVERS` gibt es nicht mehr: alle Hebel sind Produktion (#152).
## Ein alter Aufruf scheitert laut, statt still dasselbe Bild zu liefern.
func _reject_levers() -> bool:
	var raw := OS.get_environment("RS_STUDY_LEVERS")
	if raw.is_empty():
		return true
	push_error("RS_STUDY_LEVERS='%s': alle Hebel sind Produktion, die Studie hat keine mehr" % raw)
	return false

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

## Die Debug-Ansicht der Schutzmaske liest sie im Terrain-Shader.
func _update_protect_mask(bytes: PackedByteArray) -> void:
	super._update_protect_mask(bytes)
	if study_enabled:
		terrain_mat.set_shader_parameter("protect_tex", protect_tex)

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
			"quality": render_quality, "terrain_grid": terrain_grid,
			"seed": sim_seed, "year": sim.currentYear(), "target": str(cam_target),
			"distance": cam_dist, "yaw": study_start_yaw, "variant": study_variant,
			"movie": false }))
	get_tree().quit()
