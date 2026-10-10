extends SceneTree
## Headless-Wächter des Kronendachs (#152):
##   godot --headless --path game --script res://tests/canopy.gd
##
## Wo Wald steht, ist headless in SimCoreTests/CanopyTests.swift gepinnt; hier
## zählt der Weg durch Brücke, Main und Shader:
##  - jede `canopy_*`-Zahl kommt über die Brücke (SimCore.CanopyRender), ist im
##    Terrain-Shader default-frei deklariert und auf dem Material gesetzt;
##  - die Waldmaske liegt als Textur am Material und folgt Pinselstrich,
##    Neugenerieren und Laden (die Pfade von Main, nicht nur die Brücke);
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
	_check_brush(main)
	_check_regenerate_and_load(main)
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
## Main zuletzt hochgeladen hat (`forest_img`), und dass die Textur dieselbe
## bleibt.
func _check_uploaded(main: Node, tex: Texture2D, what: String) -> void:
	_check(main.forest_img.get_data() == main.sim.forestMaskBytes(),
		"%s: hochgeladen ist die aktuelle Waldmaske" % what)
	_check(main.terrain_mat.get_shader_parameter("forest_tex") == tex,
		"%s: das Material liest weiter die aktualisierte Waldtextur" % what)

## Pinselstrich über Mains Strich-Ende: eine Waldzelle unter den Meeresspiegel
## eingeebnet trägt danach keinen Wald mehr.
func _check_brush(main: Node) -> void:
	var tex: Texture2D = main.forest_tex
	var forest: PackedByteArray = main.forest_img.get_data()
	var n: int = main.N
	var cell := -1
	for k in range(forest.size()):
		var i := k % n
		var j := k / n
		if forest[k] == 255 and i > 20 and i < n - 20 and j > 20 and j < n - 20:
			cell = k
			break
	_check(cell >= 0, "Produktionswelt braucht Wald abseits des Rands")
	if cell < 0:
		return
	var gx := float(cell % n)
	var gz := float(cell / n)
	for _r in 6:  # Einebnen nähert sich dem Ziel, ein Hieb reicht nicht
		main.sim.brush(3, gx, gz, 4.0, 3.0, main.sea - 0.05)
	main._finish_stroke()
	_check(main.forest_img.get_data()[cell] == 0,
		"Pinselstrich: unter den Meeresspiegel eingeebneter Wald verschwindet (%d)"
			% main.forest_img.get_data()[cell])
	_check_uploaded(main, tex, "Pinselstrich")

## Neugenerieren tauscht den Wald, Laden holt den gespeicherten zurück. Nicht
## mitgespeichert ist der Render-Zustand des Rasterwassers (EWMA, s. AGENTS.md);
## nach dem Laden darf die Schutzmaske deshalb an einzelnen Ufern abweichen, und
## der Wald folgt ihr. Verglichen wird der Wald überall sonst.
func _check_regenerate_and_load(main: Node) -> void:
	var tex: Texture2D = main.forest_tex
	var path := "user://tests/canopy.%s" % main.sim.worldFileExtension()
	var saved: PackedByteArray = main.forest_img.get_data()
	var saved_protect: PackedByteArray = main.sim.protectMaskBytes()
	var err: String = main.sim.saveWorld(ProjectSettings.globalize_path(path))
	_check(err.is_empty(), "saveWorld: %s" % err)
	main._regen()
	_check(main.forest_img.get_data() != saved, "Neugenerieren tauscht den Wald")
	_check_uploaded(main, tex, "Neugenerieren")
	main._load_world(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var got: PackedByteArray = main.forest_img.get_data()
	var protect: PackedByteArray = main.sim.protectMaskBytes()
	var compared := 0
	var wrong := 0
	for k in range(saved.size()):
		if protect[k] == saved_protect[k]:
			compared += 1
			if got[k] != saved[k]:
				wrong += 1
	_check(compared > saved.size() * 9 / 10 and wrong == 0,
		"Laden holt den gespeicherten Wald zurück (%d von %d Zellen abweichend)"
			% [wrong, compared])
	_check_uploaded(main, tex, "Laden")
