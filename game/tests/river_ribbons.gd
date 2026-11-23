extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")

const FRAME_SETTLED := 0

var now := 0.0

var hscale: float
var river_lift: float
var lake_surface_lift: float
var sea_surface_sink: float
var min_rank: float
var max_cross_slope: float
var waterline_lift: float
var waterline_reach: float
var waterline_reach_min: float
var waterline_inner: float
var center_raise_max: float
var visible_lo: float
var visible_hi: float
var kind_delta_lo: float

const CELL_BOUNDARY_EPS := 0.001
const SINK_TOLERANCE := 0.02

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert (Projekt importiert? godot --headless --path game --import)")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim):
		quit(1)
		return
	var contract := Main.calibration(sim, "water_contract")
	var render_contract := Main.calibration(sim, "contract")
	hscale = render_contract["heightScale"]
	river_lift = render_contract["riverLift"]
	lake_surface_lift = contract["ribbonLakeSurfaceLift"]
	sea_surface_sink = contract["ribbonSeaSurfaceSink"]
	min_rank = contract["ribbonMinimumRank"]
	max_cross_slope = contract["ribbonMaxCrossSlope"]
	waterline_lift = contract["ribbonWaterlineLift"]
	waterline_reach = contract["ribbonWaterlineReach"]
	waterline_reach_min = contract["ribbonWaterlineReachMin"]
	waterline_inner = contract["ribbonWaterlineInner"]
	center_raise_max = contract["ribbonCenterRaiseMax"]
	visible_lo = contract["ribbonVisibleLo"]
	visible_hi = contract["ribbonVisibleHi"]
	kind_delta_lo = contract["ribbonDeltaLo"]

	sim.step(4000.0)

	now += 1.0
	var frame: Dictionary = sim.renderFrame(FRAME_SETTLED, now)
	if not frame.has("ribbons"):
		push_error("FAIL: erster Frame baut die Bänder nicht (Delta-Meldung versagt)")
		quit(1)
		return
	print("delta_initial=", "rebuild")

	var h_before: PackedFloat32Array = sim.heights()
	now += 1.0
	sim.renderFrame(FRAME_SETTLED, now)
	var h_after: PackedFloat32Array = sim.heights()
	if h_before != h_after:
		push_error("FAIL: der Frame verändert die Sim-Höhen")
		quit(1)
		return

	var verts: PackedVector3Array = frame["ribbon_verts"]
	var cols: PackedColorArray = frame["ribbon_colors"]
	var uvs: PackedVector2Array = frame["ribbon_uvs"]
	var idx: PackedInt32Array = frame["ribbon_indices"]
	print("verts=", verts.size(), " indices=", idx.size())
	if verts.size() < 4:
		push_error("FAIL: keine Ribbon-Geometrie nach 4000 Jahren")
		quit(1)
		return
	var uv2s_all: PackedVector2Array = frame["ribbon_uv2s"]
	if cols.size() != verts.size() or uvs.size() != verts.size() or uv2s_all.size() != verts.size():
		push_error("FAIL: Puffer-Längen inkonsistent (verts=%d cols=%d uvs=%d uv2s=%d)"
			% [verts.size(), cols.size(), uvs.size(), uv2s_all.size()])
		quit(1)
		return
	if not frame.has("ribbon_flows"):
		push_error("FAIL: Frame ohne ribbon_flows")
		quit(1)
		return
	var flows: PackedFloat32Array = frame["ribbon_flows"]
	if flows.size() != 4 * verts.size():
		push_error("FAIL: ribbon_flows hat %d Werte, erwartet 4 × %d" % [flows.size(), verts.size()])
		quit(1)
		return
	var flow_sum := Vector4.ZERO
	for v in verts.size():
		for c in 3:
			if flows[4 * v + c] < 0.0 or flows[4 * v + c] > 1.0:
				push_error("FAIL: ribbon_flows[%d][%d] = %f außerhalb 0 … 1" % [v, c, flows[4 * v + c]])
				quit(1)
				return
		if flows[4 * v + 3] < 0.0:
			push_error("FAIL: ribbon_flows[%d].w = %f < 0" % [v, flows[4 * v + 3]])
			quit(1)
			return
		flow_sum += Vector4(flows[4 * v], flows[4 * v + 1], flows[4 * v + 2], flows[4 * v + 3])
	if flow_sum.x <= 0.0 or flow_sum.z <= 0.0 or flow_sum.w <= 0.0:
		push_error("FAIL: ribbon_flows trägt keine Lauf-Größen (Summe %s)" % flow_sum)
		quit(1)
		return
	var corridor_err := _check_corridor(frame, verts.size())
	if corridor_err != "":
		push_error("FAIL: " + corridor_err)
		quit(1)
		return
	if idx.size() % 3 != 0:
		push_error("FAIL: Index-Puffer ist kein Dreiecks-Vielfaches")
		quit(1)
		return
	var vmax := 0
	for i in idx:
		vmax = maxi(vmax, i)
	if vmax >= verts.size():
		push_error("FAIL: Index zeigt hinter das Vertex-Ende")
		quit(1)
		return

	var heights: PackedFloat32Array = sim.heights()
	var levels: PackedFloat32Array = (frame["filled"] as PackedByteArray).to_float32_array()
	var uv2s: PackedVector2Array = frame["ribbon_uv2s"]
	var n: int = sim.gridSize()
	var world: float = sim.worldSize()
	var sea: float = sim.seaLevel()
	var cs := world / float(n - 1)
	var max_ground_error := 0.0
	var on_water := 0
	var pair_on_water: Array[bool] = []
	var stray := 0
	var stray_report := ""
	var land_pairs := 0
	var sunk_pairs := 0
	for a in range(0, verts.size(), 2):
		var v: Vector3 = verts[a]
		var vr: Vector3 = verts[a + 1]
		var half_w := Vector2(v.x - vr.x, v.z - vr.z).length() * 0.5
		var cross_tol := half_w * max_cross_slope
		var pair_mid := (v + vr) * 0.5
		var ground_c := _bilinear_height(heights, n, world, pair_mid.x, pair_mid.z) * hscale
		var ground := _bilinear_height(heights, n, world, v.x, v.z) * hscale
		var ground_r := _bilinear_height(heights, n, world, vr.x, vr.z) * hscale
		var lake_c := _cell_value(levels, n, world, pair_mid.x, pair_mid.z) * hscale + lake_surface_lift
		var reach := maxf(waterline_reach_min,
			waterline_reach * smoothstep(visible_lo, visible_hi, cols[a].a))
		var target_l := minf(ground_c + river_lift,
			_waterline_ground(heights, n, world, pair_mid, v, reach) * hscale
				+ waterline_lift + center_raise_max)
		var target_r := minf(ground_c + river_lift,
			_waterline_ground(heights, n, world, pair_mid, vr, reach) * hscale
				+ waterline_lift + center_raise_max)
		var expect_l := maxf(ground + waterline_lift, target_l)
		var expect_r := maxf(ground_r + waterline_lift, target_r)
		var wall := maxf(ground_c + cross_tol + river_lift, lake_c)
		var err_l := maxf(0.0, maxf(v.y - maxf(expect_l, lake_c), v.y - wall))
		var err_r := maxf(0.0, maxf(vr.y - maxf(expect_r, lake_c), vr.y - wall))
		var level := _cell_value(levels, n, world, pair_mid.x, pair_mid.z)
		var surface_err_l: float = minf(
			_lake_surface_err(levels, n, world, pair_mid.x, pair_mid.z, v.y),
			absf(v.y - (sea * hscale + sea_surface_sink)))
		var surface_err_r: float = minf(
			_lake_surface_err(levels, n, world, pair_mid.x, pair_mid.z, vr.y),
			absf(vr.y - (sea * hscale + sea_surface_sink)))
		var edge_l_water := surface_err_l <= 0.05
		var edge_r_water := surface_err_r <= 0.05
		var water_like := edge_l_water or edge_r_water
		pair_on_water.append(water_like)
		var stray_l := err_l > 0.002 and not edge_l_water
		var stray_r := err_r > 0.002 and not edge_r_water
		if stray_l or stray_r:
			stray += 1
			if stray <= 8:
				stray_report += ("\n  paar=%d typ=%.2f alpha=%.3f y=%f/%f gitter=(%.3f, %.3f)"
					+ " gelände=%f/%f wasserspiegel=%f meer=%f"
					+ " ground_err=%f/%f surface_err=%f/%f") % [
					a, uv2s[a].x, cols[a].a, v.y, vr.y,
					(pair_mid.x + world * 0.5) / cs, (pair_mid.z + world * 0.5) / cs,
					expect_l, expect_r,
					level * hscale + lake_surface_lift,
					sea * hscale + sea_surface_sink,
					err_l, err_r, surface_err_l, surface_err_r]
			continue
		if not water_like:
			land_pairs += 1
			if pair_mid.y < ground_c - SINK_TOLERANCE:
				sunk_pairs += 1
		if edge_l_water:
			on_water += 1
		else:
			max_ground_error = maxf(max_ground_error, err_l)
		if edge_r_water:
			on_water += 1
		else:
			max_ground_error = maxf(max_ground_error, err_r)
	print("max_ground_error=", max_ground_error, " vertices_auf_wasser=", on_water,
		" land_paare=", land_pairs, " mitte_versunken=", sunk_pairs)
	if land_pairs < 1000 or sunk_pairs * 10 > land_pairs:
		push_error("FAIL: Bandmitte unter dem Gelände (%d von %d Land-Paaren)" % [sunk_pairs, land_pairs])
		quit(1)
		return
	if stray > 0:
		push_error("FAIL: %d Band-Kantenpaare liegen weder auf dem Gelände noch auf einem Wasserspiegel (erste %d):%s"
			% [stray, mini(stray, 8), stray_report])
		quit(1)
		return

	var starts: PackedInt32Array = frame["ribbon_strip_starts"]
	var max_alpha_jump := 0.0
	var river_strips := 0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x > kind_delta_lo:
			continue
		river_strips += 1
		var strip_max_rank := 0.0
		for a in range(from, to, 2):
			strip_max_rank = maxf(strip_max_rank, cols[a].b)
			if a > from and not pair_on_water[a / 2] and not pair_on_water[a / 2 - 1]:
				max_alpha_jump = maxf(max_alpha_jump, absf(cols[a].a - cols[a - 2].a))
		if strip_max_rank < min_rank:
			push_error("FAIL: Ribbon ohne Strahler-3-Anschluss emittiert")
			quit(1)
			return
	print("fluss_bänder=", river_strips, " max_alpha_jump=", max_alpha_jump)
	if river_strips < 1:
		push_error("FAIL: keine Fluss-Bänder emittiert")
		quit(1)
		return
	if max_alpha_jump > 0.40:
		push_error("FAIL: segmentierte Alpha-Spitze im Ribbon (max=%f)" % max_alpha_jump)
		quit(1)
		return

	var wmin := INF
	var wmax := 0.0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x > kind_delta_lo:
			continue
		for a in range(from, to, 2):
			var left := Vector2(verts[a].x, verts[a].z)
			var right := Vector2(verts[a + 1].x, verts[a + 1].z)
			var w := left.distance_to(right)
			wmin = minf(wmin, w)
			wmax = maxf(wmax, w)
	print("width_min=", wmin, " width_max=", wmax)
	if wmax <= 0.0 or wmax / maxf(wmin, 1e-6) < 1.5:
		push_error("FAIL: Bandbreite variiert nicht mit dem Abfluss (min=%f max=%f)" % [wmin, wmax])
		quit(1)
		return

	sim.step(1000.0)
	now += 1.0
	var d2: Dictionary = sim.renderFrame(FRAME_SETTLED, now)
	print("delta_after_step=", "rebuild" if d2.has("ribbons") else "still")
	if not d2.has("ribbons"):
		push_error("FAIL: Migration meldet kein Delta")
		quit(1)
		return

	print("RIVER_RIBBONS_OK")
	quit(0)

