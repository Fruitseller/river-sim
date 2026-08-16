extends SceneTree
## Headless-Wächter für die Fluss-Ribbons (Issue #31) — GPU-frei ausführbar mit:
##   godot --headless --path game --script res://tests/river_ribbons.gd
## Prüft den GDExtension-Vertrag des Ribbon-Pfads:
##  - buildRiverRibbons liefert konsistente Puffer (Verts/Colors/UVs/Indices),
##    Breite folgt dem Abfluss (√Q-Gesetz), Bandkanten dem lokalen Gelände,
##    Alpha bleibt längs kohärent und jedes Band erreicht Strahler-Ordnung 4
##  - Dirty-Vertrag: vor dem ersten Build „riesig", nach markRiversBuilt 0,
##    nach einem Sim-Schritt wieder > 0 (Migration bewegt die Zentrumslinien)
##  - Determinismus-Nachweis auf Extension-Ebene: buildRiverRibbons ändert die
##    Sim-Physik nicht (Höhen bit-gleich vor/nach dem Build)
## Exit-Code != 0 bei Fehler.

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")

# Vertragswerte aus SimCore/WaterRender.swift (dort begründet) — gepinnt von
# SimCoreTests/WaterRenderTests.swift gegen DIESE Datei (Issue #51).
const LAKE_SURFACE_LIFT := 0.04
const SEA_SURFACE_SINK := -0.06
const MIN_RANK := 0.65
const MAX_CROSS_SLOPE := 0.4
const KIND_DELTA_LO := 0.25

