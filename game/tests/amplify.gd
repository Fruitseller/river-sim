extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const TerrainAmplifier = preload("res://scripts/TerrainAmplifier.gd")

const NUDGE := 2.0e-4
const MAX_GAIN := 16.0
const REACH_CELLS := 72

var failures := 0
var main: Node
var done := false
var waited := 0

func _initialize() -> void:
	if not ClassDB.class_exists("SimNode"):
		print("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var probe: Object = ClassDB.instantiate("SimNode")
	var stamp_ok: bool = BuildStamp.check(probe)
	probe.free()
	if not stamp_ok:
		quit(1)
		return
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if done or main == null or not main.is_node_ready():
		return false
	waited += 1
	if waited < 4:
		return false
	done = true
	if not TerrainAmplifier.available():
		_check(main.amplifier == null and main.relief_vp != null,
			"Ohne RenderingDevice backt Main weiter mit relief_bake.gdshader")
		print("AMPLIFY: kein RenderingDevice, GPU-Teil übersprungen")
	else:
		_check_main_contract()
		_check_amplifier()
	main.queue_free()
	if failures > 0:
		quit(1)
		return true
	print("AMPLIFY_OK")
	quit(0)
	return true

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)

func _check_main_contract() -> void:
	_check(main.amplifier != null, "Mit RenderingDevice rechnet der Verfeinerer")
	if main.amplifier == null:
		return
	var mat: ShaderMaterial = main.terrain_mat
	_check(mat.get_shader_parameter("relief_enabled") == true
		and mat.get_shader_parameter("amplify_enabled") == true,
		"Der erste Stand ist nach dem Aufbau veröffentlicht")
	var lod: float = mat.get_shader_parameter("amplify_vertex_lod")
	var expect: float = log(float(main.N * TerrainAmplifier.FACTOR) / float(main.terrain_grid)) / log(2.0)
	_check(absf(lod - expect) < 1e-6, "Das Netz liest die Mip-Stufe seines Vertexabstands (%s)" % lod)
	main.relief_bake_frame = Engine.get_frames_drawn() - 1
	main._relief_cpu()
	var lift: PackedFloat32Array = main.amplifier.read_cell_lift()
	_check(main.relief_lift_cache.size() == main.N * main.N and main.relief_lift_cache == lift,
		"Pinselkuppel, Raycast und Kameraziel lesen die Fläche des Verfeinerers")
	var moved := 0
	for v in lift:
		if absf(v - 0.5) > 1e-4:
			moved += 1
	_check(moved > main.N, "Die Verfeinerung verschiebt die sichtbare Fläche (%d Zellen)" % moved)

