extends SceneTree
## Headless-Wächter für den Uniform-Kanal der Wasser-Kalibrierung (#91/#92):
##   godot --headless --path game --script res://tests/water_uniforms.gd
##
## Der Contract-Schritt verspricht: jede `water_*`-Uniform, die ein Shader
## deklariert, bekommt ihren Wert AUSSCHLIESSLICH über die Brücke — keine
## bleibt still auf ihrem Default stehen, und keine trägt einen Literal-Default
## (das wäre wieder die Kopie der Kalibrierung, die #92 abschafft). Geprüft:
##  - die Brücke liefert die Tabelle konsistent (Namen ↔ Werte, eindeutig),
##  - jede deklarierte `water_*`-Uniform steht in der Tabelle und ist
##    default-frei deklariert,
##  - jeder Tabellenwert ist in mindestens einem Shader deklariert,
##  - Main.apply_water_calibration setzt jeden deklarierten Namen wirklich
##    (get_shader_parameter liefert den Brückenwert, nicht null).
## Exit-Code != 0 bei Fehler.

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")

const SHADERS := [
	"res://shaders/terrain.gdshader",
	"res://shaders/water.gdshader",
	"res://shaders/ocean.gdshader",
]

var done := false
var failed := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _fail(msg: String) -> void:
	push_error("FAIL: " + msg)
	failed = true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim):
		quit(1)
		return

	# Brücken-Tabelle: Namen und Werte paarweise, Namen eindeutig.
	var scalar_names: PackedStringArray = sim.waterScalarUniformNames()
	var scalar_values: PackedFloat32Array = sim.waterScalarUniformValues()
	var color_names: PackedStringArray = sim.waterColorUniformNames()
	var color_values: PackedVector3Array = sim.waterColorUniformValues()
	print("scalars=", scalar_names.size(), " colors=", color_names.size())
	if scalar_names.size() != scalar_values.size():
		_fail("Skalar-Namen und -Werte sind nicht paarweise")
	if color_names.size() != color_values.size():
		_fail("Farb-Namen und -Werte sind nicht paarweise")
	if scalar_names.is_empty() or color_names.is_empty():
		_fail("Brücken-Tabelle ist leer")
	var bridge := {}
	for i in scalar_names.size():
		if bridge.has(scalar_names[i]):
			_fail("Uniform-Name doppelt: " + scalar_names[i])
		bridge[scalar_names[i]] = scalar_values[i]
	for i in color_names.size():
		if bridge.has(color_names[i]):
			_fail("Uniform-Name doppelt: " + color_names[i])
		bridge[color_names[i]] = color_values[i]

	# Deklarationen aus den echten Shader-Quelltexten. Zeilenanker genügt hier:
	# die strengere, kommentarbereinigte Sicht hält SimCoreTests (SourceProbe).
	# Der Typ wird BREIT gematcht und dann geprüft: eine künftige
	# `uniform vec2 water_*` soll laut scheitern, nicht still am Wächter vorbei.
	var decl_re := RegEx.new()
	decl_re.compile("(?m)^uniform\\s+([A-Za-z0-9_]+)\\s+(water_[A-Za-z0-9_]+)([^;]*);")
	var declared_anywhere := {}
	for path in SHADERS:
		var source := FileAccess.get_file_as_string(path)
		if source.is_empty():
			_fail(path + " nicht lesbar")
			continue
		var declared := {}
		for m in decl_re.search_all(source):
			var kind := m.get_string(1)
			var name := m.get_string(2)
			var rest := m.get_string(3)
			if kind.begins_with("sampler"):
				continue # Texturen (water_tex) sind keine Kalibrier-Werte.
			if kind != "float" and kind != "vec3":
				_fail("%s: %s hat Typ %s — die Brücke kennt nur float und vec3"
					% [path, name, kind])
				continue
			declared[name] = true
			declared_anywhere[name] = true
			if not bridge.has(name):
				_fail("%s deklariert %s an der Brücken-Tabelle vorbei — der Wert "
					% [path, name] + "bliebe still auf seinem Default stehen")
				continue
			if (kind == "float") != (bridge[name] is float):
				_fail("%s: %s ist als %s deklariert, die Brücke liefert aber %s"
					% [path, name, kind, type_string(typeof(bridge[name]))])
				continue
			if rest.find("=") >= 0:
				_fail("%s: %s trägt einen Literal-Default — der Wert reist über "
					% [path, name] + "die Brücke, ein Default wäre eine Kopie (#92)")

		# Anwendung auf ein echtes Material mit diesem Shader: jede deklarierte
		# Uniform muss danach gesetzt sein (nicht null) und den Brückenwert tragen.
		var mat := ShaderMaterial.new()
		mat.shader = load(path)
		Main.apply_water_calibration(sim, [mat])
		for name in declared:
			var got: Variant = mat.get_shader_parameter(name)
			if got == null:
				_fail("%s: %s deklariert, aber nicht gesetzt" % [path, name])
			elif not _value_matches(got, bridge[name]):
				_fail("%s: %s gesetzt auf %s statt %s"
					% [path, name, str(got), str(bridge[name])])
		print(path, ": declared=", declared.size())

	for name in bridge:
		if not declared_anywhere.has(name):
			_fail("Brückenwert %s wird von keinem Shader deklariert (toter Kanal)"
				% [name])

	if failed:
		quit(1)
		return
	print("WATER_UNIFORMS_OK")
	quit(0)

func _value_matches(got: Variant, expected: Variant) -> bool:
	if got is Vector3 and expected is Vector3:
		return got.is_equal_approx(expected)
	if (got is float or got is int) and (expected is float or expected is int):
		return absf(float(got) - float(expected)) <= 1e-6
	return false