# Wie nah an der Zellgrenze (in Zellen) die Zentrumslinie liegen darf, damit
# auch die Nachbarzelle als gemeinter Spiegel zählt — s. `_lake_surface_err`.
const CELL_BOUNDARY_EPS := 0.001

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

	# Derselbe Wallclock-Deckel gilt im Echtzeit- und `_jump`-Pfad: vor einer
	# Sekunde kein Build, an der Grenze/bei Nutzeraktion sofort.
	var main: Node3D = Main.new()
	main.last_river_rebuild_msec = 1000
	if main._river_rebuild_due(1999, false) or not main._river_rebuild_due(2000, false):
		push_error("FAIL: 1-Hz-Ribbon-Deckel hat falsche Zeitgrenze")
		main.free()
		quit(1)
		return
	if not main._river_rebuild_due(1001, true):
		push_error("FAIL: erzwungener Ribbon-Rebuild wird gedeckelt")
		main.free()
		quit(1)
		return
	main.free()

	# Mäander brauchen etwas Laufzeit, bis Kanäle getraced und migriert sind.
	sim.step(4000.0)

	# Dirty-Vertrag: vor dem ersten Build muss das Delta den Rebuild erzwingen.
	var d0: float = sim.riversMaxDelta()
	print("delta_initial=", d0)
	if d0 < 1.0:
		push_error("FAIL: riversMaxDelta vor dem ersten Build zu klein")
		quit(1)
		return

	# Physik-Neutralität: der Geometrie-Build darf die Höhen nicht anfassen.
	var h_before: PackedFloat32Array = sim.heights()
	sim.buildRiverRibbons(Main.HSCALE, Main.RIVER_LIFT)
	var h_after: PackedFloat32Array = sim.heights()
	if h_before != h_after:
		push_error("FAIL: buildRiverRibbons verändert die Sim-Höhen")
		quit(1)
		return

	var verts: PackedVector3Array = sim.riverRibbonVerts()
	var cols: PackedColorArray = sim.riverRibbonColors()
	var uvs: PackedVector2Array = sim.riverRibbonUVs()
	var idx: PackedInt32Array = sim.riverRibbonIndices()
	print("verts=", verts.size(), " indices=", idx.size())
	if verts.size() < 4:
		push_error("FAIL: keine Ribbon-Geometrie nach 4000 Jahren")
		quit(1)
		return
	if cols.size() != verts.size() or uvs.size() != verts.size():
		push_error("FAIL: Puffer-Längen inkonsistent (verts=%d cols=%d uvs=%d)"
			% [verts.size(), cols.size(), uvs.size()])
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

	# Jede Bandkante muss auf ihrer EIGENEN lokalen Geländehöhe liegen — GEKLEMMT
	# auf die maximale Quer-Neigung um die Zentrums-Höhe (MAX_CROSS_SLOPE, s.
	# WaterRender.ribbonMaxCrossSlope): sanfte Quergefälle folgen dem Gelände
	# (eine reine Zentrums-Höhe schnitte das Band dort ins Terrain), Kanten auf
	# Schluchtwänden tauchen stattdessen in den Fels ein, statt das Band die
	# Wand hochzudrapieren.
	# AUSNAHME seit Issue #34: Stützpunkte UNTER Wasser (Mündung, geflutete
	# Senke, Delta-Arm, Altarm) liegen flach auf dem WASSERSPIEGEL — sonst
	# kippte das Band am Ufer aus der Wasserfläche heraus.
	var heights: PackedFloat32Array = sim.heights()
	var levels: PackedFloat32Array = sim.filled()
	var uv2s: PackedVector2Array = sim.riverRibbonUV2s()
	var n: int = sim.gridSize()
	var world: float = sim.worldSize()
	var sea: float = sim.seaLevel()
	var cs := world / float(n - 1)
	var max_ground_error := 0.0
	var on_water := 0
	var pair_on_water: Array[bool] = []
	# Alle Ausreißer sammeln statt beim ersten abzubrechen: dieser Wächter kann
	# nur auf der Maschine rot werden, deren Welt ihn auslöst (Höhenfelder sind
	# plattformabhängig, AGENTS.md), und dort steht meist kein Debugger zur
	# Verfügung — dann ist die AUSGABE die Diagnose (Issue #61).
	var stray := 0
	var stray_report := ""
	for a in range(0, verts.size(), 2):
		var v: Vector3 = verts[a]
		var vr: Vector3 = verts[a + 1]
		# Erwartete Kantenhöhe wie in RiverRibbonRenderer.emitRibbon: eigene
		# Geländehöhe, geklemmt auf Zentrums-Höhe ± Halbbreite × MAX_CROSS_SLOPE.
		# Die Halbbreite steckt in der Kantenpaar-Geometrie (halber XZ-Abstand),
		# das Zentrum ist der Paar-Mittelpunkt.
		var half_w := Vector2(v.x - vr.x, v.z - vr.z).length() * 0.5
		var cross_tol := half_w * MAX_CROSS_SLOPE
		var pair_mid := (v + vr) * 0.5
		var ground_c := _bilinear_height(heights, n, world, pair_mid.x, pair_mid.z) * Main.HSCALE
		var ground := _bilinear_height(heights, n, world, v.x, v.z) * Main.HSCALE
		var ground_r := _bilinear_height(heights, n, world, vr.x, vr.z) * Main.HSCALE
		var expect_l := clampf(ground, ground_c - cross_tol, ground_c + cross_tol) + Main.RIVER_LIFT
		var expect_r := clampf(ground_r, ground_c - cross_tol, ground_c + cross_tol) + Main.RIVER_LIFT
		var err := maxf(absf(v.y - expect_l), absf(vr.y - expect_r))
		# Wasserspiegel wird an der ZENTRUMSLINIE und in DERSELBEN Zelle
		# gelesen wie in SimNode (nächster Gitterpunkt): eine Bandkante liegt
		# bis zu 3 Zellen daneben, und über dem Ufer fällt `filled` innerhalb
		# einer Zelle auf die Geländehöhe ab.
		var level := _cell_value(levels, n, world, pair_mid.x, pair_mid.z)
		# Versatz wie in RiverRibbonRenderer.emitRibbon (WaterRender.ribbon*Surface*):
		# See knapp über dem Spiegel, Meer knapp darunter — NICHT RIVER_LIFT,
		# der gilt nur für Bänder auf dem Gelände.
		var surface_err: float = minf(
			_lake_surface_err(levels, n, world, pair_mid.x, pair_mid.z, v.y),
			absf(v.y - (sea * Main.HSCALE + SEA_SURFACE_SINK)))
		# Wasser-Nähe zählt als Wasser, AUCH wenn zufällig beides passt: im
		# flachen Apron kann die geklemmte Land-Erwartung einer echten
		# Wasser-Kante gleichen (Tiefe × HSCALE ≈ RIVER_LIFT − Spiegel-Versatz)
		# — die Alpha-Glattheits-Prüfung unten muss solche Paare ausnehmen,
		# denn am Wassereintritt blendet das Band bewusst hart aus.
		var water_like := surface_err <= 0.05
		pair_on_water.append(water_like)
		if err > 0.002:
			if not water_like:
				stray += 1
				if stray <= 8:
					# Gitterposition MIT Nachkommastellen: liegt sie dicht an
					# x.5, hat die Kante nur die Nachbarzelle erwischt; sonst
					# steht das Band wirklich auf einem fremden Spiegel.
					stray_report += ("\n  paar=%d typ=%.2f alpha=%.3f y=%f gitter=(%.3f, %.3f)"
						+ " gelände_links=%f wasserspiegel=%f meer=%f"
						+ " ground_err=%f surface_err=%f") % [
						a, uv2s[a].x, cols[a].a, v.y,
						(pair_mid.x + world * 0.5) / cs, (pair_mid.z + world * 0.5) / cs,
						ground + Main.RIVER_LIFT,
						level * Main.HSCALE + LAKE_SURFACE_LIFT,
						sea * Main.HSCALE + SEA_SURFACE_SINK,
						err, surface_err]
			on_water += 2
			continue
		max_ground_error = maxf(max_ground_error, err)
	print("max_ground_error=", max_ground_error, " vertices_auf_wasser=", on_water)
	if stray > 0:
		push_error("FAIL: %d Band-Kantenpaare liegen weder auf dem Gelände noch auf einem Wasserspiegel (erste %d):%s"
			% [stray, mini(stray, 8), stray_report])
		quit(1)
		return

	# Nur Läufe emittieren, die mindestens Strahler 4 erreichen. Ihr Oberlauf
	# bleibt als feiner Taper am selben Band erhalten; niedrigere Mäander würden
	# die alten verknäulten „zu viele Flüsse"-Felder nachzeichnen.
	# Gilt für FLUSS-Bänder; Delta-Arme und Altarme (Issue #34) haben keine
	# eigene Strahler-Ordnung, ihre Bänder werden hier also übersprungen.
	var starts: PackedInt32Array = sim.riverRibbonStripStarts()
	var max_alpha_jump := 0.0
	var river_strips := 0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x > KIND_DELTA_LO:
			continue
		river_strips += 1
		var strip_max_rank := 0.0
		for a in range(from, to, 2):
			strip_max_rank = maxf(strip_max_rank, cols[a].b)
			# Sprünge nur auf dem LAND-Reach prüfen: am Wassereintritt blendet
			# das Band bewusst hart mit der Wassersäule aus (Issue #34,
			# `submergedFade`) — dort übernimmt die Seefläche im selben Pixel.
			if a > from and not pair_on_water[a / 2] and not pair_on_water[a / 2 - 1]:
				max_alpha_jump = maxf(max_alpha_jump, absf(cols[a].a - cols[a - 2].a))
		if strip_max_rank < MIN_RANK:
			push_error("FAIL: Ribbon ohne Strahler-4-Anschluss emittiert")
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

	# Breite folgt dem Abfluss: die Querbreiten (Vertex-Paar-Abstände) müssen
	# VARIIEREN (Oberlauf fein, Unterlauf breit) — ein konstantes Band wäre
	# das alte 1-Zellen-Deckel-Verhalten.
	# Nur Fluss-Bänder: ein Altarm ist per Definition konstant breit.
	var wmin := INF
	var wmax := 0.0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x > KIND_DELTA_LO:
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

	# Nach markRiversBuilt ist das Delta exakt 0 (nichts hat sich bewegt) …
	sim.markRiversBuilt()
	var d1: float = sim.riversMaxDelta()
	print("delta_after_mark=", d1)
	if d1 != 0.0:
		push_error("FAIL: Delta nach markRiversBuilt nicht 0")
		quit(1)
		return

	# … und nach einem Sim-Schritt wieder > 0 (Mäander migrieren).
	sim.step(1000.0)
	var d2: float = sim.riversMaxDelta()
	print("delta_after_step=", d2)
	if d2 <= 0.0:
		push_error("FAIL: Migration meldet kein Delta")
		quit(1)
		return

	print("RIVER_RIBBONS_OK")
	quit(0)

