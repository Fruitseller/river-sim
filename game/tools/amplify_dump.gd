extends SceneTree
## Schreibt eine Zeitraffer-Folge echter Sim-Daten als Rohdateien, für die
## Offline-Entwicklung und den Stabilitätsnachweis des Gelände-Verfeinerers
## (#238). Läuft headless, die Sim rechnet auf der CPU:
##
##   RS_SEED=1337 RS_STEP=20000 AMPLIFY_DUMP=/abs/ordner AMPLIFY_TICKS=12 \
##     AMPLIFY_TICK_YEARS=15 godot --headless --path game \
##     --script res://tools/amplify_dump.gd
##
## Je Takt `t`: `heights_<t>.f32` (n², Float32, Sim-Höhe 0…1),
## `filled_<t>.f32` (Seespiegel), `protect_<t>.u8` (Schutzmaske),
## `flow_<t>.u8`, `surface_<t>.rgba`, `cover_<t>.rgba`, `water_<t>.rgba`,
## dazu einmal `meta.json` (n, Weltgröße, Überhöhung, Meeresspiegel).
## Takt 0 ist der eingeschwungene Stand (FRAME_SETTLED), danach
## Zeitraffer-Takte wie in `Main._process`.

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
		# Was der Verfeinerer aus dem Kalibrier-Register braucht.
		"pond": Main.calibration(sim, "water")["water_pond_contour_lo"],
		"height_code": Main.calibration(sim, "relief")["relief_height_code"],
		"slope_code": Main.calibration(sim, "relief")["relief_slope_code"],
	}
	var f := FileAccess.open(out.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()
	# Die Overlay-Drossel (0,30 s) läuft über die Uhr des Aufrufers: je Takt
	# eine Sekunde, dann bringt jeder Frame alle Overlays mit.
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
