extends "res://scripts/Main.gd"
## Messbühne für #235 (Bildzeit-Budget): Wohin geht die Bildzeit?
## Schaltet im SELBEN Prozess blockweise zwischen Zuständen um (Reihenfolge je
## Runde gedreht, Runde 0 wärmt nur) und misst je Bild den Abstand der
## gezeichneten Bilder und die GPU-Zeit des Viewports. Kein Produktionsweg.
##
##   RS_PROBE_STATES  Komma-Liste der Zustände (Standard "base,noshadow")
##   RS_PROBE_ROUNDS  gezählte Runden (Standard 6)
##   RS_PROBE_TS=1    einmalig die GPU-Zeitmarken der Renderpässe drucken
const BLOCK_FRAMES := 120
const SKIP_FRAMES := 20

var probe_states: PackedStringArray
var probe_rounds := 6
var probe_frame := -1
var probe_last := 0
var probe_data := {} # "runde:zustand" -> {"dt": [], "gpu": []}
var probe_sun: DirectionalLight3D
var probe_mesh_full: Mesh
var probe_mesh_half: Mesh
var probe_elapsed := 0.0
var probe_state := ""
## Alter Stand: das eine PlaneMesh (`terrain_mi`); neuer Stand: die Kacheln.
var probe_terrain: Node3D
var probe_defaults := {}

func _ready() -> void:
	super._ready()
	if sim == null:
		get_tree().quit(1)
		return
	probe_states = OS.get_environment("RS_PROBE_STATES").split(",", false) \
		if OS.has_environment("RS_PROBE_STATES") else PackedStringArray(["base", "noshadow"])
	if OS.has_environment("RS_PROBE_ROUNDS"):
		probe_rounds = maxi(1, int(OS.get_environment("RS_PROBE_ROUNDS")))
	for c in get_children():
		if c is DirectionalLight3D:
			probe_sun = c
		if c is CanvasLayer:
			c.visible = false
	brush_mi.visible = false
	probe_terrain = get("terrain_mi") if get("terrain_mi") != null else get("terrain_tiles")
	if probe_terrain is MeshInstance3D:
		probe_mesh_full = probe_terrain.mesh
	active_fps_cap = 0
	var vp := get_viewport()
	probe_defaults = {"mode": vp.scaling_3d_mode, "scale": vp.scaling_3d_scale, "msaa": vp.msaa_3d}
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	RenderingServer.frame_post_draw.connect(_probe_drawn)
	print("PROBE ", JSON.stringify({"viewport": str(get_viewport().size),
		"quality": render_quality, "terrain_grid": terrain_grid, "states": probe_states,
		"target": str(cam_target), "distance": cam_dist, "yaw": cam_yaw, "pitch": cam_pitch}))

func _process(delta: float) -> void:
	last_activity_msec = Time.get_ticks_msec()
	probe_elapsed += delta
	super._process(delta)

func _probe_set(state: String) -> void:
	probe_state = state
	var vp := get_viewport()
	probe_sun.shadow_enabled = not state.contains("noshadow")
	vp.scaling_3d_mode = probe_defaults["mode"]
	vp.scaling_3d_scale = probe_defaults["scale"]
	if state.contains("native"):
		vp.scaling_3d_scale = 1.0
	if state.contains("scale50"):
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 0.5
	elif state.contains("scale67"):
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 0.67
	for m in [["mfxs", Viewport.SCALING_3D_MODE_METALFX_SPATIAL], ["mfxt", Viewport.SCALING_3D_MODE_METALFX_TEMPORAL],
			["fsr2", Viewport.SCALING_3D_MODE_FSR2], ["fsr1", Viewport.SCALING_3D_MODE_FSR]]:
		var at := state.find(m[0])
		if at >= 0:
			vp.scaling_3d_mode = m[1]
			vp.scaling_3d_scale = int(state.substr(at + 4, 2)) / 100.0
	probe_terrain.visible = not state.contains("noterrain")
	cloud_bodies.visible = not state.contains("noclouds")
	water_mi.visible = not state.contains("noocean")
	if river_mi != null:
		river_mi.visible = not state.contains("noriver")
	terrain_mat.set_shader_parameter("detail_enabled", not state.contains("nodetail"))
	terrain_mat.set_shader_parameter("material_enabled", not state.contains("nomaterial"))
	terrain_mat.set_shader_parameter("canopy_enabled", not state.contains("nocanopy"))
	vp.msaa_3d = Viewport.MSAA_DISABLED if state.contains("nomsaa") else probe_defaults["msaa"]
	var env: Environment = get_world_3d().environment if get_world_3d().environment != null else null
	for c in get_children():
		if c is WorldEnvironment:
			env = c.environment
	if env != null:
		env.ssao_enabled = not state.contains("nossao")
		env.fog_enabled = not state.contains("nofog")
	if probe_mesh_full == null:
		pass
	elif state.contains("grid360"):
		if probe_mesh_half == null:
			var pm := PlaneMesh.new()
			pm.size = Vector2(world_size, world_size)
			pm.subdivide_width = terrain_grid / 2 - 2
			pm.subdivide_depth = terrain_grid / 2 - 2
			probe_mesh_half = pm
		probe_terrain.mesh = probe_mesh_half
	else:
		probe_terrain.mesh = probe_mesh_full