func _lake_surface_err(levels: PackedFloat32Array, n: int, world: float,
		x: float, z: float, y: float) -> float:
	var cs := world / float(n - 1)
	var best := INF
	for i in _cell_candidates((x + world * 0.5) / cs, n):
		for j in _cell_candidates((z + world * 0.5) / cs, n):
			best = minf(best, absf(y - (levels[j * n + i] * hscale + lake_surface_lift)))
	return best

func _cell_candidates(g: float, n: int) -> Array[int]:
	var base := clampi(int(round(g)), 0, n - 1)
	var out: Array[int] = [base]
	var frac := g - floorf(g)
	if absf(frac - 0.5) < CELL_BOUNDARY_EPS:
		out.append(clampi(base - 1 if frac >= 0.5 else base + 1, 0, n - 1))
	return out

func _cell_value(f: PackedFloat32Array, n: int, world: float, x: float, z: float) -> float:
	var cs := world / float(n - 1)
	var i := clampi(int(round((x + world * 0.5) / cs)), 0, n - 1)
	var j := clampi(int(round((z + world * 0.5) / cs)), 0, n - 1)
	return f[j * n + i]

func _waterline_ground(h: PackedFloat32Array, n: int, world: float, mid: Vector3, edge: Vector3,
		reach: float) -> float:
	var g := INF
	for f in [waterline_inner, 0.5 * (1.0 + waterline_inner), 1.0]:
		var p: Vector3 = mid + (edge - mid) * (reach * f)
		g = minf(g, _bilinear_height(h, n, world, p.x, p.z))
	return g

