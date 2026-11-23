extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const SHADERS := ["res://shaders/relief_bake.gdshader", "res://shaders/terrain.gdshader"]
const LIFT := 1.0

const RAY_DIR := Vector3(0.45, -1.0, 0.3)
class FixedRayMain extends "res://scripts/Main.gd":
	var ray_xz := Vector2.ZERO
	var ray_y := 0.0
	func _raycast_terrain() -> Vector3:
		var d := RAY_DIR.normalized()
		return _raycast_surface(Vector3(ray_xz.x, ray_y, ray_xz.y) - d * 120.0, d)

var failures := 0
var main: Node
var done := false

func _initialize() -> void:
	if not ClassDB.class_exists("SimNode"):
		print("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var probe: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(probe):
		quit(1)
		return
	_check_shaders(probe)
	probe.free()
	main = FixedRayMain.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if done or main == null or not main.is_node_ready():
		return false
	done = true
	_check_bake_cadence(main)
	_check_visible_surface(main)
	_check_stroke_never_waits(main)
	_check_regen_does_not_fade(main)
	main.queue_free()
	if failures > 0:
		quit(1)
		return true
	print("RELIEF_OK")
	quit(0)
	return true

func _check_stroke_never_waits(main: Node) -> void:
	main.year_rate = 0.0
	main._settle_sim()
	var year: float = main.shown_year
	var waited: float = main.sim.stepWaitMilliseconds()
	main.sim.beginStep(15.0, main.FRAME_TIMELAPSE, main._now())
	main.sculpting = true
	main.last_activity_msec = Time.get_ticks_msec()
	main._process(0.05)
	_check(main.sim.stepWaitMilliseconds() == waited,
		"Der Pinsel wartet nicht auf den Hintergrund-Schritt")
	while main.sim.stepInFlight() and not main.sim.stepReady():
		OS.delay_msec(1)
	main._process(0.05)
	main.sculpting = false
	_check(main.shown_year == year + 15.0 and not main.sim.stepInFlight(),
		"Der Schritt ist abgeholt, bevor der Strich weitermalt (Jahr %s → %s)"
			% [year, main.shown_year])
	_check(main.sim.stepWaitMilliseconds() == waited, "Auch das Abholen wartet nicht")

func _check_regen_does_not_fade(main: Node) -> void:
	main.year_rate = 60.0
	main._regen()
	main.year_rate = 0.0
	_check(main.height_fade.mix == 1.0 and main.overlay_fade.mix == 1.0
		and main.relief_mix == 1.0 and main.ribbon_fade.mix == 1.0
		and not main.river_prev_mi.visible, "Neugenerieren im Zeitraffer blendet nicht")

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _check_shaders(sim: Object) -> void:
	var calib: Dictionary = Main.calibration(sim, "relief")
	_check(not calib.is_empty(), "Brücke liefert die Relief-Tabelle")
	var decl_re := RegEx.new()
	decl_re.compile("(?m)^uniform\\s+float\\s+(relief_[A-Za-z0-9_]+)([^;]*);")
	var declared_anywhere := {}
	for path in SHADERS:
		var shader: Shader = load(path)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		_check(not shader.get_shader_uniform_list().is_empty(), "%s muss kompilieren" % path)
		for name in calib:
			mat.set_shader_parameter(name, calib[name])
		for m in decl_re.search_all(FileAccess.get_file_as_string(path)):
			var name := m.get_string(1)
			declared_anywhere[name] = true
			_check(calib.has(name), "%s deklariert %s an der Brücke vorbei" % [path, name])
			_check(m.get_string(2).find("=") < 0, "%s: %s trägt einen Literal-Default" % [path, name])
			var got: Variant = mat.get_shader_parameter(name)
			_check(got != null and absf(float(got) - float(calib.get(name, 0.0))) < 1e-6,
				"%s: %s nicht gesetzt" % [path, name])
	for name in calib:
		_check(declared_anywhere.has(name), "Brückenwert %s wird von keinem Shader gelesen" % name)

func _check_bake_cadence(main: Node) -> void:
	_check(main.relief_bakes > 0, "Der Aufbau backt die erste Verschiebung")
	_check(main.terrain_mat.get_shader_parameter("relief_enabled") == true,
		"Terrain-Material liest die Verschiebung")
	var before: int = main.relief_bakes
	main.year_rate = 0.0
	for i in 40:
		main.last_activity_msec = Time.get_ticks_msec()
		main._process(0.02)
	_check(main.relief_bakes == before, "Standbild darf nicht neu backen (%d → %d)"
		% [before, main.relief_bakes])
	var year_before: float = main.shown_year
	main.year_rate = 60.0
	var ticks := 0
	var faded := false
	var height_faded := false
	var overlay_faded := false
	for i in 40:
		var y: float = main.shown_year
		main._process(0.02)
		if main.shown_year != y:
			ticks += 1
		faded = faded or main.relief_mix < 1.0
		height_faded = height_faded or main.height_fade.mix < 1.0
		overlay_faded = overlay_faded or main.overlay_fade.mix < 1.0
		while main.sim.stepInFlight() and not main.sim.stepReady():
			OS.delay_msec(1)
	var y_last: float = main.shown_year
	main._settle_sim()
	if main.shown_year != y_last:
		ticks += 1
	main._frame_trigger = main.FRAME_TIMELAPSE
	main._apply_frame(main.sim.renderFrame(main.FRAME_SETTLED, main._now()))
	main._frame_trigger = main.FRAME_SETTLED
	overlay_faded = overlay_faded or main.overlay_fade.mix < 1.0
	main._frame_trigger = main.FRAME_TIMELAPSE
	main._apply_frame({"ribbons": true})
	main._frame_trigger = main.FRAME_SETTLED
	_check(main.ribbon_fade.mix == 0.0 and main.river_prev_mi.visible,
		"Band-Bau im Zeitraffer blendet über, der alte Stand bleibt sichtbar")
	main.year_rate = 0.0
	_check(faded, "Zeitraffer blendet die Verschiebung über, statt zu springen")
	_check(height_faded, "Zeitraffer blendet die Höhe über")
	_check(overlay_faded, "Zeitraffer blendet Farbe, Material und Wald über")
	for i in 20:
		main.last_activity_msec = Time.get_ticks_msec()
		main._process(0.02)
	_check(main.relief_mix == 1.0 and main.terrain_mat.get_shader_parameter("bake_blend") == 1.0,
		"Blende endet nach einem Sim-Takt auf dem neuen Stand")
	for param in ["height_blend", "overlay_blend"]:
		_check(main.terrain_mat.get_shader_parameter(param) == 1.0,
			"%s endet auf dem neuen Stand" % param)
	_check(main.ocean_mat.get_shader_parameter("height_blend") == 1.0,
		"Das Meer blendet die Höhe mit dem Terrain")
	for i in 40:
		main.last_activity_msec = Time.get_ticks_msec()
		main._process(0.02)
	_check(main.ribbon_fade.mix == 1.0 and not main.river_prev_mi.visible
		and main.river_mat.get_shader_parameter("ribbon_blend") == 1.0,
		"Band-Blende endet auf dem neuen Stand, der alte verschwindet")
	var bakes: int = main.relief_bakes - before
	_check(ticks > 0 and main.shown_year > year_before, "Zeitraffer muss Sim-Schritte machen")
	_check(bakes >= ticks and bakes <= 2 * ticks,
		"Je Sim-Schritt ein Back-Pass (Schritte %d, Back-Pässe %d)" % [ticks, bakes])

func _check_visible_surface(main: Node) -> void:
	main.forest_img = null
	var code: float = main.relief_height_code
	_check(code > 0.0, "Höhen-Code der Backtextur kommt über die Brücke")
	var field := PackedFloat32Array()
	field.resize(main.N * main.N)
	field.fill(0.5 + LIFT * code)
	main.relief_lift_cache = field
	main.relief_bake_frame = -1

	var h: PackedFloat32Array = main.sim.heights()
	var n: int = main.N
	var cell := -1
	for j in range(n / 3, 2 * n / 3):
		for i in range(n / 3, 2 * n / 3):
			if h[j * n + i] > main.sea + 0.1:
				cell = j * n + i
				break
		if cell >= 0:
			break
	_check(cell >= 0, "Testwelt braucht Land in der Mitte")
	if cell < 0:
		return
	var ci := cell % n
	var cj := cell / n
	var x: float = ci * main.step - main.half
	var z: float = cj * main.step - main.half
	var sim_y: float = h[cell] * main.hscale
	main.ray_xz = Vector2(x, z)
	main.ray_y = sim_y

	var year: float = main.sim.currentYear()
	_check(main.relief_geometry_age > 0.0 and year < 0.05 * main.relief_geometry_age,
		"Testwelt ist jung (Jahr %.0f, volle Verformung ab %.0f)" % [year, main.relief_geometry_age])
	_check(main.terrain_mat.get_shader_parameter("sim_year") == year,
		"Terrain-Material kennt das Geländealter")
	var young: Vector3 = main._raycast_terrain()
	_check(young != Vector3.INF and absf(young.y - main._sample_h((young.x + main.half) / main.step,
		(young.z + main.half) / main.step) * main.hscale) < 0.05,
		"Junge Welt: Treffer auf der Sim-Höhe, nicht auf der Verformung")
	main.relief_geometry_age = 1e-3

	var hit: Vector3 = main._raycast_terrain()
	_check(hit != Vector3.INF, "Strahl muss das Gelände treffen")
	if hit == Vector3.INF:
		return
	var hit_gx: float = (hit.x + main.half) / main.step
	var hit_gz: float = (hit.z + main.half) / main.step
	var hit_sim_y: float = main._sample_h(hit_gx, hit_gz) * main.hscale
	_check(absf(hit.y - (hit_sim_y + LIFT)) < 0.05,
		"Treffer auf der sichtbaren Fläche: y %.3f, erwartet %.3f (Sim %.3f)"
		% [hit.y, hit_sim_y + LIFT, hit_sim_y])
	main.relief_lift_cache = PackedFloat32Array()
	var bare: Vector3 = main._raycast_terrain()
	main.relief_lift_cache = field
	_check(Vector2(bare.x - hit.x, bare.z - hit.z).length() > main.step,
		"Schräger Strahl muss die Verschiebung sehen (Treffer ohne/mit %s / %s)" % [bare, hit])
	var hit_cell := roundi(hit_gz) * n + roundi(hit_gx)

	main.last_activity_msec = Time.get_ticks_msec()
	main._process(0.02)
	_check(main.brush_mi.visible, "Pinselkuppel sichtbar im Standbild")
	_check(absf(main.brush_mi.position.y - hit.y) < 0.05,
		"Pinselkuppel sitzt auf der sichtbaren Fläche (y %.3f)" % main.brush_mi.position.y)
	var rim: Vector3 = main.brush_dome(hit, 1.0, Main.BRUSH_FALLOFF_POWER)[0][0] + hit
	var rim_sim_y: float = main._sample_h((rim.x + main.half) / main.step,
		(rim.z + main.half) / main.step) * main.hscale
	_check(absf(rim.y - (rim_sim_y + LIFT + Main.BRUSH_DOME_LIFT)) < 0.05,
		"Kuppelrand liegt auf der verschobenen Fläche (y %.3f, Sim %.3f)" % [rim.y, rim_sim_y])

	main.cam_target = Vector3(x, 0.0, z)
	main.cam_target_on_surface = true
	main._process(0.02)
	_check(not main.cam_target_on_surface and absf(main.cam_target.y - (sim_y + LIFT)) < 0.05,
		"Kameraziel liegt auf der sichtbaren Fläche (y %.3f)" % main.cam_target.y)

	var far := ((roundi(hit_gz) + n / 2) % n) * n + roundi(hit_gx)
	var h_far: float = h[far]
	main.current_tool = 0
	main.sculpting = true
	main.year_rate = 60.0
	main._process(0.05)
	main.year_rate = 0.0
	_check(main.relief_mix == 1.0, "Pinsel backt ohne Blende")
	_check(main.height_fade.mix == 1.0, "Pinsel zeigt die neue Höhe sofort (#172)")
	main.sculpting = false
	var after: PackedFloat32Array = main.sim.heights()
	_check(after[hit_cell] > h[hit_cell], "Pinsel hebt die Sim-Zelle unter dem Treffer (%.5f → %.5f)"
		% [h[hit_cell], after[hit_cell]])
	_check(after[far] == h_far, "Pinsel lässt entfernte Zellen unberührt")