@warning_ignore("integer_division")
func _probe_drawn() -> void:
	var now := Time.get_ticks_usec()
	if probe_elapsed < 3.0:
		probe_last = now
		return
	probe_frame += 1
	var block := probe_frame / BLOCK_FRAMES
	var in_block := probe_frame % BLOCK_FRAMES
	var n := probe_states.size()
	var round_index := block / n
	var state: String = probe_states[(block % n + round_index) % n]
	if in_block == 0:
		_probe_set(state)
	elif in_block >= SKIP_FRAMES and round_index > 0:
		var key := "%d:%s" % [round_index, state]
		if not probe_data.has(key):
			probe_data[key] = {"dt": [], "gpu": []}
		probe_data[key]["dt"].append((now - probe_last) / 1000.0)
		probe_data[key]["gpu"].append(RenderingServer.viewport_get_measured_render_time_gpu(
			get_viewport().get_viewport_rid()))
	if OS.has_environment("RS_PROBE_TS") and in_block == BLOCK_FRAMES - 1 and round_index == 1:
		_probe_timestamps(state)
	probe_last = now
	if round_index > probe_rounds:
		RenderingServer.frame_post_draw.disconnect(_probe_drawn)
		_probe_report()
		get_tree().quit()

func _probe_timestamps(state: String) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	var count := rd.get_captured_timestamps_count()
	var rows := []
	var prev := 0
	for i in count:
		var t := rd.get_captured_timestamp_gpu_time(i)
		if i > 0:
			rows.append("%s=%.3f" % [rd.get_captured_timestamp_name(i - 1), (t - prev) / 1000000.0])
		prev = t
	print("PROBE_TS ", state, " n=", count, " ", " ".join(rows))

@warning_ignore("integer_division")
static func _med(values: Array) -> float:
	var s := values.duplicate()
	s.sort()
	return s[s.size() / 2] if s.size() > 0 else -1.0

static func _p95(values: Array) -> float:
	var s := values.duplicate()
	s.sort()
	return s[int((s.size() - 1) * 0.95)] if s.size() > 0 else -1.0

func _probe_report() -> void:
	var out := {}
	for state in probe_states:
		var dt_meds := []
		var gpu_meds := []
		var dt_p95s := []
		for r in range(1, probe_rounds + 1):
			var d: Dictionary = probe_data.get("%d:%s" % [r, state], {"dt": [], "gpu": []})
			dt_meds.append(_med(d["dt"]))
			dt_p95s.append(_p95(d["dt"]))
			gpu_meds.append(_med(d["gpu"]))
		out[state] = {"frame_ms": snappedf(_med(dt_meds), 0.01), "frame_p95_ms": snappedf(_med(dt_p95s), 0.01),
			"gpu_ms": snappedf(_med(gpu_meds), 0.01), "gpu_rounds": gpu_meds}
	print("PROBE_RESULT ", JSON.stringify({"viewport": str(get_viewport().size), "rounds": probe_rounds,
		"states": out}))
