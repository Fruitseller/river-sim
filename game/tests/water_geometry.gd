extends SceneTree
## Headless-Wächter für die Wasser-Geometrie (Issue #34) — GPU-frei ausführbar:
##   godot --headless --path game --script res://tests/water_geometry.gd
##
## Prüft die Zusagen, die #34 dem Renderpfad gibt:
##  - MÜNDUNG geschlossen: jedes Fluss-Band, dessen Lauf binnen weniger Zellen
##    Wasser erreicht, endet IM Wasser — kein Spalt zwischen Band und Uferkontur.
##  - KEIN doppeltes Wasser: wo der Raster-See-Kanal malt (Wassersäule über
##    `rawWet` = 0.03), ist das Fluss-Band bereits ausgeblendet.
##  - DELTAS: an Mündungen mit flachem Ablagerungskörper entstehen
##    Distributär-Arme (Typ 0.5), an Steilufern nicht.
##  - ALTARME: existieren als eigene Bänder (Typ 1.0) mit Stillwasser-Kodierung
##    (Richtung exakt 0) und Alters-Fade unter der Maximal-Deckkraft.
##  - Physik-Neutralität + Determinismus des Geometrie-Baus.
##
## Zahlen werden mitgedruckt (Messprotokoll: docs/geometry-water-measurements.md).
## Exit-Code != 0 bei Fehler.

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const WaterContract = preload("res://tests/water_contract.gd")

# Vertragswerte aus SimCore/WaterRender.swift (dort begründet) — seit Issue #92
# über die Brücke geholt (SimNode.waterContractNames/Values) statt als eigene
# Konstanten kopiert; die Paarung Name ↔ Konstante pinnt
# SimCoreTests/WaterUniformsTests.swift ausführbar.
var kind_river: float
var kind_delta: float
var kind_oxbow: float
var pond_contour_lo: float
var lake_raw_wet: float
var max_oxbow_opacity: float
var mouth_search_cells: int

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
	var contract := WaterContract.fetch(sim)
	kind_river = contract["ribbonKindRiver"]
	kind_delta = contract["ribbonKindDelta"]
	kind_oxbow = contract["ribbonKindOxbow"]
	pond_contour_lo = contract["pondContourLo"]
	lake_raw_wet = contract["lakeRawWetDepth"]
	max_oxbow_opacity = contract["oxbowMaximumOpacity"]
	mouth_search_cells = int(contract["mouthSearchCells"])

	# Ohne Überschreibung ist dieser Lauf der WÄCHTER (feste Welt, feste
	# Erwartungen). Mit RS_SEED/RS_STEP ist er ein MESSLAUF über eine andere Welt:
	# dann bleiben die Invarianten (kein Spalt, kein doppeltes Wasser, Stillwasser-
	# Kodierung) scharf, aber die Existenz-Zusagen entfallen — ob eine bestimmte
	# Welt gerade Altarme trägt, ist Physik, keine Render-Eigenschaft (Seed 907
	# hat nach 60.000 Jahren keinen einzigen wassergefüllten Altarm mehr).
	var strict := true
	# Der Wächter prüft den ERSTEN Zustand ab Jahr 20.000 (jedes Jahrtausend bis
	# 80.000), der Altarm- UND Delta-Bänder trägt, statt eines festen Jahres.
	# Bis Issue #174 stand hier fest 30.000 J., gemessen auf der damaligen Welt
	# (Seed 1337: 15.000 → 0, 20.000 → 0, 25.000 → 4, 30.000 → 4, 40.000 → 1
	# Altarm-Bänder). Ob eine Welt zu einem bestimmten Jahr gerade einen jungen
	# Altarm trägt, ist Physik: mit der Großform aus #174 und der System-libm des
	# CI-Runners (Linux) traf 30.000 J. eine Lücke. Die Zusage bleibt — Altarme
	# und Deltas entstehen, und ihre Bänder halten alle Invarianten unten —,
	# nur ohne festes Datum. Jedes Jahrtausend, nicht jedes fünfte: ein Altarm-
	# Band braucht offenes Wasser im eigenen Bogen, und auf der neuen Welt sind
	# gleichzeitig nur 0–4 junge Altarme wassergefüllt (gemessen Seed 1337,
	# Jahre 20.000–80.000 in 5.000er-Schritten, macOS) — im 5.000er-Raster
	# traf der Linux-Runner keinen.
	var years := 80000.0
	if OS.has_environment("RS_STEP"):
		years = float(OS.get_environment("RS_STEP"))
		strict = false
	if OS.has_environment("RS_SEED"):
		sim.generate(int(OS.get_environment("RS_SEED")))
		strict = false
	var y := 0.0
	while y < years:
		sim.step(1000.0)
		y += 1000.0
		if strict and y >= 20000.0:
			sim.recomputeFlow()
			sim.buildRiverRibbons(Main.HSCALE, Main.RIVER_LIFT)
			if _has_kind(sim, kind_oxbow) and _has_kind(sim, kind_delta):
				break
	years = y
	sim.recomputeFlow()

	var h_before: PackedFloat32Array = sim.heights()
	var t0 := Time.get_ticks_usec()
	sim.buildRiverRibbons(Main.HSCALE, Main.RIVER_LIFT)
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
	if sim.heights() != h_before:
		push_error("FAIL: buildRiverRibbons verändert die Sim-Höhen")
		quit(1)
		return

	var verts: PackedVector3Array = sim.riverRibbonVerts()
	var cols: PackedColorArray = sim.riverRibbonColors()
	var uv2s: PackedVector2Array = sim.riverRibbonUV2s()
	var starts: PackedInt32Array = sim.riverRibbonStripStarts()
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
	var wl: PackedFloat32Array = sim.filled()
	var rec: PackedInt32Array = sim.receivers()

	# --- Zählung je Typ + Deckkraft im vom Raster gemalten Tiefwasser ---------
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
				# Stillwasser-Kodierung: Richtung exakt 0 (COLOR.rg == 0.5).
				if absf(cols[a].r - 0.5) > 0.002 or absf(cols[a].g - 0.5) > 0.002:
					oxbow_still = false
	print("build_ms=", build_ms, " verts=", verts.size(), " bänder=", strip_kind)
	print("max_alpha_fluss_im_rasterwasser=", deep_river_alpha,
		" oxbow_alpha_max=", oxbow_alpha_max)

	# Das Raster malt ab 0.03 Wassersäule (rawWet). Dort MUSS das Band weg sein,
	# sonst liegen zwei Wasserflächen übereinander.
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

	# --- Mündungen: kein Spalt ------------------------------------------------
	var closed := 0
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
		# Trockenes Ende ist nur erlaubt, wenn in Reichweite gar kein Wasser liegt
		# (der Lauf versickert im Land) — sonst fehlt die Mündung.
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
		" mündungen_mit_spalt=", gaps)
	if gaps > 0:
		push_error("FAIL: %d Fluss-Band(-Enden) enden vor der Wasserfläche" % gaps)
		quit(1)
		return

	# --- Determinismus des Geometrie-Baus ------------------------------------
	sim.buildRiverRibbons(Main.HSCALE, Main.RIVER_LIFT)
	if sim.riverRibbonVerts() != verts or sim.riverRibbonColors() != cols:
		push_error("FAIL: zweiter Bau liefert andere Geometrie (nicht deterministisch)")
		quit(1)
		return

	print("WATER_GEOMETRY_OK")
	quit(0)

