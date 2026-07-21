extends Node3D
## river-sim — Godot-Frontend (M2).
## Der Simulationskern (Erosion/Flüsse/Tektonik) lebt in der GDExtension `SimNode`
## (Swift/SimCore, headless getestet). Dieses Skript macht nur Rendering, Kamera,
## Eingabe und Zeitsteuerung — die Physik-Logik wird NICHT hier dupliziert.

const HSCALE := 26.0          # Höhen-Skalierung fürs Mesh (h ist normiert)
const LAKE_EPS := 0.015
const RIVER_MIN_CELLS := 40.0 # ab so vielen Oberlieger-Zellen ein sichtbarer Fluss
const CREEK_MIN_CELLS := 15.0 # kleinere Bäche nur als Tönung
const RIVER_LIFT := 0.32

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
var river_mi: MeshInstance3D
var ring_mi: MeshInstance3D
var terrain_mesh := ArrayMesh.new()
var river_mesh := ArrayMesh.new()
var river_mat: ShaderMaterial

# gecachte Felder (nach jedem Rebuild aktualisiert)
var h_cache: PackedFloat32Array
var hf_cache: PackedFloat32Array
var sed_cache: PackedFloat32Array
var rain_cache: PackedFloat32Array
var veg_cache: PackedFloat32Array
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

# Höhen-Farbverlauf (Schwelle, Color) — portiert aus dem Prototyp
var stops := []

func _ready() -> void:
	stops = [
		[-0.3, Color(0.02, 0.07, 0.20)],
		[0.00, Color(0.08, 0.22, 0.45)],
		[0.15, Color(0.20, 0.42, 0.60)],
		[0.17, Color(0.76, 0.70, 0.50)],
		[0.28, Color(0.25, 0.48, 0.22)],
		[0.45, Color(0.16, 0.34, 0.16)],
		[0.58, Color(0.42, 0.38, 0.34)],
		[0.70, Color(0.55, 0.53, 0.51)],
		[0.80, Color(0.95, 0.96, 0.98)],
	]
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
	sim.recomputeFlow()
	_pull_fields()
	_rebuild_terrain()
	_rebuild_rivers()

# ---------------------------------------------------------------- Szene / UI

func _setup_scene() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.043, 0.055, 0.078)
	e.ambient_light_color = Color(0.75, 0.83, 1.0)
	e.ambient_light_energy = 0.45
	e.fog_enabled = true
	e.fog_light_color = Color(0.043, 0.055, 0.078)
	e.fog_density = 0.0015
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.95, 0.87)
	sun.light_energy = 1.6
	sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(-35), 0)
	sun.shadow_enabled = true
	add_child(sun)

	cam = Camera3D.new()
	cam.far = 1000.0
	cam.fov = 55.0
	add_child(cam)
	_update_camera()

	terrain_mi = MeshInstance3D.new()
	terrain_mi.mesh = terrain_mesh
	var tmat := StandardMaterial3D.new()
	tmat.vertex_color_use_as_albedo = true
	tmat.roughness = 0.95
	tmat.metallic = 0.0
	tmat.cull_mode = BaseMaterial3D.CULL_DISABLED # Heightfield: Wicklung egal
	terrain_mi.material_override = tmat
	add_child(terrain_mi)

	water_mi = MeshInstance3D.new()
	var wp := PlaneMesh.new()
	wp.size = Vector2(world_size * 1.02, world_size * 1.02)
	water_mi.mesh = wp
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.11, 0.30, 0.54, 0.55)
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.roughness = 0.15
	water_mi.material_override = wmat
	water_mi.position.y = sea * HSCALE
	add_child(water_mi)

	river_mi = MeshInstance3D.new()
	river_mi.mesh = river_mesh
	river_mat = ShaderMaterial.new()
	river_mat.shader = load("res://shaders/water.gdshader")
	river_mi.material_override = river_mat
	river_mi.extra_cull_margin = 16384.0 # Geometrie wird laufend neu gebaut
	add_child(river_mi)

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
	panel.position = Vector2(12, 12)
	layer.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	year_label = Label.new()
	year_label.text = "Jahr 0"
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
	hint.text = "Links: formen (Shift kehrt um) · Rechts: drehen · Rad: Zoom"
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
	_rebuild_terrain()
	_rebuild_rivers()
	_update_year()

