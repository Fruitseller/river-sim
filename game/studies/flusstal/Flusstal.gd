extends "res://scripts/Main.gd"
## Bildstudie #116. Feste Komposition für Seed 1337, 20.000 Vorlaufjahre.
## Die handgesetzten Waldgruppen sind keine allgemeine Biom-Verteilung.

const StudyMeshes = preload("res://studies/flusstal/StudyMeshes.gd")
var study_enabled := OS.get_environment("RS_STUDY_VARIANT") != "baseline"
var study_mode := OS.get_environment("RS_STUDY_MODE")
var study_output := OS.get_environment("RS_STUDY_OUTPUT")
var study_elapsed := 0.0
var study_frames := 0
var study_last_draw := 0
var study_intervals: Array[float] = []
var study_props: Node3D
var study_start_year := 0.0
var study_start_yaw := 0.0

func _ready() -> void:
	super._ready()
	if sim == null:
		get_tree().quit(1)
		return
	study_start_year = sim.currentYear()
	study_start_yaw = cam_yaw
	if study_enabled:
		if sim_seed != 1337 or study_start_year != 20000.0:
			push_error("Handplatzierung braucht Seed 1337 und 20.000 Jahre. Start: scripts/graphics-study.sh")
			get_tree().quit(1)
			return
		_build_composition()
	for child in get_children():
		if child is CanvasLayer:
			child.visible = study_mode.is_empty()
	if not study_mode.is_empty():
		active_fps_cap = 0
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.frame_post_draw.connect(_study_drawn)
	print("STUDY ", JSON.stringify({"variant": "prototype" if study_enabled else "baseline",
		"seed": sim_seed, "year": study_start_year, "viewport": str(get_viewport().size),
		"quality": render_quality, "target": str(cam_target), "distance": cam_dist,
		"yaw": cam_yaw, "pitch": cam_pitch, "mode": study_mode}))

func _setup_scene() -> void:
	super._setup_scene()
	if not study_enabled:
		return
	terrain_mat.set_shader_parameter("study_enabled", true)
	for kind in ["rock", "ground"]:
		for channel in ["color", "normal", "roughness"]:
			terrain_mat.set_shader_parameter("study_" + kind + "_" + channel,
				load("res://studies/flusstal/assets/" + kind + "_" + channel + ".jpg"))
	for child in get_children():
		if child is WorldEnvironment:
			child.environment.tonemap_exposure = 0.78
			child.environment.ambient_light_energy = 0.42
			child.environment.fog_density = 0.0012
		if child is DirectionalLight3D:
			child.look_at_from_position(Vector3(-80, 105, 50), Vector3.ZERO, Vector3.UP)
			child.light_color = Color(1.0, 0.97, 0.91)
			child.directional_shadow_max_distance = 160.0

func _tree_mesh(variant: int) -> ArrayMesh:
	if not study_enabled:
		return super._tree_mesh(variant)
	return StudyMeshes.tree(variant)

func _update_ring() -> void:
	if not study_mode.is_empty():
		ring_mi.visible = false
	else:
		super._update_ring()

func _update_terrain_textures(water_blend: float = 1.0, update_overlays: bool = true) -> void:
	# Auch Laden und Pinselstriche können das Bett bei gleichem Jahr verändern.
	if study_props != null:
		study_props.visible = false
	super._update_terrain_textures(water_blend, update_overlays)

## Die Gruppenmittelpunkte und Radien wurden für diesen Ausschnitt komponiert.
## Der Zufall füllt nur diese Gruppen. Wasser und steile Standorte bleiben frei.
func _build_composition() -> void:
	study_props = Node3D.new()
	study_props.name = "HandgesetzteStudie"
	add_child(study_props)
	var rng := RandomNumberGenerator.new()
	rng.seed = 116
	var water := _placement_water()
	var groups: Array[Vector3] = [Vector3(-22, -36, 8), Vector3(-10, -40, 6), Vector3(-24, -20, 7),
		Vector3(-5, -28, 5), Vector3(-18, -10, 5), Vector3(-31, -30, 7)]
	var trees: Array[Transform3D] = []
	for group in groups:
		for candidate in 600:
			var angle := rng.randf() * TAU
			var radius: float = sqrt(rng.randf()) * group.z
			var p := Vector2(group.x, group.y) + Vector2(cos(angle), sin(angle)) * radius
			if not _dry_footprint(p, 0.55, water):
				continue
			var y := _height_at(p)
			if maxf(absf(_height_at(p + Vector2(0.4, 0)) - y),
				absf(_height_at(p + Vector2(0, 0.4)) - y)) > 0.35:
				continue
			var size := rng.randf_range(0.45, 0.9)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size)
			trees.append(Transform3D(basis, Vector3(p.x, y - 0.08, p.y)))
	_add_instances(StudyMeshes.tree(0), trees)
	var rocks: Array[Transform3D] = []
	# Felszüge entlang der Talflanken; keine Auflage über dem Wasser.
	for ridge in [Vector3(-15, -33, 7), Vector3(-2, -19, 6), Vector3(-25, -15, 5)]:
		for candidate in 180:
			var p := Vector2(ridge.x + rng.randf_range(-ridge.z, ridge.z),
				ridge.y + rng.randf_range(-2.0, 2.0))
			var size := rng.randf_range(0.35, 1.1)
			if not _dry_footprint(p, size * 1.5, water):
				continue
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(size, size, size))
			rocks.append(Transform3D(basis, Vector3(p.x, _height_at(p) - size * 0.55, p.y)))
	_add_instances(StudyMeshes.rock(), rocks)
	print("STUDY_PROPS trees=", trees.size(), " rocks=", rocks.size())

func _placement_water() -> Image:
	var water: Image = water_field._img.duplicate()
	# Der Raster-Deckel entfernt Wasser unter Bändern. Deshalb zusätzlich jedes
	# tatsächlich gebaute Dreieck sperren, konservativ über seine XZ-Boundingbox.
	if river_mesh.get_surface_count() > 0:
		var arrays := river_mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, indices.size(), 3):
			var a := Vector2(INF, INF)
			var b := Vector2(-INF, -INF)
			for corner in 3:
				var p := vertices[indices[i + corner]]
				var cell := Vector2((p.x + half) / step, (p.z + half) / step)
				a = a.min(cell.floor())
				b = b.max(cell.ceil())
			water.fill_rect(Rect2i(Vector2i(a), Vector2i(b - a) + Vector2i.ONE), Color.RED)
	return water

func _height_at(p: Vector2) -> float:
	return _sample_h((p.x + half) / step, (p.y + half) / step) * HSCALE

func _dry_footprint(p: Vector2, radius: float, water: Image) -> bool:
	var a := Vector2i(floor((p.x - radius + half) / step), floor((p.y - radius + half) / step))
	var b := Vector2i(ceil((p.x + radius + half) / step), ceil((p.y + radius + half) / step))
	if a.x < 0 or a.y < 0 or b.x >= N or b.y >= N:
		return false
	for z in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			var wet := water.get_pixel(x, z)
			if maxf(wet.r, wet.g) > 0.02 or _sample_h(x, z) <= sea + 0.025:
				return false
	return true

func _add_instances(mesh: ArrayMesh, transforms: Array[Transform3D]) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	study_props.add_child(node)

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
	# Handplatzierung ist nur für den eingefrorenen Stand gültig. Beim ersten
	# Fortschritt ausblenden, bevor alte Felsen ein neues Flussbett überdecken.
	if study_props != null and sim.currentYear() != study_start_year:
		study_props.visible = false

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
	if not study_output.is_empty():
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
