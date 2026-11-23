extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")

const FRAME_SETTLED := 0

var kind_river: float
var kind_delta: float
var kind_oxbow: float
var pond_contour_lo: float
var lake_raw_wet: float
var max_oxbow_opacity: float
var mouth_search_cells: int
var join_coverage: float

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim):
		quit(1)
		return
	var contract := Main.calibration(sim, "water_contract")
	kind_river = contract["ribbonKindRiver"]
	kind_delta = contract["ribbonKindDelta"]
	kind_oxbow = contract["ribbonKindOxbow"]
	pond_contour_lo = contract["pondContourLo"]
	lake_raw_wet = contract["lakeRawWetDepth"]
	max_oxbow_opacity = contract["oxbowMaximumOpacity"]
	mouth_search_cells = int(contract["mouthSearchCells"])
	join_coverage = contract["ribbonJoinCoverage"]
	if not _check_inside_other_river_guard():
		quit(1)
		return

	var strict := true
	var years := 80000.0
	if OS.has_environment("RS_STEP"):
		years = float(OS.get_environment("RS_STEP"))
		strict = false
	if OS.has_environment("RS_SEED"):
		sim.generate(int(OS.get_environment("RS_SEED")))
		strict = false
	var now := 0.0
	var banded: Dictionary = {}
	var y := 0.0
	while y < years:
		sim.step(1000.0)
		y += 1000.0
		if strict and y >= 20000.0:
			sim.recomputeFlow()
			now += 1.0
			var frame: Dictionary = sim.renderFrame(FRAME_SETTLED, now)
			if frame.has("ribbons"):
				banded = frame
			if _has_kind(banded, kind_oxbow) and _has_kind(banded, kind_delta):
				break
	years = y
	sim.recomputeFlow()
	now += 1.0
	var frame: Dictionary = sim.renderFrame(FRAME_SETTLED, now)
	if frame.has("ribbons"):
		banded = frame
	if banded.is_empty():
		push_error("FAIL: kein Frame mit Band-Bau nach %d Jahren" % int(years))
		quit(1)
		return

	var h_before: PackedFloat32Array = sim.heights()
	var t0 := Time.get_ticks_usec()
	now += 1.0
	sim.renderFrame(FRAME_SETTLED, now)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	if sim.heights() != h_before:
		push_error("FAIL: der Frame verändert die Sim-Höhen")
		quit(1)
		return

	var verts: PackedVector3Array = banded["ribbon_verts"]
	var cols: PackedColorArray = banded["ribbon_colors"]
	var uv2s: PackedVector2Array = banded["ribbon_uv2s"]
	var starts: PackedInt32Array = banded["ribbon_strip_starts"]
	if verts.size() < 4 or starts.size() < 1:
		push_error("FAIL: keine Wasser-Geometrie nach %d Jahren" % int(years))
		quit(1)
		return
	if uv2s.size() != verts.size():
		push_error("FAIL: UV2-Puffer (Typ-Kanal) hat die falsche Länge")
		quit(1)
		return

	var n: int = sim.gridSize()
	var world: float = sim.worldSize()
	var sea: float = sim.seaLevel()
	var cs := world / float(n - 1)
	var h: PackedFloat32Array = sim.heights()
	var wl: PackedFloat32Array = (frame["filled"] as PackedByteArray).to_float32_array()
	var rec: PackedInt32Array = sim.receivers()

	var strip_kind := {kind_river: 0, kind_delta: 0, kind_oxbow: 0}
	var deep_river_alpha := 0.0
	var oxbow_alpha_max := 0.0
	var oxbow_still := true
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		var kind: float = uv2s[from].x
		if not strip_kind.has(kind):
			push_error("FAIL: unbekannter Band-Typ %f in UV2.x" % kind)
			quit(1)
			return
		strip_kind[kind] += 1
		for a in range(from, to, 2):
			var k := _cell_of(verts[a], verts[a + 1], world, cs, n)
			var pond: float = _pond(h, wl, sea, k)
			if kind == kind_river and pond >= lake_raw_wet:
				deep_river_alpha = maxf(deep_river_alpha, cols[a].a)
			if kind == kind_oxbow:
				oxbow_alpha_max = maxf(oxbow_alpha_max, cols[a].a)
				if absf(cols[a].r - 0.5) > 0.002 or absf(cols[a].g - 0.5) > 0.002:
					oxbow_still = false
	print("frame_ms=", build_ms, " verts=", verts.size(), " bänder=", strip_kind)
	print("max_alpha_fluss_im_rasterwasser=", deep_river_alpha,
		" oxbow_alpha_max=", oxbow_alpha_max)

	if deep_river_alpha > 0.02:
		push_error("FAIL: Fluss-Band deckt noch im Raster-Seewasser (alpha=%f)"
			% deep_river_alpha)
		quit(1)
		return
	if strict and strip_kind[kind_oxbow] < 1:
		push_error("FAIL: keine Altarm-Bänder nach %d Jahren" % int(years))
		quit(1)
		return
	if not oxbow_still:
		push_error("FAIL: Altarm-Band trägt eine Fließrichtung (kein Stillwasser)")
		quit(1)
		return
	if oxbow_alpha_max > max_oxbow_opacity + 0.001:
		push_error("FAIL: Altarm-Deckkraft über dem Maximum (%f)" % oxbow_alpha_max)
		quit(1)
		return
	if strict and strip_kind[kind_delta] < 1:
		push_error("FAIL: kein einziger Delta-Arm — Mündungen ohne Auffächerung")
		quit(1)
		return

	var closed := 0
	var joined := 0
	var gaps := 0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x != kind_river:
			continue
		var last := to - 2
		var k := _cell_of(verts[last], verts[last + 1], world, cs, n)
		if _is_water(h, wl, sea, k):
			closed += 1
			continue
		if _inside_other_river(verts, cols, uv2s, starts, s, (verts[last] + verts[last + 1]) * 0.5, cs):
			joined += 1
			continue
		var c := k
		for _i in mouth_search_cells:
			var r := rec[c]
			if r < 0:
				break
			c = int(r)
			if _is_water(h, wl, sea, c):
				gaps += 1
				break
	print("fluss_bänder=", strip_kind[kind_river], " mündungen_im_wasser=", closed,
		" zusammenflüsse=", joined, " mündungen_mit_spalt=", gaps)
	if gaps > 0:
		push_error("FAIL: %d Fluss-Band(-Enden) enden vor der Wasserfläche" % gaps)
		quit(1)
		return

	print("WATER_GEOMETRY_OK")
	quit(0)