## Zellindex unter der MITTE eines Kantenpaars (die Zentrumslinie des Bands).
func _cell_of(left: Vector3, right: Vector3, world: float, cs: float, n: int) -> int:
	var mid := (left + right) * 0.5
	var gx: int = clampi(int(round((mid.x + world * 0.5) / cs)), 0, n - 1)
	var gz: int = clampi(int(round((mid.z + world * 0.5) / cs)), 0, n - 1)
	return gz * n + gx

## Wassersäule über der Zelle (Meer und See sind zwei verschiedene Flächen —
## dieselbe Fallunterscheidung wie openWaterSurface in RenderSupport.swift).
func _pond(h: PackedFloat32Array, wl: PackedFloat32Array, sea: float, k: int) -> float:
	if h[k] <= sea:
		return sea - h[k]
	if wl[k] > sea:
		return wl[k] - h[k]
	return 0.0

# Wasserfläche = Ozean-Ebene ODER Raster-See. Die Ozean-Ebene deckt jede Zelle
# unter `sea` (ocean.gdshader verwirft nur über `sea`), die Kontur-Schwelle
# gilt für den Raster-See. Seit die Bänder ab der Wasserlinie ausblenden (#174,
# Küsten-Feinschliff), endet ein Band auf den ersten, kaum überfluteten
# Meereszellen; mit der See-Schwelle auch fürs Meer zählte das als Spalt
# (Linux-Runner, Seed 1337 Jahr 20.000: Bandende auf sea − 0,0002, die Schwelle
# erst drei Zellen weiter).
func _is_water(h: PackedFloat32Array, wl: PackedFloat32Array, sea: float, k: int) -> bool:
	return h[k] < sea or _pond(h, wl, sea, k) > pond_contour_lo


# Trägt der zuletzt gebaute Band-Puffer mindestens ein Band dieses Typs?
func _has_kind(sim: Object, kind: float) -> bool:
	var uv2s: PackedVector2Array = sim.riverRibbonUV2s()
	var starts: PackedInt32Array = sim.riverRibbonStripStarts()
	for s in starts.size():
		if starts[s] < uv2s.size() and uv2s[starts[s]].x == kind:
			return true
	return false
