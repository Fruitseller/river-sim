extends SceneTree
## Regression: synthetische Altarm-Overlays dürfen keine geschlossenen blauen
## Ringe mit trockener Mitte erzeugen. Prüft den öffentlichen Render-Pfad über
## SimNode.waterFieldBytes() beim deterministischen Standard-Seed.

const YEARS := 106_000
const LAKE_CHANNEL := 1
const VISIBLE_THRESHOLD := 32
const MIN_HOLE_CELLS := 4
const MAX_RING_HOLES := 0

func _initialize() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	var years := YEARS
	if OS.has_environment("RS_REPRO_YEARS"):
		years = int(OS.get_environment("RS_REPRO_YEARS"))
	for _step in range(int(years / 1000.0)):
		sim.step(1000.0)
	var n: int = sim.gridSize()
	var water: PackedByteArray = sim.waterFieldBytes(1.0)
	var rings := _count_enclosed_holes(water, n)
	sim.free()
	print("WATER_RINGS year=", years, " holes=", rings, " max=", MAX_RING_HOLES)
	if rings > MAX_RING_HOLES:
		push_error("FAIL: Altarm-Overlay erzeugt %d geschlossene Wasserringe" % rings)
		quit(1)
	else:
		print("WATER_RINGS_OK")
		quit(0)

func _count_enclosed_holes(water: PackedByteArray, n: int) -> int:
	var count := n * n
	var state := PackedByteArray()
	state.resize(count) # 0 = trocken/unbesucht, 1 = Wasser, 2 = trocken/besucht
	for k in range(count):
		state[k] = 1 if water[k * 4 + LAKE_CHANNEL] > VISIBLE_THRESHOLD else 0
	var queue := PackedInt32Array()
	queue.resize(count)
	var holes := 0
	for start in range(count):
		if state[start] != 0:
			continue
		var head := 0
		var tail := 1
		queue[0] = start
		state[start] = 2
		var component_size := 0
		var touches_boundary := false
		while head < tail:
			var cell: int = queue[head]
			head += 1
			component_size += 1
			var x := cell % n
			var y := int(cell / n)
			if x == 0 or x == n - 1 or y == 0 or y == n - 1:
				touches_boundary = true
			if x > 0 and state[cell - 1] == 0:
				state[cell - 1] = 2; queue[tail] = cell - 1; tail += 1
			if x < n - 1 and state[cell + 1] == 0:
				state[cell + 1] = 2; queue[tail] = cell + 1; tail += 1
			if y > 0 and state[cell - n] == 0:
				state[cell - n] = 2; queue[tail] = cell - n; tail += 1
			if y < n - 1 and state[cell + n] == 0:
				state[cell + n] = 2; queue[tail] = cell + n; tail += 1
		if not touches_boundary and component_size >= MIN_HOLE_CELLS:
			holes += 1
	return holes