func _inside_other_river(verts: PackedVector3Array, cols: PackedColorArray,
		uv2s: PackedVector2Array, starts: PackedInt32Array, own: int,
		point: Vector3, cs: float) -> bool:
	var p2 := Vector2(point.x, point.z)
	for s in starts.size():
		var from: int = starts[s]
		if s == own or uv2s[from].x != kind_river:
			continue
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		for q in range(from, to - 3, 2):
			var a0 := cols[q].a
			var a1 := cols[q + 2].a
			if maxf(a0, a1) < join_coverage:
				continue
			var hw0 := Vector2(verts[q].x - verts[q + 1].x, verts[q].z - verts[q + 1].z).length() * 0.5
			var hw1 := Vector2(verts[q + 2].x - verts[q + 3].x, verts[q + 2].z - verts[q + 3].z).length() * 0.5
			if maxf(hw0, hw1) <= 0.0:
				continue
			var m0 := Vector2((verts[q].x + verts[q + 1].x) * 0.5, (verts[q].z + verts[q + 1].z) * 0.5)
			var m1 := Vector2((verts[q + 2].x + verts[q + 3].x) * 0.5, (verts[q + 2].z + verts[q + 3].z) * 0.5)
			var d := m1 - m0
			var len2 := d.length_squared()
			var t_raw := (p2 - m0).dot(d) / len2 if len2 > 1e-12 else 0.0
			var overhang := 0.5 * cs / sqrt(len2) if len2 > 1e-12 else 0.0
			if q == from and t_raw < -overhang:
				continue
			if q + 2 == to - 2 and t_raw > 1.0 + overhang:
				continue
			var t := clampf(t_raw, 0.0, 1.0)
			var alpha := lerpf(a0, a1, t)
			var hw := lerpf(hw0, hw1, t)
			if alpha >= join_coverage and hw > 0.0 and p2.distance_to(m0 + d * t) <= hw + cs:
				return true
	return false

