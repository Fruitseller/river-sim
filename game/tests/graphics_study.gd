extends SceneTree
## Kleine Verhaltenswächter für #116, ohne Messlauf. Mit geladener GDExtension
## erzeugt `_check_protect_mask` einen `SimNode` und damit die Produktionswelt
## samt Einlauf (wie `smoke.gd`, das Budget steht in docs/ci-measurements.md).

var failures := 0

func _initialize() -> void:
	_check_protect_mask()
	_check_lever_parsing()
	_check_study_shaders()
	if failures > 0:
		quit(1)
		return
	print("GRAPHICS_STUDY_OK")
	quit(0)

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

## Die Schutzmaske sperrt Verschiebung und Kronendach an Wasser (#154).
## Sie entsteht als godot-freie Render-Ableitung in SimRender und wird
## über die Brücke (sim.protectMaskBytes) als R8-Puffer bereitgestellt.
func _check_protect_mask() -> void:
	var study = load("res://studies/flusstal/Flusstal.gd").new()
	if ClassDB.class_exists("SimNode"):
		var sim: Object = ClassDB.instantiate("SimNode")
		study.sim = sim
		study.N = sim.gridSize()
		study.half = sim.worldSize() * 0.5
		study.step = sim.worldSize() / float(study.N - 1)

		var mask: Image = study._placement_water()
		_check(mask != null, "Schutzmaske muss erzeugt werden")
		_check(mask.get_format() == Image.FORMAT_R8, "Schutzmaske muss im Format R8 vorliegen")
		_check(mask.get_width() == study.N and mask.get_height() == study.N,
			"Schutzmaske muss Dimension N*N haben")

		var mask_bytes: PackedByteArray = sim.protectMaskBytes()
		_check(mask_bytes.size() == study.N * study.N, "sim.protectMaskBytes() muss n*n Bytes liefern")

		var water_before: PackedByteArray = sim.waterFieldBytes(1.0)
		var _dummy: PackedByteArray = sim.protectMaskBytes()
		var water_after: PackedByteArray = sim.waterFieldBytes(1.0)
		_check(water_before == water_after, "Schutzmaske darf das Render-Wasserfeld nicht ändern")
	else:
		study.N = 16
		var mask: Image = study._placement_water()
		_check(mask != null and mask.get_format() == Image.FORMAT_R8,
			"Schutzmaske ohne Sim muss Fallback-R8-Bild liefern")
		_check(mask.get_data()[0] == 255, "Fallback ohne Sim muss alles schützen")
	study.free()

## Ein unbekannter Hebelname bricht ab, statt still ignoriert zu werden.
func _check_lever_parsing() -> void:
	var previous_variant := OS.get_environment("RS_STUDY_VARIANT")
	var previous_levers := OS.get_environment("RS_STUDY_LEVERS")
	OS.set_environment("RS_STUDY_VARIANT", "prototype")
	var script = load("res://studies/flusstal/Flusstal.gd")
	OS.set_environment("RS_STUDY_LEVERS", "")
	var all = script.new()
	_check(all._parse_levers() and all.study_levers.size() == 4, "Ohne Angabe gelten alle vier Hebel")
	all.free()
	OS.set_environment("RS_STUDY_LEVERS", "geometry,frame")
	var two = script.new()
	_check(two._parse_levers() and two._lever("geometry") and two._lever("frame")
		and not two._lever("canopy"), "Hebel-Liste schaltet einzeln")
	two.free()
	OS.set_environment("RS_STUDY_LEVERS", "geometry,licht")
	var typo = script.new()
	_check(not typo._parse_levers(), "Tippfehler im Hebel muss abbrechen")
	typo.free()
	OS.set_environment("RS_STUDY_VARIANT", previous_variant)
	OS.set_environment("RS_STUDY_LEVERS", previous_levers)

## Die Studien-Shader werden zur Laufzeit aus den Produktionsquellen gebaut
## (#define FLUSSTAL_STUDY vor der Quelle). Früher rutschte ein stiller
## Include-Fehler durch, weil nichts den zusammengesetzten Code kompilierte:
## das Material fiel auf Standard zurück und nur ein A/B-Bild hätte es gezeigt.
## Diese Prüfung parst BEIDE Fassungen: Produktion darf die Studien-Uniforms
## nicht kennen, die Studie muss sie liefern. Ohne Uniforms = Kompilierungsfehler.
func _check_study_shaders() -> void:
	var study_script = load("res://studies/flusstal/Flusstal.gd")
	var cases := {
		"res://shaders/terrain.gdshader": [
			"study_enabled", "study_rock_color", "study_rock_normal", "study_rock_roughness",
			"study_ground_color", "study_ground_normal", "study_ground_roughness",
			"study_geometry", "study_relief_tex", "study_protect_tex",
			"study_canopy_enabled", "study_clouds",
		],
		"res://shaders/ocean.gdshader": ["study_ocean", "study_clouds"],
		"res://shaders/water.gdshader": ["study_clouds"],
	}
	for path in cases:
		var source: String = FileAccess.get_file_as_string(path)
		_check(not source.is_empty(), "%s muss lesbar sein" % path)
		var production := Shader.new()
		production.code = source
		var production_names := _uniform_names(production)
		_check(production_names.size() > 0, "%s muss kompilieren" % path)
		var study_names := _uniform_names(study_script.study_shader(path))
		for name in cases[path]:
			_check(not production_names.has(name),
				"Produktions-Shader %s darf Studien-Uniform %s nicht binden" % [path, name])
			_check(study_names.has(name),
				"Studien-Fassung von %s muss Uniform %s liefern (Kompilierungsfehler?)" % [path, name])
	var bake: Shader = load("res://studies/flusstal/relief_bake.gdshader")
	var bake_names := _uniform_names(bake)
	for name in ["height_tex", "study_protect_tex", "study_relief_scale", "study_sharpen"]:
		_check(bake_names.has(name), "Back-Pass muss Uniform %s liefern (Kompilierungsfehler?)" % name)

func _uniform_names(shader: Shader) -> Dictionary:
	var names := {}
	for u in shader.get_shader_uniform_list():
		names[u["name"]] = true
	return names