func _bilinear_height(h: PackedFloat32Array, n: int, world: float, x: float, z: float) -> float:
	var cs := world / float(n - 1)
	var gx := (x + world * 0.5) / cs
	var gz := (z + world * 0.5) / cs
	var xi := clampi(int(gx), 0, n - 2)
	var zi := clampi(int(gz), 0, n - 2)
	var fx := clampf(gx - float(xi), 0.0, 1.0)
	var fz := clampf(gz - float(zi), 0.0, 1.0)
	var k := zi * n + xi
	return (h[k] * (1.0 - fx) * (1.0 - fz)
		+ h[k + 1] * fx * (1.0 - fz)
		+ h[k + n] * (1.0 - fx) * fz
		+ h[k + n + 1] * fx * fz)

func _check_corridor(frame: Dictionary, ribbon_verts: int) -> String:
	for key in ["ribbon_profile", "corridor_verts", "corridor_normals", "corridor_colors",
			"corridor_uvs", "corridor_uv2s", "corridor_custom", "corridor_indices"]:
		if not frame.has(key):
			return "Frame ohne " + key
	var profile: PackedFloat32Array = frame["ribbon_profile"]
	if profile.size() != 4 * ribbon_verts:
		return "ribbon_profile hat %d Werte, erwartet 4 × %d" % [profile.size(), ribbon_verts]
	var cv: PackedVector3Array = frame["corridor_verts"]
	if cv.size() < 3:
		return "kein Korridor-Mesh nach 4000 Jahren"
	var sizes := [(frame["corridor_normals"] as PackedVector3Array).size(),
		(frame["corridor_colors"] as PackedColorArray).size(),
		(frame["corridor_uvs"] as PackedVector2Array).size(),
		(frame["corridor_uv2s"] as PackedVector2Array).size(),
		(frame["corridor_custom"] as PackedFloat32Array).size() / 4]
	for size in sizes:
		if size != cv.size():
			return "Korridor-Puffer ungleich lang (%s gegen %d Vertices)" % [str(sizes), cv.size()]
	var ci: PackedInt32Array = frame["corridor_indices"]
	if ci.size() % 3 != 0:
		return "Korridor-Indizes kein Dreiecks-Vielfaches"
	for i in ci:
		if i < 0 or i >= cv.size():
			return "Korridor-Index %d außerhalb" % i
	var with_corridor := 0
	for v in ribbon_verts:
		if profile[4 * v] > 0.0:
			with_corridor += 1
	if with_corridor == 0:
		return "kein Band-Vertex trägt einen Korridor"
	print("corridor_verts=", cv.size(), " band_vertices_mit_korridor=", with_corridor)
	return ""
