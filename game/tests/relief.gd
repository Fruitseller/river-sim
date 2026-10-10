extends SceneTree
## Headless-Wächter der Render-Verschiebung von Rinnen und Graten (#153):
##   godot --headless --path game --script res://tests/relief.gd
##
## Geprüft wird das äußere Verhalten an den Vertragsgrenzen, nicht das Muster:
##  - Back-Pass und Terrain-Shader kompilieren; jede `relief_*`-Zahl kommt über
##    die Brücke (SimCore.ReliefRender), ist default-frei deklariert und wird
##    auf beiden Materialien gesetzt;
##  - Main backt die Verschiebung nur bei Terrain-Updates: im Standbild nie,
##    im Zeitraffer mit jedem Sim-Schritt und dort weich übergeblendet, beim
##    Pinsel sofort;
##  - Pinselring und Kameraziel liegen auf der SICHTBAREN Fläche (Sim-Höhe plus
##    Verschiebung), der Pinsel ändert die Sim-Zelle unter dem Treffer.
## Der Dummy-Renderer zeichnet den Back-Pass nicht; für die Flächen-Prüfung
## bekommt Main deshalb eine bekannte Verschiebung (+1 Einheit) gesetzt.
## Erzeugt einen `SimNode` samt Produktionswelt (Laufzeit wie `smoke.gd`).

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const SHADERS := ["res://shaders/relief_bake.gdshader", "res://shaders/terrain.gdshader"]
const LIFT := 1.0  # gesetzte Verschiebung in Welteinheiten

## Main mit festem, SCHRÄGEM Zeigerstrahl auf `ray_xz`: senkrecht fiele der
## Treffer mit und ohne Verschiebung auf dieselbe Zelle, schräg nicht. Alles
## andere (Raymarch, Ring, Pinsel) ist der echte Produktionspfad.
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
	root.add_child(main) # _ready im ersten Frame: Welt, Szene, erster Back-Auftrag

func _process(_delta: float) -> bool:
	if done or main == null or not main.is_node_ready():
		return false
	done = true
	_check_bake_cadence(main)
	_check_visible_surface(main)
	main.queue_free()
	if failures > 0:
		quit(1)
		return true
	print("RELIEF_OK")
	quit(0)
	return true

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _check_shaders(sim: Object) -> void:
	var calib: Dictionary = Main.relief_calibration(sim)
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

## Standbild ohne Terrain-Update backt nicht; jeder Sim-Schritt im Zeitraffer
## backt (Höhen-Upload), höchstens doppelt (zusätzlich ein Band-Bau).
func _check_bake_cadence(main: Node) -> void:
	_check(main.relief_bakes > 0, "Der Aufbau backt die erste Verschiebung")
	_check(main.terrain_mat.get_shader_parameter("relief_enabled") == true,
		"Terrain-Material liest die Verschiebung")
	var before: int = main.relief_bakes
	main.year_rate = 0.0
	for i in 40:
		main.last_activity_msec = Time.get_ticks_msec() # kein Leerlauf-Abkürzen
		main._process(0.02)
	_check(main.relief_bakes == before, "Standbild darf nicht neu backen (%d → %d)"
		% [before, main.relief_bakes])
	var year_before: float = main.sim.currentYear()
	main.year_rate = 60.0
	var ticks := 0
	var faded := false
	for i in 40:
		var y: float = main.sim.currentYear()
		main._process(0.02)
		if main.sim.currentYear() != y:
			ticks += 1
		faded = faded or main.relief_mix < 1.0
	main.year_rate = 0.0
	_check(faded, "Zeitraffer blendet die Verschiebung über, statt zu springen")
	for i in 20:
		main.last_activity_msec = Time.get_ticks_msec()
		main._process(0.02)
	_check(main.relief_mix == 1.0 and main.terrain_mat.get_shader_parameter("bake_blend") == 1.0,
		"Blende endet nach einem Sim-Takt auf dem neuen Stand")
	var bakes: int = main.relief_bakes - before
	_check(ticks > 0 and main.sim.currentYear() > year_before, "Zeitraffer muss Sim-Schritte machen")
	_check(bakes >= ticks and bakes <= 2 * ticks,
		"Je Sim-Schritt ein Back-Pass (Schritte %d, Back-Pässe %d)" % [ticks, bakes])

