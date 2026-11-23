extends SceneTree

const Main = preload("res://scripts/Main.gd")

var main: Node
var done := false

func _initialize() -> void:
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if done or main == null or not main.is_node_ready():
		return false
	done = true
	var out := OS.get_environment("AMPLIFY_DUMP")
	if out.is_empty():
		print("FAIL: AMPLIFY_DUMP fehlt")
		quit(1)
		return true
	DirAccess.make_dir_recursive_absolute(out)
	var ticks := int(OS.get_environment("AMPLIFY_TICKS")) if OS.has_environment("AMPLIFY_TICKS") else 12
	var years := float(OS.get_environment("AMPLIFY_TICK_YEARS")) if OS.has_environment("AMPLIFY_TICK_YEARS") else 15.0
	var sim: Object = main.sim
	var meta := {
		"n": main.N, "world_size": main.world_size, "hscale": main.hscale,
		"sea_level": main.sea, "ticks": ticks, "tick_years": years,
		"year": sim.currentYear(),
		"pond": Main.calibration(sim, "water")["water_pond_contour_lo"],
		"height_code": Main.calibration(sim, "relief")["relief_height_code"],
		"slope_code": Main.calibration(sim, "relief")["relief_slope_code"],
	}
	var f := FileAccess.open(out.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()
	var now := 1000.0
	_write(out, 0, sim.renderFrame(main.FRAME_SETTLED, now))
	for t in range(1, ticks + 1):
		sim.step(years)
		now += 1.0
		_write(out, t, sim.renderFrame(main.FRAME_TIMELAPSE, now))
	print("AMPLIFY_DUMP_OK ", out)
	main.queue_free()
	quit(0)
	return true

func _write(out: String, t: int, frame: Dictionary) -> void:
	for key in [["heights", "f32"], ["filled", "f32"], ["protect", "u8"], ["flow", "u8"],
			["surface", "rgba"], ["cover", "rgba"], ["water", "rgba"], ["forest", "u8"]]:
		if not frame.has(key[0]):
			continue
		var f := FileAccess.open(out.path_join("%s_%02d.%s" % [key[0], t, key[1]]), FileAccess.WRITE)
		f.store_buffer(frame[key[0]])
		f.close()