func _process(delta: float) -> void:
	u_time += delta * (2.5 if year_rate > 0.0 else 0.7)
	if river_mat:
		river_mat.set_shader_parameter("u_time", u_time)

	if year_rate > 0.0:
		var years := year_rate * delta
		sim.step(years)
		flow_timer += delta
		rebuild_timer += delta
		# Flüsse & Mesh gedrosselt neu aufbauen (nicht jeden Frame, wäre zu teuer).
		if rebuild_timer > 0.2:
			rebuild_timer = 0.0
			_pull_fields()
			_rebuild_terrain()
			_rebuild_rivers()
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
			_rebuild_terrain()
			_rebuild_rivers()

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
	h_cache = sim.heights()
	hf_cache = sim.filled()
	sed_cache = sim.sediment()
	rain_cache = sim.rainField()
	veg_cache = sim.vegetation()
	area_cache = sim.flowArea()
	recv_cache = sim.receivers()

func _cells_upstream(k: int) -> float:
	return area_cache[k] / cell_area

# ---------------------------------------------------------------- Terrain-Mesh

func _rebuild_terrain() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(N * N)
	normals.resize(N * N)
	colors.resize(N * N)

	for j in N:
		for i in N:
			var k := j * N + i
			var y: float = h_cache[k] * HSCALE
			verts[k] = Vector3(-half + i * step, y, -half + j * step)
			normals[k] = _terrain_normal(i, j)
			colors[k] = _terrain_color(i, j, k)

	for j in (N - 1):
		for i in (N - 1):
			var a := j * N + i
			indices.append(a)
			indices.append(a + N)
			indices.append(a + 1)
			indices.append(a + 1)
			indices.append(a + N)
			indices.append(a + N + 1)

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	terrain_mesh.clear_surfaces()
	terrain_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

func _terrain_normal(i: int, j: int) -> Vector3:
	var l := maxi(i - 1, 0)
	var r := mini(i + 1, N - 1)
	var d := maxi(j - 1, 0)
	var u := mini(j + 1, N - 1)
	var dhx: float = (h_cache[j * N + r] - h_cache[j * N + l]) * HSCALE
	var dhz: float = (h_cache[u * N + i] - h_cache[d * N + i]) * HSCALE
	return Vector3(-dhx, 2.0 * step, -dhz).normalized()

func _grad_color(v: float) -> Color:
	for k in range(stops.size() - 1):
		if v <= stops[k + 1][0]:
			var a: float = stops[k][0]
			var b: float = stops[k + 1][0]
			var t: float = clamp((v - a) / (b - a), 0.0, 1.0)
			return (stops[k][1] as Color).lerp(stops[k + 1][1] as Color, t)
	return stops[stops.size() - 1][1]

func _terrain_color(i: int, j: int, k: int) -> Color:
	var v: float = h_cache[k]
	if v <= sea + 0.012:
		return _grad_color(v)
	# Biome: Steppe → Gras (Feuchte) → Wald (Vegetation), Fels nach Hang/Sediment.
	var c := Color(0.66, 0.58, 0.40)
	c = c.lerp(Color(0.36, 0.54, 0.26), clamp(rain_cache[k], 0.0, 1.0))
	c = c.lerp(Color(0.11, 0.30, 0.13), veg_cache[k] * 0.85)
	var rocky: float = 0.55 if sed_cache[k] < 0.004 else 0.0
	if i > 0 and i < N - 1 and j > 0 and j < N - 1:
		var slope: float = (abs(h_cache[k + 1] - h_cache[k - 1]) + abs(h_cache[k + N] - h_cache[k - N])) * 0.25
		rocky = max(rocky, clamp(slope * 70.0 - 0.55, 0.0, 0.85))
	c = c.lerp(Color(0.47, 0.45, 0.43), max(0.0, rocky))
	if v > 0.60:
		c = c.lerp(Color(0.95, 0.96, 0.98), clamp((v - 0.60) / 0.08, 0.0, 1.0))
	var cu := _cells_upstream(k)
	if cu >= CREEK_MIN_CELLS:
		var t: float = clamp(log(cu / CREEK_MIN_CELLS + 1.0) / 2.5, 0.0, 1.0) * 0.85
		c = c.lerp(Color(0.10, 0.32, 0.58), t)
	return c

