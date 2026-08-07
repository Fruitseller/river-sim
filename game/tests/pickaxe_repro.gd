extends SceneTree
## Repro-Loop für die Spitzhacke: carvt eine Kerbe vom stärksten Fluss zur Küste
## und prüft getrennt (a) PHYSIK: der Abfluss folgt der Kerbe (flowArea steigt),
## (b) RENDER: das Wasser-Overlay (waterFieldBytes) zeigt den neuen Lauf.
##   godot --headless --path game --script res://tests/pickaxe_repro.gd

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	var sim: Object = ClassDB.instantiate("SimNode")
	var n: int = sim.gridSize()
	var sea: float = sim.seaLevel()
	var world: float = sim.worldSize()
	var cell: float = world / float(n - 1)
	var cell_area := cell * cell

	sim.step(3000.0) # Flüsse etablieren (inkl. Stream-Map)
	var h: PackedFloat32Array = sim.heights()
	var area: PackedFloat32Array = sim.flowArea()

	# Stärkste Fluss-Zelle im Landesinneren (Abstand zum Rand, damit die Kerbe Platz hat).
	var best := -1
	var best_a := 0.0
	for j in range(80, n - 80):
		for i in range(80, n - 80):
			var k := j * n + i
			if h[k] > sea + 0.08 and area[k] > best_a:
				best_a = area[k]
				best = k
	if best < 0:
		push_error("FAIL_SETUP: keine Fluss-Zelle gefunden")
		quit(1)
		return
	var bi := best % n
	var bj := best / n
	print("river_cell=(", bi, ",", bj, ") area_cells=", best_a / cell_area, " h=", h[best])

	# Kerbenrichtung: zur nächsten Kante (dorthin ist die Küste am nächsten).
	var di := 0
	var dj := 0
	if mini(bi, n - 1 - bi) < mini(bj, n - 1 - bj):
		di = -1 if bi < n - bi else 1
	else:
		dj = -1 if bj < n - bj else 1

	# Kerbe carven: schmaler Pinsel (≈2 Zellen), Tiefe kontrolliert per Rücklesen
	# in mehreren Pässen — leicht bergab Richtung Küste, über Meeresniveau.
	var trench: Array[int] = []
	var length := 120
	var depth_start: float = h[best] - 0.03
	for s in range(1, length + 1):
		var ti := bi + di * s
		var tj := bj + dj * s
		if ti < 1 or ti >= n - 1 or tj < 1 or tj >= n - 1:
			break
		var k := tj * n + ti
		if h[k] <= sea: # Küste erreicht
			break
		trench.append(k)
	for pass_i in range(24):
		var h_now: PackedFloat32Array = sim.heights()
		var open := 0
		for idx in range(trench.size()):
			var k: int = trench[idx]
			var target := maxf(sea + 0.04, depth_start - 0.0015 * (idx + 1))
			if h_now[k] > target:
				open += 1
				sim.brush(5, float(k % n), float(k / n), 0.3, 1.0, 0.0)
		if open == 0:
			break
	sim.recomputeFlow()
	print("trench_len=", trench.size())

	# Höhenprofil der Kerbe nach dem Carven: Tiefe & Monotonie.
	var h2: PackedFloat32Array = sim.heights()
	var prof := ""
	var non_monotone := 0
	for idx in range(trench.size()):
		var k: int = trench[idx]
		if idx % 10 == 0:
			prof += "%.3f " % h2[k]
		if idx > 0 and h2[k] > h2[trench[idx - 1]] + 0.001:
			non_monotone += 1
	print("carved_profile=", prof, " non_monotone=", non_monotone,
		" river_h_after=", h2[best])

	# Receiver-Pfad ab der Fluss-Zelle: läuft er durch die Kerbe?
	var recv: PackedInt32Array = sim.receivers()
	var in_band := 0
	var walk := best
	var path := ""
	for s2 in range(200):
		walk = recv[walk]
		if walk < 0:
			break
		var wi := walk % n
		var wj := walk / n
		if s2 < 12:
			path += "(%d,%d) " % [wi, wj]
		for t in trench:
			if absi(t % n - wi) <= 2 and absi(t / n - wj) <= 2:
				in_band += 1
				break
	print("walk_first=", path, " walk_cells_in_trench_band=", in_band)

	# (a) PHYSIK: maximales Einzugsgebiet im Kerben-Band (±2 Zellen quer).
	area = sim.flowArea()
	var band_max := 0.0
	for idx in range(trench.size() / 4, trench.size() * 3 / 4):
		var k: int = trench[idx]
		var ki := k % n
		var kj := k / n
		for dj2 in range(-2, 3):
			for di2 in range(-2, 3):
				band_max = maxf(band_max, area[(kj + dj2) * n + ki + di2])
	var mid_cells := band_max / cell_area
	print("trench_band_max_area_cells=", mid_cells)
	var physics_ok := mid_cells > 300.0 # > renderMinCells: müsste als Fluss zählen

	# (b) RENDER: Wasser-Overlay entlang der Kerbe (R = Fluss, G = See).
	var wb: PackedByteArray = sim.waterFieldBytes(1.0)
	var painted := 0
	var lake_cells := 0
	var probe := 0
	for idx in range(trench.size() / 4, trench.size() * 3 / 4): # mittlere Hälfte
		var k: int = trench[idx]
		probe += 1
		if wb[k * 4] > 40:
			painted += 1
		if wb[k * 4 + 1] > 40:
			lake_cells += 1
	print("render_painted=", painted, "/", probe, " lake_cells=", lake_cells)
	var render_ok := painted > probe / 2

	if not physics_ok:
		push_error("FAIL_PHYSICS: Kerbe kapert den Fluss nicht (area=" + str(mid_cells) + ")")
		quit(1)
		return
	if not render_ok:
		push_error("FAIL_RENDER: Fluss folgt der Kerbe, aber das Overlay zeigt ihn nicht")
		quit(1)
		return
	# (c) LANGZEIT: der Fluss hält die gekaperte Rinne offen, aber übertiefte
	# Stellen (Seen in der Kerbe) füllen sich über die Zeit mit Sediment.
	var depth0 := _trench_pond_depth(sim, trench)
	sim.step(1500.0)
	var depth1 := _trench_pond_depth(sim, trench)
	area = sim.flowArea()
	var band_max2 := 0.0
	for idx in range(trench.size() / 4, trench.size() * 3 / 4):
		var k: int = trench[idx]
		for dj3 in range(-3, 4):
			for di3 in range(-3, 4):
				band_max2 = maxf(band_max2, area[(k / n + dj3) * n + k % n + di3])
	print("pond_depth_after_carve=", depth0, " after_1500y=", depth1,
		" band_area_after=", band_max2 / cell_area)
	if band_max2 / cell_area < 300.0:
		push_error("FAIL_PERSIST: Fluss verlässt die Kerbe nach 1500 Jahren")
		quit(1)
		return
	if depth1 > depth0 * 0.8:
		push_error("FAIL_INFILL: Kerben-Seen füllen sich nicht auf (%.4f → %.4f)" % [depth0, depth1])
		quit(1)
		return

	# (d) DECKEL: auch mit riesigem Slider-Radius bleibt der Hieb schmal.
	var spot_i := bi + 60 * dj # abseits der Kerbe (senkrecht versetzt)
	var spot_j := bj + 60 * di
	var h3: PackedFloat32Array = sim.heights()
	for r in range(20):
		sim.brush(5, float(spot_i), float(spot_j), 10.0, 3.0, 0.0)
	var h4: PackedFloat32Array = sim.heights()
	var max_reach := 0
	for off in range(1, 40):
		if spot_i + off < n and absf(h4[spot_j * n + spot_i + off] - h3[spot_j * n + spot_i + off]) > 0.005:
			max_reach = off
	print("pickaxe_reach_cells=", max_reach)
	if max_reach > 4:
		push_error("FAIL_CAP: Spitzhacke wirkt " + str(max_reach) + " Zellen weit trotz Deckel")
		quit(1)
		return

	print("PICKAXE_OK")
	quit(0)

## Mittlere Wassertiefe (hf − h) über den Kerben-Zellen — misst die Übertiefung.
func _trench_pond_depth(sim: Object, trench: Array[int]) -> float:
	var hh: PackedFloat32Array = sim.heights()
	var hfx: PackedFloat32Array = sim.filled()
	var s := 0.0
	for k in trench:
		s += maxf(0.0, hfx[k] - hh[k])
	return s / trench.size()
