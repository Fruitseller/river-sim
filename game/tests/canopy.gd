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
##  - Einzelbäume (#236) nur mit RenderingDevice (headless: Kronendach), das
##    Dach hebt dann nicht mehr an; `RS_NO_TREES` zeigt das Kronendach;
##  - Pinselring und Kameraziel liegen auf der sichtbaren Fläche (mit Bäumen
##    auf dem Boden, ohne auf dem Dach);
##  - Materialverteilung (#174 D): jede `material_*`-Zahl kommt über die Brücke
##    (SimCore.MaterialRender), ist default-frei deklariert und gesetzt, die
##    Bodenbedeckung liegt in Gittergröße am Material und folgt dem Pinsel.
## Erzeugt einen `SimNode` samt Produktionswelt (Laufzeit wie `smoke.gd`).

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const SHADER := "res://shaders/terrain.gdshader"

# Rohwert von FrameTrigger.settled (Main.gd FRAME_SETTLED).
const FRAME_SETTLED := 0

var failures := 0
var main: Node
var done := false
# Monotone Uhr für die Probe-Frames (SETTLED ist ungedrosselt, die Uhr läuft
# trotzdem weiter, damit kein Deckel je zuschlägt).
var frame_clock := 0.0

## Ein frischer Render-Frame über die Brücke (Issue #214): die Masken und die
## Bodenbedeckung kommen aus dem Frame — derselbe Weg, den Main.gd fährt. Ohne
## Weltänderung zwischen Mains letztem Upload und diesem Frame sind die Puffer
## bit-gleich zu dem, was Main hochgeladen hat.
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

## Materialverteilung (#174 D): Kalibrierung über die Brücke, default-frei
## im Terrain-Shader, gesetzt; die Bodenbedeckung kommt mit dem Frame.
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

## Einzelbäume (#236) gibt es genau dann, wenn ein RenderingDevice da ist
## (der Compute-Pass braucht es) und `RS_NO_TREES` fehlt; headless, also in
## CI, bleibt das Kronendach von #152. Mit Bäumen weiß der Terrain-Shader davon
## (`tree_instances`: keine Anhebung, keine gemalten Kronen), und es gibt die
## vier Listen (Nadel-, Laubbaum nah, fern, Schatten).
func _check_tree_instances(main: Node) -> void:
	var want: bool = Main.ForestTrees.available() and not OS.has_environment("RS_NO_TREES")
	var trees: Node3D = main.forest_trees
	_check((trees != null) == want, "Einzelbäume genau mit RenderingDevice (erwartet %s)" % want)
	_check((main.terrain_mat.get_shader_parameter("tree_instances") == true) == want,
		"Terrain-Shader weiß von den Bäumen genau dann, wenn es sie gibt")
	if trees != null:
		_check(trees.lists.size() == 4, "vier Baumlisten (%d)" % trees.lists.size())

## Pinselring und Kameraziel liegen auf der sichtbaren Fläche: Sim-Höhe plus
## Dachhöhe (mit Einzelbäumen null) an
## einer Zelle mit geschlossenem Wald (ohne Verschiebung, die prüft relief.gd).
## Am Bestandsrand hebt der Terrain-Vertex-Shader nach der geglätteten Maske
## (`canopy_lift_smooth_texels`) und damit weniger; dort muss die sichtbare
## Fläche genauso tief liegen (Review Neon Nr. 2).
func _check_visible_surface(main: Node) -> void:
	main.relief_lift_cache = PackedFloat32Array()
	main.relief_bake_frame = -1
	var forest: PackedByteArray = _frame(main.sim)["forest"]
	var n: int = main.N
	# Innen: 6×6 geschlossener Wald um das Quad (i … i+1, j … j+1), so reicht
	# auch die Glättung beider Ecken nur über Wald.
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

## Bestandsrand: ein Gitterpunkt mit voller Maske, dessen geglättete Maske
## unter `canopy_lift_lo` fällt. Der Terrain-Vertex-Shader hebt ihn nicht
## (`lift_f = min(v_forest, sm * 0.25)`); hier unabhängig davon nachgerechnet
## aus der Maske des Frames.
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
				expect = 0.0  # mit Einzelbäumen hebt das Dach nirgends
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

## Der Dummy-Renderer liest Texturen nicht zurück; geprüft wird das Bild, das
## Main zuletzt hochgeladen hat (`forest_img`), und dass die Textur dieselbe
## bleibt.
func _check_uploaded(main: Node, tex: Texture2D, what: String) -> void:
	_check(main.forest_img.get_data() == _frame(main.sim)["forest"],
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
	_check(main.cover_field._img.get_data() == _frame(main.sim)["cover"],
		"Pinselstrich: hochgeladen ist die aktuelle Bodenbedeckung (#174 D)")

## Neugenerieren tauscht den Wald, Laden holt den gespeicherten zurück —
## bit-gleich. Der Render-Zustand des Rasterwassers reist zwar nicht im
## Spielstand (EWMA, s. AGENTS.md), aber jeder Weltwechsel endet in einem
## `settled`-Frame mit Blend 1,0, der ihn vollständig überschreibt. Bis zum
## Review Neon Nr. 5 wich der Wald hier ab (Mac 1, Linux 9 Zellen), und der
## Test klammerte Ufer aus und duldete einen Anteil: Ursache war nicht das
## Gedächtnis der Waldmaske (der Test lässt keine Zeit laufen), sondern dass
## der Endstand des Pinselstrichs die Bänder des Vor-Pinsel-Stands behielt
## (`RenderState.rebuildRibbonsIfDue`, Wächter
## `RenderFrameTests.testFinishedStrokeMatchesTheLoadedWorld`).
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
