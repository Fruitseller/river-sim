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

# Vertragswerte aus SimCore/WaterRender.swift (dort begründet) — gepinnt von
# SimCoreTests/WaterRenderTests.swift gegen DIESE Datei (Issue #51).
const KIND_RIVER := 0.0
const KIND_DELTA := 0.5
const KIND_OXBOW := 1.0
const POND_CONTOUR_LO := 0.003
const LAKE_RAW_WET := 0.03
const MAX_OXBOW_OPACITY := 0.7
const MOUTH_SEARCH_CELLS := 8

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

	# Ohne Überschreibung ist dieser Lauf der WÄCHTER (feste Welt, feste
	# Erwartungen). Mit RS_SEED/RS_STEP ist er ein MESSLAUF über eine andere Welt:
	# dann bleiben die Invarianten (kein Spalt, kein doppeltes Wasser, Stillwasser-
	# Kodierung) scharf, aber die Existenz-Zusagen entfallen — ob eine bestimmte
	# Welt gerade Altarme trägt, ist Physik, keine Render-Eigenschaft (Seed 907
	# hat nach 60.000 Jahren keinen einzigen wassergefüllten Altarm mehr).
	var strict := true
	# 30.000 statt 20.000 J. seit dem Umstieg auf n = 720 (Aug 2026): die
	# kleinere Welt hat kürzere Läufe, ihre Mäander schnüren später ab.
	# GEMESSEN über RS_STEP (Bänder mit Typ-Kanal KIND_OXBOW, Seed 1337):
	# 15.000 J. → 0, 20.000 → 0, 25.000 → 4, 30.000 → 4, 40.000 → 1.
	# 30.000 liegt auf dem Plateau, nicht an seiner Kante. Bei n = 832 trug
	# dieselbe Welt schon nach 20.000 J. Altarm-Bänder — die Zusage ist also
	# nicht schwächer geworden, sie braucht nur den Zeitpunkt, an dem DIESE
	# Welt sie erfüllt (s. Kommentar über `strict`).
	var years := 30000.0
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
	var strip_kind := {KIND_RIVER: 0, KIND_DELTA: 0, KIND_OXBOW: 0}
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
			if kind == KIND_RIVER and pond >= LAKE_RAW_WET:
				deep_river_alpha = maxf(deep_river_alpha, cols[a].a)
			if kind == KIND_OXBOW:
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
	if strict and strip_kind[KIND_OXBOW] < 1:
		push_error("FAIL: keine Altarm-Bänder nach %d Jahren" % int(years))
		quit(1)
		return
	if not oxbow_still:
		push_error("FAIL: Altarm-Band trägt eine Fließrichtung (kein Stillwasser)")
		quit(1)
		return
	if oxbow_alpha_max > MAX_OXBOW_OPACITY + 0.001:
		push_error("FAIL: Altarm-Deckkraft über dem Maximum (%f)" % oxbow_alpha_max)
		quit(1)
		return
	if strict and strip_kind[KIND_DELTA] < 1:
		push_error("FAIL: kein einziger Delta-Arm — Mündungen ohne Auffächerung")
		quit(1)
		return

	# --- Mündungen: kein Spalt ------------------------------------------------
	var closed := 0
	var gaps := 0
	for s in starts.size():
		var from: int = starts[s]
		var to: int = (starts[s + 1] if s + 1 < starts.size() else verts.size())
		if uv2s[from].x != KIND_RIVER:
			continue
		var last := to - 2
		var k := _cell_of(verts[last], verts[last + 1], world, cs, n)
		if _is_water(h, wl, sea, k):
			closed += 1
			continue
		# Trockenes Ende ist nur erlaubt, wenn in Reichweite gar kein Wasser liegt
		# (der Lauf versickert im Land) — sonst fehlt die Mündung.
		var c := k
		for _i in MOUTH_SEARCH_CELLS:
			var r := rec[c]
			if r < 0:
				break
			c = int(r)
			if _is_water(h, wl, sea, c):
				gaps += 1
				break
	print("fluss_bänder=", strip_kind[KIND_RIVER], " mündungen_im_wasser=", closed,
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

func _is_water(h: PackedFloat32Array, wl: PackedFloat32Array, sea: float, k: int) -> bool:
	return _pond(h, wl, sea, k) > POND_CONTOUR_LO
