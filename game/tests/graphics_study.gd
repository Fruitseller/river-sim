extends SceneTree
## Kleine Verhaltenswächter für #116, ohne Messlauf. `_check_protect_mask`
## erzeugt einen `SimNode` und damit die Produktionswelt samt Einlauf (wie
## `smoke.gd`; Laufzeit in docs/ci-measurements.md).

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

## Die Schutzmaske sperrt Verschiebung und Kronendach an Wasser (#154). Ihr
## Inhalt ist headless gepinnt (`WaterProtectMaskTests`); hier zählt der Weg
## durch Brücke und Studie: R8 in Gittergröße, voll sichtbares Wasser gesperrt,
## trockenes Land frei, das Wasserfeld unverändert.
func _check_protect_mask() -> void:
	if not ClassDB.class_exists("SimNode"):
		_check(false, "SimNode nicht registriert (GDExtension gebaut und importiert?)")
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	var study = load("res://studies/flusstal/Flusstal.gd").new()
	study.sim = sim
	study.N = sim.gridSize()
	sim.buildRiverRibbons(24.0, 0.35)
	var water: PackedByteArray = sim.waterFieldBytes(1.0)
	var mask: Image = study._protect_mask(sim.protectMaskBytes())
	_check(mask.get_format() == Image.FORMAT_R8, "Schutzmaske muss im Format R8 vorliegen")
	_check(mask.get_width() == study.N and mask.get_height() == study.N,
		"Schutzmaske muss Dimension N*N haben")
	var bytes := mask.get_data()
	var water_cells := 0
	var free_cells := 0
	for k in bytes.size():
		if water[k * 4] == 255 or water[k * 4 + 1] == 255:
			water_cells += 1
			if bytes[k] != 255:
				_check(false, "Voll sichtbares Wasser an Zelle %d ist ungeschützt" % k)
				break
		if bytes[k] == 0:
			free_cells += 1
	_check(water_cells > 0, "Produktionswelt muss sichtbares Wasser haben")
	_check(free_cells > bytes.size() / 4, "Trockenes Land muss frei bleiben")
	_check(sim.waterFieldBytes(1.0) == water, "Schutzmaske darf das Render-Wasserfeld nicht ändern")
	study.free()
	sim.free()

## Alle Hebel sind Produktion (#151, #153, #155, #152): ein alter Aufruf mit
## `RS_STUDY_LEVERS` scheitert laut, statt still dasselbe Bild zu liefern.
func _check_lever_parsing() -> void:
	var previous_levers := OS.get_environment("RS_STUDY_LEVERS")
	var script = load("res://studies/flusstal/Flusstal.gd")
	OS.set_environment("RS_STUDY_LEVERS", "")
	var none = script.new()
	_check(none._reject_levers(), "Ohne RS_STUDY_LEVERS startet die Studie")
	none.free()
	for adopted in ["canopy", "light", "frame", "geometry"]:
		OS.set_environment("RS_STUDY_LEVERS", adopted)
		var old = script.new()
		_check(not old._reject_levers(), "Übernommener Hebel '%s' muss abbrechen" % adopted)
		old.free()
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
			"study_debug",
		],
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

func _uniform_names(shader: Shader) -> Dictionary:
	var names := {}
	for u in shader.get_shader_uniform_list():
		names[u["name"]] = true
	return names