## Abstand des Bands zum SEE-Spiegel unter ihm — tolerant NUR auf der Zellgrenze.
##
## Die Extension rundet die Zentrumslinie in `double` auf eine Zelle, dieser
## Wächter rechnet aus dem Vertex-Puffer zurück, der `float32` trägt. Bei ±65
## Welteinheiten trägt float32 rund 2,5e-5 Zellen Rundungsfehler — liegt die
## Zentrumslinie zufällig auf x.5, meinen beide Seiten dieselbe Kante und
## nennen verschiedene Zellen. Am Ufer unterscheiden sich deren Spiegel
## beliebig weit, und der Wächter würde ohne Grund rot (Issue #61).
## Die Toleranz ist deshalb bewusst eine ORTS-Toleranz von 0,001 Zellen und
## keine Höhen-Toleranz: einen Meter daneben bleibt einen Meter daneben.
func _lake_surface_err(levels: PackedFloat32Array, n: int, world: float,
		x: float, z: float, y: float) -> float:
	var cs := world / float(n - 1)
	var best := INF
	for i in _cell_candidates((x + world * 0.5) / cs, n):
		for j in _cell_candidates((z + world * 0.5) / cs, n):
			best = minf(best, absf(y - (levels[j * n + i] * Main.HSCALE + LAKE_SURFACE_LIFT)))
	return best

## Zellindex(e) einer kontinuierlichen Gitterposition: der gerundete — und auf
## der Zellgrenze (innerhalb `CELL_BOUNDARY_EPS`) auch der Nachbar.
func _cell_candidates(g: float, n: int) -> Array[int]:
	var base := clampi(int(round(g)), 0, n - 1)
	var out: Array[int] = [base]
	var frac := g - floorf(g)
	if absf(frac - 0.5) < CELL_BOUNDARY_EPS:
		out.append(clampi(base - 1 if frac >= 0.5 else base + 1, 0, n - 1))
	return out

## Feldwert in DER Zelle, die SimNode für diesen Punkt benutzt (Rundung, nicht
## Interpolation) — nur so ist der Vergleich exakt statt „ungefähr".
func _cell_value(f: PackedFloat32Array, n: int, world: float, x: float, z: float) -> float:
	var cs := world / float(n - 1)
	var i := clampi(int(round((x + world * 0.5) / cs)), 0, n - 1)
	var j := clampi(int(round((z + world * 0.5) / cs)), 0, n - 1)
	return f[j * n + i]

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