func _check_amplifier() -> void:
	var sim: Object = main.sim
	var n: int = main.N
	var frame: Dictionary = sim.renderFrame(main.FRAME_SETTLED, main._now() + 10.0)
	var heights: PackedByteArray = frame["heights"]
	var filled: PackedByteArray = frame["filled"]
	var protect: PackedByteArray = frame["protect"]
	var relief: Dictionary = Main.calibration(sim, "relief")
	var pond: float = Main.calibration(sim, "water")["water_pond_contour_lo"]
	var code: float = relief["relief_height_code"]
	var amp := TerrainAmplifier.new()
	_check(amp.setup(n, main.world_size, main.hscale, main.sea, pond, code,
		relief["relief_slope_code"]), "Verfeinerer richtet sich ein")

	amp.submit(heights, filled, protect, true)
	var first := amp.read_cell_lift()
	var first_fine := amp.read_raw("offset")
	var first_relief := amp.read_raw("relief")
	var first_maps := amp.read_raw("maps")
	_check_binding(n, heights.to_float32_array(), filled.to_float32_array(), protect, pond,
		first, first_fine, amp.params, code)

	amp.submit(heights, filled, protect, true)
	_check(amp.read_raw("offset") == first_fine and amp.read_cell_lift() == first,
		"Gleicher Eingang gibt bit-gleichen Ausgang")

	amp.submit(heights, filled, protect, false)
	var rounds := 0
	while amp.busy() and rounds < 1000:
		amp.advance(true, 0.02, 0.3)
		rounds += 1
	_check(rounds > 3, "Der verteilte Auftrag läuft über mehrere Bilder (%d)" % rounds)
	_check(amp.read_raw("offset") == first_fine and amp.read_raw("relief") == first_relief
		and amp.read_raw("maps") == first_maps and amp.read_cell_lift() == first,
		"Verteilt gerechnet gibt dasselbe wie in einem Zug (Abweichung, Fläche, Karten)")

	var h := heights.to_float32_array()
	var cx := n / 2
	var cz := n / 2
	var radius := 5
	for j in range(cz - radius, cz + radius + 1):
		for i in range(cx - radius, cx + radius + 1):
			h[j * n + i] += NUDGE * (1.0 if (i + j) % 2 == 0 else -1.0)
	amp.submit(h.to_byte_array(), filled, protect, true)
	var nudged := amp.read_cell_lift()
	var nudged_fine := amp.read_raw("offset")
	var fine_n := n * TerrainAmplifier.FACTOR
	var row_bytes := fine_n * 4
	var top := (cz - radius - REACH_CELLS) * TerrainAmplifier.FACTOR * row_bytes
	var bottom := (cz + radius + REACH_CELLS + 1) * TerrainAmplifier.FACTOR * row_bytes
	_check(top > 0 and bottom < nudged_fine.size()
		and nudged_fine.slice(0, top) == first_fine.slice(0, top)
		and nudged_fine.slice(bottom) == first_fine.slice(bottom),
		"Außerhalb der Reichweite ist auch das feine Feld bit-gleich")
	_check(nudged_fine != first_fine, "Die Störung kommt im feinen Feld an")
	var worst := 0.0
	var far := 0
	for j in n:
		for i in n:
			var d := absf(nudged[j * n + i] - first[j * n + i]) / code
			worst = maxf(worst, d)
			if d > 0.0 and maxi(absi(i - cx), absi(j - cz)) > radius + REACH_CELLS:
				far += 1
	var gain: float = worst / (NUDGE * main.hscale)
	print("AMPLIFY: Störung %.5f Welteinheiten, größte Antwort %.5f (Faktor %.2f)"
		% [NUDGE * main.hscale, worst, gain])
	_check(worst > 0.0, "Die Störung kommt in der Fläche an")
	_check(gain <= MAX_GAIN, "Kleine Änderung gibt kleine Änderung (Faktor %.2f)" % gain)
	_check(far == 0, "Eine Änderung wirkt nur in fester Reichweite (%d Zellen außerhalb)" % far)

	var before: int = amp.published
	amp.submit(h.to_byte_array(), filled, protect, false)
	for i in 400:
		amp.advance(false, 0.02, 0.1)
	_check(amp.busy() and amp.published == before,
		"Während der Blende bleibt das Ausgabe-Ziel unberührt")
	amp.submit(heights, PackedByteArray(), PackedByteArray(), false)
	rounds = 0
	while amp.busy() and rounds < 4000:
		amp.advance(true, 0.02, 0.1)
		rounds += 1
	_check(amp.published == before + 2, "Der wartende Eingang wird nach dem laufenden gerechnet")
	_check(amp.read_raw("offset") == first_fine, "Am Ende steht der Stand des zuletzt eingereichten Eingangs")

	amp.params["mean_window"] = 0.0
	amp.submit(heights, filled, protect, true)
	var strict := amp.read_cell_lift()
	var mask := _free_cells(n, heights.to_float32_array(), filled.to_float32_array(), protect, pond, 8)
	var residual: Array[float] = []
	for k in n * n:
		if mask[k] == 1:
			residual.append(absf(strict[k] - 0.5) / code)
	residual.sort()
	var strict_p99: float = residual[int(float(residual.size() - 1) * 0.99)]
	var strict_worst: float = residual[residual.size() - 1]
	print("AMPLIFY: strenges Zellmittel, Abweichung p99 %.5f, größte %.5f Welteinheiten"
		% [strict_p99, strict_worst])
	var down: float = amp.params["bound_down"]
	_check(strict_p99 <= 0.02 * down and strict_worst <= 0.1 * down,
		"Streng bleibt das Mittel jeder freien Zelle erhalten (p99 %.5f, max %.5f)"
			% [strict_p99, strict_worst])
	amp.free_resources()

