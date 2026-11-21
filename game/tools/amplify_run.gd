extends SceneTree
## Fährt den Gelände-Verfeinerer (#238) über eine Folge aus
## `tools/amplify_dump.gd` und schreibt seine Ausgabe als Rohdateien, für
## Bildvergleich, Stabilitätsmessung und Kosten.
## Braucht ein RenderingDevice, also ein Fenster (nicht `--headless`):
##
##   AMPLIFY_DUMP=/abs/dump AMPLIFY_OUT=/abs/aus godot --path game \
##     --script res://tools/amplify_run.gd
##
## `AMPLIFY_PARAMS` (JSON) überschreibt einzelne Werte aus
## `TerrainAmplifier.params`, `AMPLIFY_TICKS` begrenzt die Takte,
## `AMPLIFY_WRITE` wählt die Felder (Standard `offset,maps`).
## Je Takt `t`: `offset_<t>.rg16f` (fein: r Abweichung in Welteinheiten,
## g Maske), `maps_<t>.rgba` (fein), dazu `run.json` mit den Zeiten.

const TerrainAmplifier = preload("res://scripts/TerrainAmplifier.gd")

var started := false

func _process(_delta: float) -> bool:
	if started:
		return false
	started = true
	var dump := OS.get_environment("AMPLIFY_DUMP")
	var out := OS.get_environment("AMPLIFY_OUT")
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dump.path_join("meta.json")))
	if not TerrainAmplifier.available():
		print("AMPLIFY_RUN_SKIP kein RenderingDevice")
		quit(0)
		return true
	DirAccess.make_dir_recursive_absolute(out)
	var amp := TerrainAmplifier.new()
	if OS.has_environment("AMPLIFY_PARAMS"):
		var over: Dictionary = JSON.parse_string(OS.get_environment("AMPLIFY_PARAMS"))
		for key in over:
			amp.params[key] = over[key]
	# Tümpeltiefe und Codes aus dem Dump (WaterRender.pondContourLo,
	# ReliefRender.heightCode und slopeCode); ältere Dumps tragen sie nicht.
	if not amp.setup(int(meta["n"]), meta["world_size"], meta["hscale"], meta["sea_level"],
			meta.get("pond", 0.003), meta.get("height_code", 0.2), meta.get("slope_code", 0.015)):
		print("FAIL: Verfeinerer nicht eingerichtet")
		quit(1)
		return true
	var ticks := int(meta["ticks"])
	if OS.has_environment("AMPLIFY_TICKS"):
		ticks = mini(ticks, int(OS.get_environment("AMPLIFY_TICKS")))
	var write := "offset,maps"
	if OS.has_environment("AMPLIFY_WRITE"):
		write = OS.get_environment("AMPLIFY_WRITE")
	var times: Array = []
	for t in range(0, ticks + 1):
		var heights := FileAccess.get_file_as_bytes(dump.path_join("heights_%02d.f32" % t))
		var filled := FileAccess.get_file_as_bytes(dump.path_join("filled_%02d.f32" % t))
		var protect := FileAccess.get_file_as_bytes(dump.path_join("protect_%02d.u8" % t))
		var t0 := Time.get_ticks_usec()
		amp.submit(heights, filled, protect, true)
		var t1 := Time.get_ticks_usec()
		# Der Rückweg wartet auf die GPU: Zeit bis hier = Kosten des Auftrags.
		var lift := amp.read_cell_lift()
		var t2 := Time.get_ticks_usec()
		times.append({"submit_ms": (t1 - t0) / 1000.0, "total_ms": (t2 - t0) / 1000.0})
		for what in write.split(",", false):
			var ext: String = {"offset": "rg16f", "maps": "rgba", "relief": "rgba16f",
				"mean": "f32", "height": "rg32f", "flux": "rgba16f"}[what]
			var f := FileAccess.open(out.path_join("%s_%02d.%s" % [what, t, ext]), FileAccess.WRITE)
			f.store_buffer(amp.read_raw(what))
			f.close()
		var lf := FileAccess.open(out.path_join("lift_%02d.f32" % t), FileAccess.WRITE)
		lf.store_buffer(lift.to_byte_array())
		lf.close()
	var f := FileAccess.open(out.path_join("run.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"params": amp.params, "times": times, "passes": amp.passes_run}))
	f.close()
	print("AMPLIFY_RUN_OK ", out, " ", times)
	amp.free_resources()
	quit(0)
	return true
