extends Node3D
## river-sim — Godot-Frontend (M2).
## Der Simulationskern (Erosion/Flüsse/Tektonik) lebt in der GDExtension `SimNode`
## (Swift/SimCore, headless getestet). Dieses Skript macht nur Rendering, Kamera,
## Eingabe und Zeitsteuerung — die Physik-Logik wird NICHT hier dupliziert.

const HSCALE := 30.0          # Höhen-Skalierung fürs Mesh

var sim: Object
var N: int
var world_size: float
var half: float
var step: float
var sea: float
var floor_level: float
var cell_area: float

var terrain_mi: MeshInstance3D
var water_mi: MeshInstance3D
var ring_mi: MeshInstance3D

# Terrain wird per Textur-Displacement gerendert: statisches Gitter, Höhen/Farben/
# Wasser als Texturen (pro Tick nur Upload, kein Mesh-Rebuild). Wasser ist ein
# glattes Feld-Overlay im Terrain-Shader — keine Fluss-Geometrie mehr.
var terrain_mat: ShaderMaterial
var height_img: Image
var height_tex: ImageTexture
var color_img: Image
var color_tex: ImageTexture
var water_img: Image
var water_tex: ImageTexture

# gecachte Felder (nur render-/flussrelevant)
var h_cache: PackedFloat32Array
var hf_cache: PackedFloat32Array
var area_cache: PackedFloat32Array
var recv_cache: PackedInt32Array

# Kamera-Orbit
var cam: Camera3D
var cam_yaw := 0.7
var cam_pitch := 0.85
var cam_dist := 135.0
var cam_target := Vector3.ZERO
var orbiting := false

# Zeit & Eingabe
var year_rate := 0.0          # Jahre/Sekunde
var droplet_carry := 0.0
var flow_timer := 0.0
var rebuild_timer := 0.0
var sculpting := false
var brush_dir := 1.0
var brush_radius := 10.0
var u_time := 0.0
var year_label: Label
var sim_seed := 1337

func _ready() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("GDExtension 'SimNode' nicht geladen — .dylib/.gdextension prüfen.")
		return
	sim = ClassDB.instantiate("SimNode")
	add_child(sim)
	N = sim.gridSize()
	world_size = sim.worldSize()
	sea = sim.seaLevel()
	floor_level = sim.floorLevel()
	half = world_size / 2.0
	step = world_size / float(N - 1)
	cell_area = step * step

	_setup_scene()
	_setup_ui()
	if OS.has_environment("RS_STEP"): # für Screenshots: erodiertes Terrain zeigen
		var total := float(OS.get_environment("RS_STEP"))
		var done := 0.0
		while done < total: # in Schritten wie der Zeitraffer (repräsentativ)
			sim.step(1000.0)
			done += 1000.0
	sim.recomputeFlow()
	_pull_fields()
	_update_terrain_textures()
	if OS.has_environment("RS_DIAG"):
		_diag()

