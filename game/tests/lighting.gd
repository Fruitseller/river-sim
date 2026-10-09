extends SceneTree
## Headless-Wächter für Licht und Atmosphäre (Issue #151):
##   godot --headless --path game --script res://tests/lighting.gd
##
## Braucht die GDExtension nicht. Geprüft wird das äußere Verhalten von
## scripts/Lighting.gd, der EINEN Quelle für Sonne, Atmosphäre und Wolken:
##  - feste Welt-Sonne: das Licht fällt von oben aus der vereinbarten Richtung,
##    unabhängig von der Kamera (Main ruft configure_sun nur beim Aufbau);
##  - Atmosphäre: AgX, Luftperspektive, Talnebel knapp über dem Meer, Anteil
##    neutral-warmes Umgebungslicht;
##  - Qualitätsstufen: `performance` ist billiger als `balanced`;
##  - Wolkenschatten: jede `cloud*`-Uniform ist in allen drei Shadern
##    deklariert, default-frei (die Werte reisen nur über Lighting.gd) und wird
##    gesetzt; die Shader kompilieren mit dem gemeinsamen Include.

const Lighting = preload("res://scripts/Lighting.gd")
const SHADERS := [
	"res://shaders/terrain.gdshader",
	"res://shaders/water.gdshader",
	"res://shaders/ocean.gdshader",
]
const CLOUD_UNIFORMS := ["clouds_enabled", "cloud_strength", "cloud_scale"]

var failures := 0

func _initialize() -> void:
	_check_sun()
	_check_environment()
	_check_quality()
	_check_clouds()
	if failures > 0:
		quit(1)
		return
	print("LIGHTING_OK")
	quit(0)

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _check_sun() -> void:
	var to_sun := Lighting.sun_direction()
	_check(is_equal_approx(to_sun.length(), 1.0), "Sonnenrichtung muss normiert sein")
	_check(to_sun.y > 0.0, "Sonne muss über dem Horizont stehen")
	var sun := DirectionalLight3D.new()
	Lighting.configure_sun(sun, "balanced")
	# Ein DirectionalLight3D leuchtet entlang seiner −Z-Achse.
	var shines := -sun.basis.z
	_check(shines.is_equal_approx(-to_sun), "Licht muss von der Sonnenrichtung her einfallen")
	_check(sun.shadow_enabled, "Die Sonne muss Schatten werfen")
	sun.free()

func _check_environment() -> void:
	var e := Lighting.make_environment("balanced", 10.0)
	_check(e.tonemap_mode == Environment.TONE_MAPPER_AGX, "Filmisches Tonemapping (AgX)")
	_check(e.fog_enabled and e.fog_mode == Environment.FOG_MODE_EXPONENTIAL,
		"Luftperspektive braucht exponentiellen Nebel")
	_check(e.fog_aerial_perspective > 0.0, "Ferne muss die Himmelsfarbe annehmen")
	_check(e.fog_height > 10.0 and e.fog_height_density > 0.0,
		"Talnebel liegt knapp über dem Meeresspiegel")
	_check(e.ambient_light_sky_contribution < 1.0,
		"Ein Anteil neutral-warmes Umgebungslicht gegen blaue Schattenseiten")

func _check_quality() -> void:
	var perf := Lighting.profile("performance")
	var bal := Lighting.profile("balanced")
	_check(Lighting.profile("unbekannt") == bal, "Unbekannte Stufe fällt auf balanced zurück")
	_check(perf["shadow_atlas"] < bal["shadow_atlas"], "performance spart Schattenatlas")
	_check(perf["shadow_splits"] < bal["shadow_splits"], "performance spart Kaskaden")
	_check(not perf["clouds"] and bal["clouds"], "performance spart Wolkenschatten")
	_check(bal["shadow_splits"] == 4, "balanced trägt vier Schattenkaskaden")
	var sun := DirectionalLight3D.new()
	Lighting.configure_sun(sun, "performance")
	_check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"performance setzt zwei Kaskaden am Licht")
	sun.free()
	_check(not Lighting.make_environment("performance", 0.0).ssao_enabled,
		"performance ohne SSAO")

func _check_clouds() -> void:
	var decl_re := RegEx.new()
	decl_re.compile("(?m)^uniform\\s+\\w+\\s+(clouds?_\\w+)([^;]*);")
	var include := FileAccess.get_file_as_string("res://shaders/clouds.gdshaderinc")
	var declared := {}
	for m in decl_re.search_all(include):
		declared[m.get_string(1)] = true
		_check(m.get_string(2).find("=") < 0,
			"%s trägt einen Literal-Default — der Wert gehört nach Lighting.gd" % m.get_string(1))
	_check(declared.keys().size() == CLOUD_UNIFORMS.size(),
		"clouds.gdshaderinc deklariert genau %s" % str(CLOUD_UNIFORMS))
	for quality in ["performance", "balanced"]:
		var mats: Array[ShaderMaterial] = []
		for path in SHADERS:
			var mat := ShaderMaterial.new()
			mat.shader = load(path)
			mats.append(mat)
		Lighting.apply_clouds(mats, quality)
		for i in mats.size():
			var names := {}
			for u in mats[i].shader.get_shader_uniform_list():
				names[u["name"]] = true
			for name in CLOUD_UNIFORMS:
				_check(names.has(name), "%s muss %s liefern (Include fehlt oder Kompilierfehler?)"
					% [SHADERS[i], name])
				_check(mats[i].get_shader_parameter(name) != null,
					"%s: %s nicht gesetzt (%s)" % [SHADERS[i], name, quality])
			_check(mats[i].get_shader_parameter("clouds_enabled") == Lighting.profile(quality)["clouds"],
				"%s: Wolkenschatten folgen der Qualitätsstufe %s" % [SHADERS[i], quality])
