extends SceneTree
## Headless-Wächter des Kronendachs (#152):
##   godot --headless --path game --script res://tests/canopy.gd
##
## Wo Wald steht, ist headless in SimCoreTests/CanopyTests.swift gepinnt; hier
## zählt der Weg durch Brücke, Main und Shader:
##  - jede `canopy_*`-Zahl kommt über die Brücke (SimCore.CanopyRender), ist im
##    Terrain-Shader default-frei deklariert und auf dem Material gesetzt;
##  - die Waldmaske liegt als Textur am Material und folgt dem Neugenerieren;
##  - es gibt keine Instanzbäume mehr;
##  - Pinselring und Kameraziel liegen auf dem Dach (sichtbare Fläche).
## Erzeugt einen `SimNode` samt Produktionswelt (Laufzeit wie `smoke.gd`).

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const SHADER := "res://shaders/terrain.gdshader"

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
	probe.free()
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if done or main == null or not main.is_node_ready():
		return false
	done = true
	_check_uniforms(main)
	_check_no_instance_trees(main)
	_check_visible_surface(main)
	_check_regenerate(main)
	main.queue_free()
	if failures > 0:
		quit(1)
		return true
	print("CANOPY_OK")
	quit(0)
	return true

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _check_uniforms(main: Node) -> void:
	var calib: Dictionary = Main.canopy_calibration(main.sim)
	_check(not calib.is_empty(), "Brücke liefert die Kronen-Tabelle")
	var mat: ShaderMaterial = main.terrain_mat
	_check(not mat.shader.get_shader_uniform_list().is_empty(), "Terrain-Shader muss kompilieren")
	var decl_re := RegEx.new()
	decl_re.compile("(?m)^uniform\\s+float\\s+(canopy_[A-Za-z0-9_]+)([^;]*);")
	var declared := {}
	for m in decl_re.search_all(FileAccess.get_file_as_string(SHADER)):
		var name := m.get_string(1)
		declared[name] = true
		_check(calib.has(name), "Terrain-Shader deklariert %s an der Brücke vorbei" % name)
		_check(m.get_string(2).find("=") < 0, "%s trägt einen Literal-Default" % name)
		var got: Variant = mat.get_shader_parameter(name)
		_check(got != null and absf(float(got) - float(calib.get(name, 0.0))) < 1e-6,
			"%s nicht gesetzt" % name)
	for name in calib:
		_check(declared.has(name), "Brückenwert %s wird vom Terrain-Shader nicht gelesen" % name)
	_check(mat.get_shader_parameter("canopy_enabled") == true, "Kronendach ist an")
	var tex: Texture2D = mat.get_shader_parameter("forest_tex")
	_check(tex != null and tex.get_width() == main.N and tex.get_height() == main.N,
		"Waldmaske liegt in Gittergröße am Material")

func _check_no_instance_trees(main: Node) -> void:
	for child in main.get_children():
		_check(not (child is MultiMeshInstance3D), "Instanzbäume sind durch das Kronendach ersetzt")

## Pinselring und Kameraziel liegen auf dem Dach: Sim-Höhe plus Dachhöhe an
## einer Zelle mit geschlossenem Wald (ohne Verschiebung, die prüft relief.gd).
func _check_visible_surface(main: Node) -> void:
	main.relief_lift_cache = PackedFloat32Array()
	main.relief_bake_frame = -1
	var forest: PackedByteArray = main.sim.forestMaskBytes()
	var n: int = main.N
	var cell := -1
	for j in range(2, n - 2):
		for i in range(2, n - 2):
			var full := true
			for k in [j * n + i, j * n + i + 1, (j + 1) * n + i, (j + 1) * n + i + 1]:
				full = full and forest[k] == 255
			if full:
				cell = j * n + i
				break
		if cell >= 0:
			break
	_check(cell >= 0, "Produktionswelt braucht geschlossenen Wald")
	if cell < 0:
		return
	var gx := float(cell % n) + 0.5
	var gz := float(cell / n) + 0.5
	var sim_y: float = main._sample_h(gx, gz) * Main.HSCALE
	var height: float = main.canopy_calib["canopy_height"]
	_check(absf(main._surface_y(gx, gz) - (sim_y + height)) < 1e-4,
		"Sichtbare Fläche liegt auf dem Dach (%.3f, Sim %.3f)" % [main._surface_y(gx, gz), sim_y])
	main.cam_target = Vector3(gx * main.step - main.half, 0.0, gz * main.step - main.half)
	main.cam_target.y = main._surface_y_at(main.cam_target)
	_check(absf(main.cam_target.y - (sim_y + height)) < 1e-4, "Kameraziel liegt auf dem Dach")

## Der Dummy-Renderer liest Texturen nicht zurück; geprüft wird das Bild, das
## Main zuletzt hochgeladen hat, und dass die Textur dieselbe bleibt.
func _check_regenerate(main: Node) -> void:
	var tex: Texture2D = main.forest_tex
	var before: PackedByteArray = main.forest_img.get_data()
	main._regen()
	var after: PackedByteArray = main.forest_img.get_data()
	_check(after != before, "Neugenerieren tauscht den Wald")
	_check(after == main.sim.forestMaskBytes(), "Hochgeladen ist die Maske der neuen Welt")
	_check(main.terrain_mat.get_shader_parameter("forest_tex") == tex,
		"Das Material liest weiter die aktualisierte Waldtextur")