func _diag() -> void:
	var land := 0
	for k in h_cache.size():
		if h_cache[k] > sea + 0.012:
			land += 1
	print("DIAG verts=", h_cache.size(), " land=", land)
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
	e.tonemap_exposure = 0.82
	e.ssao_enabled = true
	e.ssao_intensity = 1.8 # kräftigere Ambient-Occlusion → Tiefe in den Rinnen
	e.glow_enabled = true
	e.glow_intensity = 0.2
	e.glow_bloom = 0.08
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.02 # kaum Sättigungs-Boost → kein Blaustich
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_DEPTH
	e.fog_light_color = Color(0.76, 0.78, 0.79)
	e.fog_density = 0.0006
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	# warmes, kräftiges Sonnenlicht dominiert das neutrale Ambient → naturalistischer Fels
	sun.light_color = Color(1.0, 0.96, 0.90)
	sun.light_energy = 1.85
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
	pm.subdivide_width = N - 2  # → N Vertices je Kante
	pm.subdivide_depth = N - 2
	terrain_mi.mesh = pm
	terrain_mi.extra_cull_margin = 1000.0 # Displacement sprengt die Plan-AABB
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("hscale", HSCALE)
	terrain_mat.set_shader_parameter("world_size", world_size)
	terrain_mat.set_shader_parameter("grid_n", float(N))
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
	# Größere Schrift für die ganze UI (war kaum lesbar).
	var ui_theme := Theme.new()
	ui_theme.default_font_size = 22
	panel.theme = ui_theme
	layer.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	year_label = Label.new()
	year_label.text = "Jahr 0"
	year_label.add_theme_font_size_override("font_size", 32) # Jahr prominent
	vb.add_child(year_label)

	var speeds := HBoxContainer.new()
	vb.add_child(speeds)
	for pair in [["Pause", 0.0], ["10 J/s", 10.0], ["30 J/s", 30.0], ["60 J/s", 60.0]]:
		var b := Button.new()
		b.text = pair[0]
		var rate: float = pair[1]
		b.pressed.connect(func(): year_rate = rate)
		speeds.add_child(b)

	var jumps := HBoxContainer.new()
	vb.add_child(jumps)
	for pair in [["+100 J.", 100.0], ["+1.000 J.", 1000.0], ["+10.000 J.", 10000.0]]:
		var b := Button.new()
		b.text = pair[0]
		var yrs: float = pair[1]
		b.pressed.connect(func(): _jump(yrs))
		jumps.add_child(b)

	var tools := HBoxContainer.new()
	vb.add_child(tools)
	var raise_b := Button.new()
	raise_b.text = "⛰ Anheben"
	raise_b.pressed.connect(func(): brush_dir = 1.0)
	tools.add_child(raise_b)
	var lower_b := Button.new()
	lower_b.text = "🕳 Absenken"
	lower_b.pressed.connect(func(): brush_dir = -1.0)
	tools.add_child(lower_b)
	var regen_b := Button.new()
	regen_b.text = "Neues Terrain"
	regen_b.pressed.connect(_regen)
	tools.add_child(regen_b)

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 16)
	hint.text = "Links: formen (Shift kehrt um) · Rechts: drehen\nZoom: +/− Tasten · Zwei-Finger-Wisch · Pinch"
	vb.add_child(hint)

# ---------------------------------------------------------------- Zeit

func _jump(years: float) -> void:
	sim.step(years)
	_after_sim()

func _regen() -> void:
	sim_seed = (sim_seed * 16807 + 1) % 2147483647
	sim.generate(sim_seed)
	sim.recomputeFlow()
	_after_sim()