func _check_visible_surface(main: Node) -> void:
	# Bekannte Verschiebung statt des (headless nicht gezeichneten) Back-Passes.
	var code: float = main.relief_height_code
	_check(code > 0.0, "Höhen-Code der Backtextur kommt über die Brücke")
	var field := PackedFloat32Array()
	field.resize(main.N * main.N)
	field.fill(0.5 + LIFT * code)
	main.relief_lift_cache = field
	main.relief_bake_frame = -1

	# Trockene Landzelle mit Abstand zum Rand.
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
	var sim_y: float = h[cell] * Main.HSCALE
	main.ray_xz = Vector2(x, z)
	main.ray_y = sim_y

	var hit: Vector3 = main._raycast_terrain()
	_check(hit != Vector3.INF, "Strahl muss das Gelände treffen")
	if hit == Vector3.INF:
		return
	var hit_gx: float = (hit.x + main.half) / main.step
	var hit_gz: float = (hit.z + main.half) / main.step
	var hit_sim_y: float = main._sample_h(hit_gx, hit_gz) * Main.HSCALE
	_check(absf(hit.y - (hit_sim_y + LIFT)) < 0.05,
		"Treffer auf der sichtbaren Fläche: y %.3f, erwartet %.3f (Sim %.3f)"
		% [hit.y, hit_sim_y + LIFT, hit_sim_y])
	# Gegenprobe ohne Verschiebung: der schräge Strahl trifft dann woanders.
	main.relief_lift_cache = PackedFloat32Array()
	var bare: Vector3 = main._raycast_terrain()
	main.relief_lift_cache = field
	_check(Vector2(bare.x - hit.x, bare.z - hit.z).length() > main.step,
		"Schräger Strahl muss die Verschiebung sehen (Treffer ohne/mit %s / %s)" % [bare, hit])
	var hit_cell := roundi(hit_gz) * n + roundi(hit_gx)

	# Pinselring folgt dem Treffer (Standbild, kein Strich).
	main.last_activity_msec = Time.get_ticks_msec()
	main._process(0.02)
	_check(main.ring_mi.visible, "Pinselring sichtbar im Standbild")
	_check(absf(main.ring_mi.position.y - (hit.y + 0.4)) < 0.05,
		"Pinselring liegt auf der sichtbaren Fläche (y %.3f)" % main.ring_mi.position.y)

	# Kameraziel (RS_TARGET-Pfad) auf der sichtbaren Fläche.
	main.cam_target = Vector3(x, 0.0, z)
	main.cam_target_on_surface = true
	main._process(0.02)
	_check(not main.cam_target_on_surface and absf(main.cam_target.y - (sim_y + LIFT)) < 0.05,
		"Kameraziel liegt auf der sichtbaren Fläche (y %.3f)" % main.cam_target.y)

	# Der Pinsel (Anheben) wirkt auf die Sim-Zelle unter dem Treffer.
	var far := ((roundi(hit_gz) + n / 2) % n) * n + roundi(hit_gx)  # weit außerhalb jedes Pinselradius
	var h_far: float = h[far]
	main.current_tool = 0
	main.sculpting = true
	main.year_rate = 60.0  # auch bei laufendem Zeitraffer: der Strich blendet nicht
	main._process(0.05)
	main.year_rate = 0.0
	_check(main.relief_mix == 1.0, "Pinsel backt ohne Blende")
	main.sculpting = false
	var after: PackedFloat32Array = main.sim.heights()
	_check(after[hit_cell] > h[hit_cell], "Pinsel hebt die Sim-Zelle unter dem Treffer (%.5f → %.5f)"
		% [h[hit_cell], after[hit_cell]])
	_check(after[far] == h_far, "Pinsel lässt entfernte Zellen unberührt")
