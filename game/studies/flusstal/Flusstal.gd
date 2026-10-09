extends "res://scripts/Main.gd"
## Bildstudie #116, zweite Runde: dieselbe Simulationswelt, zwei Hebel.
##
##  geometry  dichtes Render-Mesh (2× Sim-Raster) + grobe Erosionsrinnen und
##            geschärfte Grate als echte Verschiebung im Vertex-Shader
##  canopy    Maßstab 1 Einheit ≈ 100 m: Kronendach im Terrain-Shader statt
##            übergroßer Instanzbäume
##
## Die beiden übrigen Hebel der Abnahme sind Produktion und gelten damit in
## beiden Varianten; die Studie hat für sie keinen eigenen Schalter mehr:
## `light` (tiefe Sonne, Schatten, Luftperspektive, Talnebel, Wolkenschatten)
## seit #151 in scripts/Lighting.gd, `frame` (Ozean ohne Streifen,
## Schelf-Farbe, Brandung) seit #155 in shaders/ocean.gdshader.
##
## Alles prozedural aus den Sim-Feldern, keine Handplatzierung: die Studie gilt
## damit für jeden Seed und bleibt im Zeitraffer, nach Pinselstrichen und nach
## dem Laden aktiv. `RS_STUDY_LEVERS` schaltet einzelne Hebel für die
## Wirkungsleiter (Komma-Liste, Standard: alle).

const STUDY_LEVERS := ["geometry", "canopy"]
## Render-Gitter der Studie: Sim-Auflösung (n = 720) statt der 384 von
## `balanced`. Es trägt die Silhouette der groben Verschiebung; ihre Normalen
## und Rinnen liest der Fragment-Shader aus der doppelt so feinen Backtextur.
## Gemessen (M4 Max, 3456×2104, Übersicht): 720 → 16 ms, 1080 → 24 ms,
## 1440 → 32 ms je Bild — die Kosten folgen der Vertexzahl, und bei 1440 sind
## die Dreiecke in der Übersicht kleiner als ein Pixel. `RS_STUDY_GRID`
## überschreibt den Wert für Messungen.
const RELIEF_BAKE_SIZE := 1440
var STUDY_GRID := int(OS.get_environment("RS_STUDY_GRID")) if OS.has_environment("RS_STUDY_GRID") else 720
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
var study_protect_tex: ImageTexture
var study_relief_vp: SubViewport
var study_relief_mat: ShaderMaterial

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
		"terrain_grid": STUDY_GRID if _lever("geometry") else terrain_grid,
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


	if _lever("geometry"):
		var pm := PlaneMesh.new()
		pm.size = Vector2(world_size, world_size)
		pm.subdivide_width = STUDY_GRID - 2
		pm.subdivide_depth = STUDY_GRID - 2
		terrain_mi.mesh = pm
		# Die Bänder sampeln die SICHTBARE Oberfläche des Render-Gitters. Das
		# dichte Mesh zeigt außerhalb der Verschiebung die bilineare Sim-Fläche,
		# deren nächste Entsprechung das volle Sim-Gitter ist.
		sim.setRenderGrid(N)
		_setup_relief_bake()
		terrain_mat.set_shader_parameter("study_geometry", true)
	if _lever("canopy"):
		terrain_mat.set_shader_parameter("study_canopy_enabled", true)
		# Das Kronendach ersetzt die Instanzbäume (in diesem Maßstab ~90 m breit).
		for mmi in tree_mmi:
			mmi.visible = false

## Back-Pass der groben Verschiebung: ein Float-SubViewport auf Render-Gitter-
## Auflösung, der nur nach einem Terrain-Update einmal zeichnet (UPDATE_ONCE).
func _setup_relief_bake() -> void:
	study_relief_vp = SubViewport.new()
	study_relief_vp.size = Vector2i(RELIEF_BAKE_SIZE, RELIEF_BAKE_SIZE)
	study_relief_vp.use_hdr_2d = true
	# Transparent, sonst verwirft der Viewport den Alpha-Kanal (Rinnen/Rippen).
	study_relief_vp.transparent_bg = true
	study_relief_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var rect := ColorRect.new()
	rect.size = Vector2(RELIEF_BAKE_SIZE, RELIEF_BAKE_SIZE)
	study_relief_mat = ShaderMaterial.new()
	study_relief_mat.shader = load("res://studies/flusstal/relief_bake.gdshader")
	study_relief_mat.set_shader_parameter("grid_n", float(N))
	study_relief_mat.set_shader_parameter("hscale", HSCALE)
	study_relief_mat.set_shader_parameter("sea_level", sea)
	# Kalibrier-Hilfe: "skala,stärke,schärfung" der groben Verschiebung.
	var relief := OS.get_environment("RS_STUDY_RELIEF").split(",")
	if relief.size() == 3:
		study_relief_mat.set_shader_parameter("study_relief_scale", float(relief[0]))
		study_relief_mat.set_shader_parameter("study_relief_strength", float(relief[1]))
		study_relief_mat.set_shader_parameter("study_sharpen", float(relief[2]))
	rect.material = study_relief_mat
	study_relief_vp.add_child(rect)
	add_child(study_relief_vp)
	terrain_mat.set_shader_parameter("study_relief_tex", study_relief_vp.get_texture())

func _bake_relief() -> void:
	if study_relief_vp == null or height_field._tex == null or study_protect_tex == null:
		return
	study_relief_mat.set_shader_parameter("height_tex", height_field._tex)
	study_relief_mat.set_shader_parameter("study_protect_tex", study_protect_tex)
	study_relief_vp.render_target_update_mode = SubViewport.UPDATE_ONCE

func _rebuild_trees() -> void:
	if _lever("canopy"):
		return
	super._rebuild_trees()

func _update_ring() -> void:
	if not study_mode.is_empty():
		ring_mi.visible = false
	else:
		super._update_ring()

func _update_terrain_textures(water_blend: float = 1.0, update_overlays: bool = true) -> void:
	super._update_terrain_textures(water_blend, update_overlays)
	if update_overlays:
		_update_study_protect()
	_bake_relief()

func _rebuild_rivers() -> void:
	super._rebuild_rivers()
	_update_study_protect()
	_bake_relief()

## Schutzmaske für Verschiebung und Kronendach (#154): godot-freie Render-Ableitung
## aus SimRender (sichtbares Rasterwasser + gebaute Flussbänder + Saum von
## `WaterRender.protectSeamCells` Zellen), binär als R8. Je Aufruf nur Kopieren
## und Hochladen; die Maske selbst cached `RenderState` bis zum nächsten
## Wasser-Upload oder Band-Bau. Eine veraltete Library fängt der Build-Stempel
## beim Start ab (`scripts/start.sh`), hier steht dafür kein Ersatzpfad.
func _update_study_protect() -> void:
	if not (_lever("geometry") or _lever("canopy")):
		return
	var img := _protect_mask()
	if study_protect_tex == null:
		study_protect_tex = ImageTexture.create_from_image(img)
		terrain_mat.set_shader_parameter("study_protect_tex", study_protect_tex)
	else:
		study_protect_tex.update(img)

func _protect_mask() -> Image:
	return Image.create_from_data(N, N, false, Image.FORMAT_R8, sim.protectMaskBytes())

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
