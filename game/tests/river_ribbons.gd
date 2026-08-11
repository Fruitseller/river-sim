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

	# Jede Bandkante muss auf ihrer EIGENEN lokalen Geländehöhe liegen. Würden
	# beide Kanten nur die Höhe der Zentrumslinie übernehmen, schneidet das Band
	# an Quergefällen ins Terrain und erscheint als radiale blaue Fragmente.
	var heights: PackedFloat32Array = sim.heights()
	var n: int = sim.gridSize()
	var world: float = sim.worldSize()
	var max_ground_error := 0.0
	for v in verts:
		var expected_y := (_bilinear_height(heights, n, world, v.x, v.z)
			* Main.HSCALE + Main.RIVER_LIFT)
		max_ground_error = maxf(max_ground_error, absf(v.y - expected_y))
	print("max_ground_error=", max_ground_error)
	if max_ground_error > 0.002:
		push_error("FAIL: Ribbon-Kante folgt nicht dem lokalen Gelände (max=%f)" % max_ground_error)
		quit(1)
		return

	# Nur Läufe emittieren, die mindestens Strahler 4 erreichen. Ihr Oberlauf
	# bleibt als feiner Taper am selben Band erhalten; niedrigere Mäander würden
	# die alten verknäulten „zu viele Flüsse"-Felder nachzeichnen.
	var strip_max_rank := 0.0
	var max_alpha_jump := 0.0
	for a in range(0, verts.size(), 2):
		if a >= 2 and uvs[a].y > 0.0:
			max_alpha_jump = maxf(max_alpha_jump, absf(cols[a].a - cols[a - 2].a))
		if uvs[a].y == 0.0 and a > 0:
			if strip_max_rank < 0.65:
				push_error("FAIL: Ribbon ohne Strahler-4-Anschluss emittiert")
				quit(1)
				return
			strip_max_rank = 0.0
		strip_max_rank = maxf(strip_max_rank, cols[a].b)
	if strip_max_rank < 0.65:
		push_error("FAIL: letztes Ribbon ohne Strahler-4-Anschluss emittiert")
		quit(1)
		return
	print("max_alpha_jump=", max_alpha_jump)
	if max_alpha_jump > 0.40:
		push_error("FAIL: segmentierte Alpha-Spitze im Ribbon (max=%f)" % max_alpha_jump)
		quit(1)
		return

	# Breite folgt dem Abfluss: die Querbreiten (Vertex-Paar-Abstände) müssen
	# VARIIEREN (Oberlauf fein, Unterlauf breit) — ein konstantes Band wäre
	# das alte 1-Zellen-Deckel-Verhalten.
	var wmin := INF
	var wmax := 0.0
	for a in range(0, verts.size(), 2):
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
