extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const SHADER := "res://shaders/terrain.gdshader"

const FRAME_SETTLED := 0

var failures := 0
var main: Node
var done := false
var frame_clock := 0.0

func _frame(sim: Object) -> Dictionary:
	frame_clock += 1.0
	return sim.renderFrame(FRAME_SETTLED, frame_clock)

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
	_check_material(main)
	_check_tree_instances(main)
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
	var calib: Dictionary = Main.calibration(main.sim, "canopy")
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

func _check_material(main: Node) -> void:
	var calib: Dictionary = Main.calibration(main.sim, "material")
	_check(not calib.is_empty(), "Brücke liefert die Material-Tabelle")
	var mat: ShaderMaterial = main.terrain_mat
	var decl_re := RegEx.new()
	decl_re.compile("(?m)^uniform\\s+float\\s+(material_[A-Za-z0-9_]+)([^;]*);")
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
	var tex: Texture2D = mat.get_shader_parameter("cover_tex")
	_check(tex != null and tex.get_width() == main.N and tex.get_height() == main.N,
		"Bodenbedeckung liegt in Gittergröße am Material")
	var cover: PackedByteArray = _frame(main.sim)["cover"]
	_check(cover.size() == main.N * main.N * 4, "Bodenbedeckung ist RGBA8 in Gittergröße")

func _check_tree_instances(main: Node) -> void:
	var want: bool = Main.ForestTrees.available() and not OS.has_environment("RS_NO_TREES")
	var trees: Node3D = main.forest_trees
	_check((trees != null) == want, "Einzelbäume genau mit RenderingDevice (erwartet %s)" % want)
	_check((main.terrain_mat.get_shader_parameter("tree_instances") == true) == want,
		"Terrain-Shader weiß von den Bäumen genau dann, wenn es sie gibt")
	if trees != null:
		_check(trees.lists.size() == 4, "vier Baumlisten (%d)" % trees.lists.size())

func _check_visible_surface(main: Node) -> void:
	main.relief_lift_cache = PackedFloat32Array()
	main.relief_bake_frame = -1
	var forest: PackedByteArray = _frame(main.sim)["forest"]
	var n: int = main.N
	var cell := -1
	for j in range(3, n - 4):
		for i in range(3, n - 4):
			var full := true
			for dj in range(-2, 4):
				for di in range(-2, 4):
					full = full and forest[(j + dj) * n + i + di] == 255
					if not full:
						break
				if not full:
					break
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
	var sim_y: float = main._sample_h(gx, gz) * main.hscale
	var height: float = 0.0 if main.forest_trees != null else main.canopy_calib["canopy_height"]
	_check(absf(main._surface_y(gx, gz) - (sim_y + height)) < 1e-4,
		"Sichtbare Fläche liegt auf Dach bzw. Boden (%.3f, Sim %.3f)" % [main._surface_y(gx, gz), sim_y])
	main.cam_target = Vector3(gx * main.step - main.half, 0.0, gz * main.step - main.half)
	main.cam_target.y = main._surface_y_at(main.cam_target)
	_check(absf(main.cam_target.y - (sim_y + height)) < 1e-4, "Kameraziel liegt auf der sichtbaren Fläche")
	_check_canopy_edge(main, forest)

func _check_canopy_edge(main: Node, forest: PackedByteArray) -> void:
	var n: int = main.N
	var calib: Dictionary = main.canopy_calib
	var lo: float = calib["canopy_lift_lo"]
	var o: float = calib["canopy_lift_smooth_texels"]
	var height: float = calib["canopy_height"]
	var found := 0
	var checked_low := false
	for j in range(3, n - 3):
		for i in range(3, n - 3):
			if forest[j * n + i] != 255:
				continue
			var sm := 0.0
			for d in [Vector2(o, o), Vector2(-o, -o), Vector2(o, -o), Vector2(-o, o)]:
				sm += _bilinear_mask(forest, n, i + d.x, j + d.y)
			var expect := smoothstep(lo, calib["canopy_lift_hi"], minf(1.0, sm * 0.25)) * height
			if expect > height * 0.5:
				continue
			if main.forest_trees != null:
				expect = 0.0
			var gx := float(i)
			var gz := float(j)
			var sim_y: float = main._sample_h(gx, gz) * main.hscale
			var got: float = main._surface_y(gx, gz) - sim_y
			_check(absf(got - expect) < 1e-4,
				"Bestandsrand (%d, %d): sichtbare Fläche %.4f über Sim, Shader hebt %.4f" % [i, j, got, expect])
			checked_low = checked_low or expect == 0.0
			found += 1
			if found >= 20:
				break
		if found >= 20:
			break
	_check(found >= 20 and checked_low, "Produktionswelt braucht Bestandsränder (%d)" % found)

func _bilinear_mask(forest: PackedByteArray, n: int, gx: float, gz: float) -> float:
	var x := clampf(gx, 0.0, n - 1.0)
	var z := clampf(gz, 0.0, n - 1.0)
	var x0 := mini(int(x), n - 2)
	var z0 := mini(int(z), n - 2)
	var fx := x - x0
	var fz := z - z0
	var k := z0 * n + x0
	return (forest[k] * (1 - fx) * (1 - fz) + forest[k + 1] * fx * (1 - fz)
		+ forest[k + n] * (1 - fx) * fz + forest[k + n + 1] * fx * fz) / 255.0

func _check_uploaded(main: Node, tex: Texture2D, what: String) -> void:
	_check(main.forest_img.get_data() == _frame(main.sim)["forest"],
		"%s: hochgeladen ist die aktuelle Waldmaske" % what)
	_check(main.terrain_mat.get_shader_parameter("forest_tex") == tex,
		"%s: das Material liest weiter die aktualisierte Waldtextur" % what)

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
	for _r in 6:
		main.sim.brush(3, gx, gz, 4.0, 3.0, main.sea - 0.05)
	main._finish_stroke()
	_check(main.forest_img.get_data()[cell] == 0,
		"Pinselstrich: unter den Meeresspiegel eingeebneter Wald verschwindet (%d)"
			% main.forest_img.get_data()[cell])
	_check_uploaded(main, tex, "Pinselstrich")
	_check(main.cover_field._img.get_data() == _frame(main.sim)["cover"],
		"Pinselstrich: hochgeladen ist die aktuelle Bodenbedeckung (#174 D)")

func _check_regenerate_and_load(main: Node) -> void:
	var tex: Texture2D = main.forest_tex
	var path := "user://tests/canopy.%s" % main.sim.worldFileExtension()
	var saved: PackedByteArray = main.forest_img.get_data()
	var saved_protect: PackedByteArray = _frame(main.sim)["protect"]
	var err: String = main.sim.saveWorld(ProjectSettings.globalize_path(path))
	_check(err.is_empty(), "saveWorld: %s" % err)
	main._regen()
	_check(main.forest_img.get_data() != saved, "Neugenerieren tauscht den Wald")
	_check_uploaded(main, tex, "Neugenerieren")
	main._load_world(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var got: PackedByteArray = main.forest_img.get_data()
	var protect: PackedByteArray = _frame(main.sim)["protect"]
	var wrong := 0
	var wrong_protect := 0
	for k in range(saved.size()):
		if got[k] != saved[k]:
			wrong += 1
		if protect[k] != saved_protect[k]:
			wrong_protect += 1
	_check(wrong == 0 and wrong_protect == 0,
		"Laden holt den gespeicherten Wald zurück (%d Wald-, %d Schutzzellen von %d abweichend)"
			% [wrong, wrong_protect, saved.size()])
	_check_uploaded(main, tex, "Laden")
