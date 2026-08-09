extends SceneTree
## Headless-Smoke-Test der GDExtension — GPU-frei ausführbar mit:
##   godot --headless --path game --script res://tests/smoke.gd
## Prüft: Library aktuell (Build-Stempel), SimNode registriert, Felder haben n*n
## Einträge, step() verändert das Terrain, Jahr läuft, Sculpting wirkt.
## Exit-Code != 0 bei Fehler.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

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

	# Zuerst prüfen, ob die geladene Library zum Quellstand passt: alles danach
	# testet sonst eine alte .so, und Fehlschläge sind dann irreführend
	# (historisch: "Nonexistent function brush" nach vergessenem Rebuild).
	if not BuildStamp.check(sim):
		quit(1)
		return

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

	# Brush-Werkzeuge (Modi siehe SimNode.brush): Spitzhacke senkt, Einebnen
	# zieht zur Zielhöhe, Glätten reduziert die lokale Rauheit.
	var cx := float(n) / 2.0
	before = sim.heights()
	for k in range(30):
		sim.brush(5, cx, cx, 8.0, 1.0, 0.0) # Spitzhacke
	after = sim.heights()
	print("pickaxe_delta_center=", after[c] - before[c])
	if after[c] - before[c] >= 0.0:
		push_error("FAIL: Spitzhacke senkt nicht ab")
		quit(1)
		return

	var target := after[c] + 0.1
	for k in range(200):
		sim.brush(3, cx, cx, 8.0, 2.0, target) # Einebnen
	after = sim.heights()
	print("flatten_dist_to_target=", absf(after[c] - target))
	if absf(after[c] - target) > 0.02:
		push_error("FAIL: Einebnen erreicht die Zielhöhe nicht")
		quit(1)
		return

	for k in range(20):
		sim.brush(4, cx, cx, 10.0, 1.0, 0.0) # Aufrauen
	var rough: PackedFloat32Array = sim.heights()
	var vr_before := _local_roughness(rough, n, c)
	for k in range(60):
		sim.brush(2, cx, cx, 10.0, 2.0, 0.0) # Glätten
	var smoothed: PackedFloat32Array = sim.heights()
	var vr_after := _local_roughness(smoothed, n, c)
	print("roughness_before=", vr_before, " after_smooth=", vr_after)
	if vr_after >= vr_before:
		push_error("FAIL: Glätten reduziert die Rauheit nicht")
		quit(1)
		return

	print("SMOKE_OK")
	quit(0)

## Mittlere absolute Nachbar-Differenz in einem 9×9-Fenster um Zelle c.
func _local_roughness(h: PackedFloat32Array, n: int, c: int) -> float:
	var ci := c % n
	var cj := c / n
	var s := 0.0
	var cnt := 0
	for j in range(cj - 4, cj + 5):
		for i in range(ci - 4, ci + 4):
			var k := j * n + i
			s += absf(h[k + 1] - h[k])
			cnt += 1
	return s / cnt