func _after_sim() -> void:
	_pull_fields()
	_update_terrain_textures()
	_update_year()

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
		year_rate = 60.0
		_shot_frame += 1
		if _shot_frame > 60:
			_fps_accum += Engine.get_frames_per_second()
		if _shot_frame == 260:
			print("RS_FPS avg=", _fps_accum / 200.0)
			get_tree().quit()

	u_time += delta * (2.5 if year_rate > 0.0 else 0.7)
	if terrain_mat:
		terrain_mat.set_shader_parameter("u_time", u_time)

	if year_rate > 0.0:
		# Jahre/Frame deckeln: verhindert die Todesspirale (langsam → großer dt →
		# mehr Hangpässe → noch langsamer) und hält jeden Schritt billig.
		var years := minf(year_rate * delta, 240.0)
		sim.step(years)
		flow_timer += delta
		rebuild_timer += delta
		# Flüsse & Mesh gedrosselt neu aufbauen (nicht jeden Frame, wäre zu teuer).
		if rebuild_timer > 0.15:
			rebuild_timer = 0.0
			_pull_fields()
			_update_terrain_textures()
			_update_year()

	if sculpting:
		var hit := _raycast_terrain()
		if hit != Vector3.INF:
			var gx := (hit.x + half) / step
			var gz := (hit.z + half) / step
			var dir := brush_dir * (-1.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
			sim.sculpt(gx, gz, brush_radius, dir)
			sim.recomputeFlow()
			_pull_fields()
			_update_terrain_textures()

	_update_ring()
	_update_camera()

func _update_year() -> void:
	year_label.text = "Jahr %s" % _fmt(int(sim.currentYear()))

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
	# Nur was Rendering/Flüsse/Raycast braucht — Farben werden in Swift berechnet,
	# daher KEINE sed/rain/veg-Felder mehr über die FFI-Grenze ziehen.
	h_cache = sim.heights()      # Höhentextur + Raycast
	hf_cache = sim.filled()      # Seeflächen
	area_cache = sim.flowArea()  # Flussbreite/-schwelle
	recv_cache = sim.receivers() # Flussrichtung

func _cells_upstream(k: int) -> float:
	return area_cache[k] / cell_area

# ---------------------------------------------------------------- Terrain-Textur

## Lädt Höhen (R32F) und Farben (RGBA8) als Texturen hoch — GPU macht Displacement
## und Färbung. Pro Tick nur ein Upload statt kompletter Mesh-Rebuild.
func _update_terrain_textures() -> void:
	var hbytes := h_cache.to_byte_array() # PackedFloat32Array → rohe float32-Bytes
	if height_img == null:
		height_img = Image.create_from_data(N, N, false, Image.FORMAT_RF, hbytes)
		height_tex = ImageTexture.create_from_image(height_img)
		terrain_mat.set_shader_parameter("height_tex", height_tex)
	else:
		height_img.set_data(N, N, false, Image.FORMAT_RF, hbytes)
		height_tex.update(height_img)

	var cbytes: PackedByteArray = sim.terrainColorBytes()
	if color_img == null:
		color_img = Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, cbytes)
		color_tex = ImageTexture.create_from_image(color_img)
		terrain_mat.set_shader_parameter("color_tex", color_tex)
	else:
		color_img.set_data(N, N, false, Image.FORMAT_RGBA8, cbytes)
		color_tex.update(color_img)

	# Wasser-Feld (Flüsse/Seen/Altarme) als glattes Overlay-Textur.
	var wbytes: PackedByteArray = sim.waterFieldBytes()
	if water_img == null:
		water_img = Image.create_from_data(N, N, false, Image.FORMAT_RGBA8, wbytes)
		water_tex = ImageTexture.create_from_image(water_img)
		terrain_mat.set_shader_parameter("water_tex", water_tex)
	else:
		water_img.set_data(N, N, false, Image.FORMAT_RGBA8, wbytes)
		water_tex.update(water_img)


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
			MOUSE_BUTTON_RIGHT:
				orbiting = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				cam_dist = max(30.0, cam_dist - 8.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				cam_dist = min(400.0, cam_dist + 8.0)
	elif event is InputEventMouseMotion and orbiting:
		cam_yaw -= event.relative.x * 0.005
		cam_pitch = clamp(cam_pitch + event.relative.y * 0.005, 0.15, 1.5)
	# Zoom ohne Maus: Trackpad-Zwei-Finger-Wisch …
	elif event is InputEventPanGesture:
		cam_dist = clamp(cam_dist + event.delta.y * 6.0, 30.0, 400.0)
	# … Pinch-Geste …
	elif event is InputEventMagnifyGesture:
		cam_dist = clamp(cam_dist / event.factor, 30.0, 400.0)
	# … und +/− auf der Tastatur.
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				cam_dist = max(30.0, cam_dist - 12.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				cam_dist = min(400.0, cam_dist + 12.0)

func _update_ring() -> void:
	if sculpting or year_rate == 0.0:
		var hit := _raycast_terrain()
		if hit != Vector3.INF:
			ring_mi.visible = true
			ring_mi.position = hit + Vector3(0, 0.4, 0)
			ring_mi.scale = Vector3(brush_radius, 1.0, brush_radius)
			return
	ring_mi.visible = false

## Heightfield-Raymarch (three.js-Dreieckstest wäre bei 128² zu teuer).
func _raycast_terrain() -> Vector3:
	var mpos := get_viewport().get_mouse_position()
	var ro := cam.project_ray_origin(mpos)
	var rd := cam.project_ray_normal(mpos)
	var prev_t := 0.0
	var t := 0.8
	while t < 600.0:
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
