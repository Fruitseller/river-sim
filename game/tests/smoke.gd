extends SceneTree
## Headless-Smoke-Test der GDExtension — GPU-frei ausführbar mit:
##   godot --headless --path game --script res://tests/smoke.gd
## Prüft: SimNode registriert, Felder haben n*n Einträge, step() verändert das
## Terrain, Jahr läuft, Sculpting wirkt. Exit-Code != 0 bei Fehler.

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	var n: int = sim.gridSize()
	var h0: PackedFloat32Array = sim.heights()
	print("grid=", n, " sea=", sim.seaLevel(), " heights_len=", h0.size())
	if h0.size() != n * n:
		push_error("FAIL: heights-Länge %d != %d" % [h0.size(), n * n])
		quit(1)
		return

	sim.step(10000.0)
	var h1: PackedFloat32Array = sim.heights()
	var diff := 0.0
	for i in range(h1.size()):
		diff += absf(h1[i] - h0[i])
	print("year=", sim.currentYear(), " erosion_change_sum=", diff)
	if sim.currentYear() < 9999.0 or diff <= 0.0:
		push_error("FAIL: step() ohne Wirkung")
		quit(1)
		return

	# Sculpting: Zentrum anheben.
	var before: PackedFloat32Array = sim.heights()
	var c := (n / 2) * n + (n / 2)
	for k in range(50):
		sim.sculpt(float(n) / 2.0, float(n) / 2.0, 12.0, 1.0)
	sim.recomputeFlow()
	var after: PackedFloat32Array = sim.heights()
	print("sculpt_delta_center=", after[c] - before[c])
	if after[c] - before[c] <= 0.0:
		push_error("FAIL: sculpt hebt nicht an")
		quit(1)
		return

	print("SMOKE_OK")
	quit(0)
