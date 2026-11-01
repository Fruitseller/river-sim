extends "res://studies/flusstal/Flusstal.gd"
## Manuelle Diagnose der Felswände (#174), keine Pflichtsuite.
## Aufruf und Befund: docs/zielbild-measurements.md, Abschnitt Felswände.
## `before` liest den Shader aus RS_CLIFF_BEFORE und dessen alte Streckung 5;
## alle anderen Modi verwenden den aktuellen Vertrag über die echte Brücke.
var cliff_modes := OS.get_environment("RS_CLIFF_MODES").split(",", false)
var cliff_output := OS.get_environment("RS_CLIFF_OUTPUT")
var cliff_index := 0
var cliff_frame := 0
var cliff_original: Dictionary = {}
var cliff_shader: Shader

func _ready() -> void:
	super._ready()
	cliff_shader = terrain_mat.shader
	for name in ["detail_enabled", "relief_enabled", "material_enabled", "canopy_enabled",
		"material_joint_depth", "material_joint_relief", "material_joint_stretch"]:
		cliff_original[name] = terrain_mat.get_shader_parameter(name)
	if cliff_modes.is_empty():
		cliff_modes = ["full", "no_detail", "no_relief", "no_joints", "bare", "faces"]
	DirAccess.make_dir_recursive_absolute(cliff_output)
	var heights := FileAccess.open(cliff_output + "/heights.f32", FileAccess.WRITE)
	heights.store_buffer(sim.heights().to_byte_array())
	print("CLIFF_GRID ", JSON.stringify({"n": N, "world": world_size, "hscale": hscale,
		"seed": sim_seed, "year": shown_year, "target": str(cam_target), "viewport": str(get_viewport().size)}))
	_cliff_probe()

func _cliff_probe() -> void:
	terrain_mat.shader = cliff_shader
	for name in cliff_original:
		terrain_mat.set_shader_parameter(name, cliff_original[name])
	var mode := cliff_modes[cliff_index]
	if mode in ["no_detail", "bare", "faces"]:
		terrain_mat.set_shader_parameter("detail_enabled", false)
	if mode in ["no_relief", "bare", "faces"]:
		terrain_mat.set_shader_parameter("relief_enabled", false)
	if mode in ["bare", "faces"]:
		terrain_mat.set_shader_parameter("material_enabled", false)
		terrain_mat.set_shader_parameter("canopy_enabled", false)
	if mode == "joint_tone":
		terrain_mat.set_shader_parameter("material_joint_relief", 0.0)
	if mode == "joint_form":
		terrain_mat.set_shader_parameter("material_joint_depth", 0.0)
	if mode == "no_joints":
		terrain_mat.set_shader_parameter("material_joint_depth", 0.0)
		terrain_mat.set_shader_parameter("material_joint_relief", 0.0)
	if mode == "before":
		var shader := Shader.new()
		shader.code = FileAccess.get_file_as_string(OS.get_environment("RS_CLIFF_BEFORE"))
		terrain_mat.shader = shader
		terrain_mat.set_shader_parameter("material_joint_stretch", 5.0)
	if mode in ["bare", "faces"]:
		var shader := Shader.new()
		var ending := "\nALBEDO = vec3(0.18); ROUGHNESS = 1.0; SPECULAR = 0.0;\n"
		if mode == "faces":
			ending += "NORMAL = -normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));\n"
		var source := FileAccess.get_file_as_string("res://shaders/terrain.gdshader")
		shader.code = source.substr(0, source.rfind("}")) + ending + "}\n"
		terrain_mat.shader = shader
	cliff_frame = 0

func _process(delta: float) -> void:
	super._process(delta)
	u_time = 1.0
	for mat in [terrain_mat, ocean_mat, river_mat, river_prev_mat]:
		if mat != null:
			mat.set_shader_parameter("u_time", u_time)
	for mat in Lighting.cloud_body_materials(cloud_bodies):
		mat.set_shader_parameter("u_time", u_time)

func _study_drawn() -> void:
	if cliff_index >= cliff_modes.size():
		return
	cliff_frame += 1
	if cliff_frame < 60:
		return
	var mode := cliff_modes[cliff_index]
	var path := cliff_output + "/" + mode + ".png"
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("CLIFF_SHOT ", mode, " ", path, " error=", err, " viewport=", get_viewport().size)
	cliff_index += 1
	if cliff_index >= cliff_modes.size():
		get_tree().quit()
	else:
		_cliff_probe()