func _check_inside_other_river_guard() -> bool:
	var cs := 2.0
	var verts := PackedVector3Array([
		Vector3(0.0, 0.0, -2.0), Vector3(0.0, 0.0, 2.0),
		Vector3(4.0, 0.0, -2.0), Vector3(4.0, 0.0, 2.0),
		Vector3(0.0, 0.0, -2.0), Vector3(0.0, 0.0, 2.0),
		Vector3(4.0, 0.0, -2.0), Vector3(4.0, 0.0, 2.0),
		Vector3(6.0, 0.0, 0.0), Vector3(6.0, 0.0, 0.0),
		Vector3(14.0, 0.0, -2.0), Vector3(14.0, 0.0, 2.0),
		Vector3(18.0, 0.0, -2.0), Vector3(18.0, 0.0, 2.0),
		Vector3(30.0, 0.0, 0.0), Vector3(30.0, 0.0, 0.0),
		Vector3(34.0, 0.0, 0.0), Vector3(34.0, 0.0, 0.0),
	])
	var low_alpha := join_coverage * 0.5
	var cols := PackedColorArray([
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
		Color(0.5, 0.5, 1.0, low_alpha), Color(0.5, 0.5, 1.0, low_alpha),
		Color(0.5, 0.5, 1.0, low_alpha), Color(0.5, 0.5, 1.0, low_alpha),
		Color(0.5, 0.5, 1.0, 0.0), Color(0.5, 0.5, 1.0, 0.0),
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
		Color(0.5, 0.5, 1.0, 1.0), Color(0.5, 0.5, 1.0, 1.0),
	])
	var uv2s := PackedVector2Array()
	uv2s.resize(verts.size())
	for i in uv2s.size():
		uv2s[i] = Vector2(kind_river, 0.0)
	var starts := PackedInt32Array([0, 4, 8, 14])

	if _inside_other_river(verts, cols, uv2s, starts, 0, Vector3(2.0, 0.0, 0.0), cs):
		push_error("FAIL: _inside_other_river akzeptiert eigenes oder zu schwach deckendes Band")
		return false
	if _inside_other_river(verts, cols, uv2s, starts, 0, Vector3(6.0, 0.0, 0.0), cs):
		push_error("FAIL: _inside_other_river akzeptiert unsichtbaren Quellenanfang (Alpha 0, Breite 0)")
		return false
	if _inside_other_river(verts, cols, uv2s, starts, 0, Vector3(19.5, 0.0, 0.0), cs):
		push_error("FAIL: _inside_other_river akzeptiert Punkt hinter offenem Bandende")
		return false
	if _inside_other_river(verts, cols, uv2s, starts, 0, Vector3(32.0, 0.0, 0.0), cs):
		push_error("FAIL: _inside_other_river akzeptiert degeneriertes Band mit Halbbreite 0")
		return false
	if not _inside_other_river(verts, cols, uv2s, starts, 0, Vector3(16.0, 0.0, 1.0), cs):
		push_error("FAIL: _inside_other_river verwirft gedeckten Zusammenfluss im Hauptlauf")
		return false
	return true

func _cell_of(left: Vector3, right: Vector3, world: float, cs: float, n: int) -> int:
	var mid := (left + right) * 0.5
	var gx: int = clampi(int(round((mid.x + world * 0.5) / cs)), 0, n - 1)
	var gz: int = clampi(int(round((mid.z + world * 0.5) / cs)), 0, n - 1)
	return gz * n + gx

func _pond(h: PackedFloat32Array, wl: PackedFloat32Array, sea: float, k: int) -> float:
	if h[k] <= sea:
		return sea - h[k]
	if wl[k] > sea:
		return wl[k] - h[k]
	return 0.0

func _is_water(h: PackedFloat32Array, wl: PackedFloat32Array, sea: float, k: int) -> bool:
	return h[k] < sea or _pond(h, wl, sea, k) > pond_contour_lo

func _has_kind(frame: Dictionary, kind: float) -> bool:
	if not frame.has("ribbons"):
		return false
	var uv2s: PackedVector2Array = frame["ribbon_uv2s"]
	var starts: PackedInt32Array = frame["ribbon_strip_starts"]
	for s in starts.size():
		if starts[s] < uv2s.size() and uv2s[starts[s]].x == kind:
			return true
	return false
