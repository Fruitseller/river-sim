extends "res://studies/flusstal/Flusstal.gd"
## Manueller Shader-A/B-Lauf im selben Prozess, Reihenfolge je Runde gedreht.
const CLIFF_FRAMES := 90
const CLIFF_SKIP := 12
var cliff_shaders: Array[Shader] = []
var cliff_frame := 0
var cliff_block := -1
var cliff_last := 0
var cliff_samples: Array[float] = []
var cliff_rounds := 8
var cliff_done := false
var cliff_stretch := 0.0

func _ready() -> void:
	super._ready()
	var old := Shader.new()
	old.code = FileAccess.get_file_as_string(OS.get_environment("RS_CLIFF_BEFORE"))
	cliff_shaders = [old, terrain_mat.shader]
	cliff_stretch = float(terrain_mat.get_shader_parameter("material_joint_stretch"))
	if OS.has_environment("RS_CLIFF_ROUNDS"):
		cliff_rounds = int(OS.get_environment("RS_CLIFF_ROUNDS"))
	_cliff_next()

func _cliff_next() -> void:
	cliff_block += 1
	var round_index := cliff_block / 2
	if round_index > cliff_rounds:
		cliff_done = true
		get_tree().quit()
		return
	var state := (cliff_block + round_index) % 2
	terrain_mat.shader = cliff_shaders[state]
	# Historischer Vergleich: aeed3b3 hatte Streckung 5, sonst dieselben Werte.
	terrain_mat.set_shader_parameter("material_joint_stretch", 5.0 if state == 0 else cliff_stretch)
	cliff_frame = 0
	cliff_samples.clear()
	var processes: Array = []
	OS.execute("/bin/ps", ["-axo", "pid=,command="], processes)
	var others: Array[String] = []
	for line in str(processes[0]).split("\n"):
		var fields := line.strip_edges().split(" ", false, 2)
		if fields.size() >= 2 and fields[1].ends_with("/Godot") and int(fields[0]) != OS.get_process_id():
			others.append(fields[0])
	print("CLIFF_BLOCK ", JSON.stringify({"round": round_index, "state": state, "foreign_godot": others}))
	if not others.is_empty() or get_viewport().size != Vector2i(3456, 2104):
		print("CLIFF_BUSY_OR_VIEWPORT ", get_viewport().size)
		cliff_done = true
		get_tree().quit(2)

func _process(delta: float) -> void:
	super._process(delta)
	if study_mode == "orbit":
		# Derselbe kurze Kamerabogen je Block, unabhängig von der Shaderzeit.
		cam_yaw = study_start_yaw + float(cliff_frame) * 0.002
		_update_camera()

func _study_drawn() -> void:
	if cliff_shaders.is_empty() or cliff_done:
		return
	var now := Time.get_ticks_usec()
	if cliff_frame >= CLIFF_SKIP and cliff_last != 0:
		cliff_samples.append(float(now - cliff_last) / 1000.0)
	cliff_last = now
	cliff_frame += 1
	if cliff_frame < CLIFF_FRAMES:
		return
	cliff_samples.sort()
	var total := 0.0
	var over := 0
	for value in cliff_samples:
		total += value
		if value > 33.3:
			over += 1
	var round_index := cliff_block / 2
	print("CLIFF_TIMING ", JSON.stringify({"round": round_index, "state": (cliff_block + round_index) % 2,
		"mean_ms": total / cliff_samples.size(), "p95_ms": cliff_samples[int((cliff_samples.size() - 1) * 0.95)],
		"over_budget_frames": over, "viewport": str(get_viewport().size), "mode": study_mode,
		"quality": render_quality, "seed": sim_seed, "year": shown_year, "target": str(cam_target),
		"distance": cam_dist, "yaw": study_start_yaw, "pitch": cam_pitch, "samples_ms": cliff_samples}))
	_cliff_next()