# ---------------------------------------------------------------- Fluss-Mesh

func _sample_hf(gx: float, gz: float) -> float:
	var xi := clampi(int(floor(gx)), 0, N - 2)
	var yi := clampi(int(floor(gz)), 0, N - 2)
	var fx := clampf(gx - xi, 0.0, 1.0)
	var fy := clampf(gz - yi, 0.0, 1.0)
	var i00 := yi * N + xi
	return hf_cache[i00] * (1 - fx) * (1 - fy) + hf_cache[i00 + 1] * fx * (1 - fy) \
		+ hf_cache[i00 + N] * (1 - fx) * fy + hf_cache[i00 + N + 1] * fx * fy

func _river_half_width(cells: float) -> float:
	return min(0.9 + 0.9 * log(cells / RIVER_MIN_CELLS + 1.0), 4.4)

func _rebuild_rivers() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Flusssegmente: Band vom Zellzentrum zum Abfluss-Nachbarn.
	for c in N * N:
		if hf_cache[c] <= sea:
			continue
		if _cells_upstream(c) < RIVER_MIN_CELLS:
			continue
		if hf_cache[c] - h_cache[c] > LAKE_EPS:
			continue # tief im See → dort liegt die Seefläche
		var d := recv_cache[c]
		if d < 0:
			continue
		if hf_cache[d] - h_cache[d] > LAKE_EPS:
			continue
		var ci := c % N
		var cj := c / N
		var di := d % N
		var dj := d / N
		var dirx := float(di - ci)
		var dirz := float(dj - cj)
		var dl := sqrt(dirx * dirx + dirz * dirz)
		if dl < 1e-6:
			continue
		dirx /= dl
		dirz /= dl
		var px := -dirz
		var pz := dirx
		var w0 := _river_half_width(_cells_upstream(c))
		var w1 := _river_half_width(_cells_upstream(d))
		var wm := (w0 + w1) * 0.5
		var sx := ci - dirx * 0.35
		var sz := cj - dirz * 0.35
		var ex := di + dirx * 0.35
		var ez := dj + dirz * 0.35
		var mx := (sx + ex) * 0.5
		var mz := (sz + ez) * 0.5
		_push_quad(verts, colors, indices, sx, sz, w0, mx, mz, wm, px, pz, dirx, dirz)
		_push_quad(verts, colors, indices, mx, mz, wm, ex, ez, w1, px, pz, dirx, dirz)

	# Seeflächen: flache Quads auf Füllhöhe.
	for k in N * N:
		if hf_cache[k] - h_cache[k] <= LAKE_EPS or hf_cache[k] <= sea:
			continue
		var ci := k % N
		var cj := k / N
		var y: float = hf_cache[k] * HSCALE + 0.06
		var base := verts.size()
		for off in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)]:
			verts.append(Vector3(-half + (ci + off.x) * step, y, -half + (cj + off.y) * step))
			colors.append(Color(0.5, 0.5, 1.0)) # dir=(0,0) → See kräuselt
		indices.append(base); indices.append(base + 2); indices.append(base + 1)
		indices.append(base + 1); indices.append(base + 2); indices.append(base + 3)

	river_mesh.clear_surfaces()
	if verts.size() == 0:
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_INDEX] = indices
	river_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

func _push_quad(verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array,
		ax: float, az: float, aw: float, bx: float, bz: float, bw: float,
		px: float, pz: float, dx: float, dz: float) -> void:
	var base := verts.size()
	var col := Color(dx * 0.5 + 0.5, dz * 0.5 + 0.5, 1.0) # Fließrichtung kodiert
	for p in [
		Vector2(ax - px * aw, az - pz * aw), Vector2(ax + px * aw, az + pz * aw),
		Vector2(bx - px * bw, bz - pz * bw), Vector2(bx + px * bw, bz + pz * bw),
	]:
		verts.append(Vector3(-half + p.x * step, _sample_hf(p.x, p.y) * HSCALE + RIVER_LIFT, -half + p.y * step))
		colors.append(col)
	indices.append(base); indices.append(base + 2); indices.append(base + 1)
	indices.append(base + 1); indices.append(base + 2); indices.append(base + 3)

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