func _check_binding(n: int, h: PackedFloat32Array, filled: PackedFloat32Array,
		protect: PackedByteArray, pond: float, lift: PackedFloat32Array,
		fine: PackedByteArray, params: Dictionary, code: float) -> void:
	var down: float = params["bound_down"]
	var up: float = params["bound_up"]
	var k_fine: int = TerrainAmplifier.FACTOR
	var fine_n := n * k_fine
	var img := Image.create_from_data(fine_n, fine_n, false, Image.FORMAT_RGH, fine)
	img.convert(Image.FORMAT_RGF)
	var off := img.get_data().to_float32_array()
	var lo := 0.0
	var hi := 0.0
	var broken := 0
	var k := 0
	while k < off.size():
		var v := off[k]
		if is_nan(v) or is_inf(v):
			broken += 1
		lo = minf(lo, v)
		hi = maxf(hi, v)
		k += 2 * 3
	print("AMPLIFY: Abweichung %.4f … %.4f Welteinheiten (Schranke −%.2f … +%.2f)" % [lo, hi, down, up])
	_check(broken == 0, "Keine NaN in der Fläche (%d)" % broken)
	_check(lo >= -down - 1e-3 and hi <= up + 1e-3, "Die Abweichung bleibt in der Schranke")
	_check(lo < -0.01 and hi > 0.01, "Die Verfeinerung formt überhaupt (%.4f … %.4f)" % [lo, hi])
	var sea: float = main.sea
	var shield := 0.0
	var shield_cells := 0
	var coast := 0.0
	var coast_cells := 0
	var water := 0.0
	var water_cells := 0
	var sum := 0.0
	var free := 0
	var free_cells := _free_cells(n, h, filled, protect, pond, 10)
	for j in range(1, n - 1):
		for i in range(1, n - 1):
			var c := j * n + i
			var is_protect := protect[c] == 255
			var all_sea := true
			var all_wet := true
			for dj in [-1, 0, 1]:
				for di in [-1, 0, 1]:
					var q: int = c + dj * n + di
					all_sea = all_sea and h[q] < sea + 0.008
					all_wet = all_wet and filled[q] - h[q] >= pond
			if is_protect or all_sea or all_wet:
				var cell_hi := 0.0
				var cell_abs := 0.0
				for b in k_fine:
					for a in k_fine:
						var v: float = off[((j * k_fine + b) * fine_n + i * k_fine + a) * 2]
						cell_hi = maxf(cell_hi, v)
						cell_abs = maxf(cell_abs, absf(v))
				if is_protect:
					shield = maxf(shield, cell_abs)
					shield_cells += 1
				if all_sea:
					coast = maxf(coast, cell_abs)
					coast_cells += 1
				if all_wet:
					water = maxf(water, cell_hi)
					water_cells += 1
			if free_cells[c] == 1:
				sum += (lift[c] - 0.5) / code
				free += 1
	print("AMPLIFY: geprüft %d Zellen Schutzmaske, %d Meer, %d stehendes Wasser"
		% [shield_cells, coast_cells, water_cells])
	_check(shield_cells > 0 and shield == 0.0,
		"In der Schutzmaske (Wasser, Bänder, Saum) ist die Abweichung auf der ganzen Zelle null (%s)" % shield)
	_check(coast_cells > 0 and coast == 0.0, "Im Meer und am Küstensaum ist die Abweichung null (%s)" % coast)
	_check(water == 0.0, "Wo Wasser steht, liegt die Fläche nie über dem Spiegel (%s)" % water)
	var mean := sum / maxf(float(free), 1.0)
	print("AMPLIFY: Mittel über %d freie Zellen %.5f Welteinheiten" % [free, mean])
	_check(free > n and absf(mean) <= 0.01 * down, "Über das freie Land gemittelt bleibt die Sim-Höhe (%.5f)" % mean)

func _free_cells(n: int, h: PackedFloat32Array, filled: PackedFloat32Array,
		protect: PackedByteArray, pond: float, margin: int) -> PackedByteArray:
	var blocked := PackedByteArray()
	blocked.resize(n * n)
	for k in n * n:
		blocked[k] = 1 if protect[k] != 0 or h[k] < main.sea + 0.04 \
			or filled[k] - h[k] >= pond * 0.5 else 0
	var wide := PackedByteArray()
	wide.resize(n * n)
	for j in n:
		var run := 0
		for i in range(-margin, n):
			var ahead := i + margin
			run = margin * 2 + 1 if ahead < n and blocked[j * n + ahead] == 1 else run - 1
			if i >= 0:
				wide[j * n + i] = 1 if run > 0 else 0
	var out := PackedByteArray()
	out.resize(n * n)
	for i in n:
		var run := 0
		for j in range(-margin, n):
			var ahead := j + margin
			run = margin * 2 + 1 if ahead < n and wide[ahead * n + i] == 1 else run - 1
			if j >= 0:
				out[j * n + i] = 0 if run > 0 else 1
	return out
