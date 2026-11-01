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

# Rohwerte von FrameTrigger (Main.gd FRAME_*; der Unicode-Vertrag dazu pinnt
# SimCoreTests/RenderFrameTests.testMainUsesTheFrameTriggerValues).
const FRAME_SETTLED := 0

# Vertragswerte aus SimCore/WaterRender.swift (dort begründet) — seit Issue #92
# über die Brücke geholt (Gruppe `water_contract` des Kalibrier-Registers,
# Issue #213) statt als eigene Konstanten kopiert; die Paarung Name ↔
# Konstante pinnt SimCoreTests/CalibrationRegistryTests.swift ausführbar.
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
	# Der letzte Frame mit frischem Band-Bau: seit #214 gibt es keinen
	# Einzelschritt mehr — die Bänder kommen aus dem Frame (`renderFrame`,
	# FRAME_SETTLED wie Main.gd am Ende eines Sprungs). Ohne Knoten-Bewegung
	# baut der Frame nicht neu; der Mesh-Stand der Schleife bleibt dann der
	# aktuelle, die Geometrie prüft er gegen die frisch gelesenen Felder.
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
	# Seespiegel aus dem JÜNGSTEN Frame (der post-loop-Frame liefert ihn immer);
	# das Band-Mesh darf älter sein — ohne Bewegung über der Schwelle baut der
	# Frame nicht neu, und bis zu dieser Schwelle ist die Geometrie standgleich.
	var wl: PackedFloat32Array = (frame["filled"] as PackedByteArray).to_float32_array()
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
	print("frame_ms=", build_ms, " verts=", verts.size(), " bänder=", strip_kind)
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
		# Zusammenfluss (`WaterRender.ribbonJoin*`, Befund 2026-10-18): ein
		# Zubringer ohne Wasser in Reichweite läuft bis IN das Band seines
		# Hauptlaufs und blendet darunter aus. Sein Ende liegt dann im anderen
		# Band, nicht vor einer Wasserfläche; die Mündung prüft das Band des
		# Hauptlaufs selbst. Ohne diese Ausnahme zählte das als Spalt (macOS,
		# Seed 1337 Jahr 20.000: Zubringer endet bei Zelle 78,510 in einem
		# Hauptlauf, das Meer 14 Zellen stromab).
		if _inside_other_river(verts, cols, uv2s, starts, s, (verts[last] + verts[last + 1]) * 0.5, cs):
			joined += 1
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
		" zusammenflüsse=", joined, " mündungen_mit_spalt=", gaps)
	if gaps > 0:
		push_error("FAIL: %d Fluss-Band(-Enden) enden vor der Wasserfläche" % gaps)
		quit(1)
		return

	# --- Determinismus des Geometrie-Baus ------------------------------------
	# Seit Issue #214 gibt es keinen Einzelschritt-Bau mehr, den ein Skript
	# zweimal erzwingen könnte: ohne Bewegung baut der Frame nicht neu. Der
	# Determinismus-Nachweis (zweiter Bau == erster Bau) ist auf XCTest
	# umgezogen: SimCoreTests/RenderStateTests baut denselben Stand zweimal
	# direkt am `RiverRibbonRenderer`.

	print("WATER_GEOMETRY_OK")
	quit(0)

## Liegt `point` in einem ANDEREN, zu mindestens `ribbonJoinCoverage` deckenden
## Fluss-Band als `own`? Spiegelbild von `RiverRibbonRenderer.stampCoverage` und
## `joinPath`: geprüft wird das Bandsegment zwischen zwei Kantenpaaren mit linear
## interpolierter Halbbreite und Deckkraft sowie halber Zelle Längsüberhang an
## offenen Bandenden. QUER gilt `hw + cs` statt des `hw + halbe Zelle` von
## `stampCoverage`: der Helfer fragt den exakten Punkt des Bandendes ab,
## `stampCoverage` urteilt über ZELLMITTEN — die ganze Zelle deckelt den Versatz
## zwischen Endpunkt und der Mitte seiner Zelle (quer bis ~0,7 Zellen).
## Unsichtbare Quellenanfänge (Halbbreite 0, Alpha 0) und
## schwach deckende Ausläufer (< `ribbonJoinCoverage`) zählen nicht als
## Zusammenfluss.
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

## Gezielter Selbsttest für `_inside_other_river`: transparente Quellenanfänge,
## schwach deckende Segmente (< `ribbonJoinCoverage`), degenerierte Nullbreiten
## und Punkte hinter dem offenen Bandende dürfen die Spaltprüfung nicht
## überspringen; ein deckendes Fremdsegment (>= `ribbonJoinCoverage`) schon.
func _check_inside_other_river_guard() -> bool:
	var cs := 2.0
	var verts := PackedVector3Array([
		# Strip 0 (own): voll deckend am Ursprung — muss als eigenes Band ignoriert werden.
		Vector3(0.0, 0.0, -2.0), Vector3(0.0, 0.0, 2.0),
		Vector3(4.0, 0.0, -2.0), Vector3(4.0, 0.0, 2.0),
		# Strip 1: fremdes Fluss-Band, aber schwach deckend (unter ribbonJoinCoverage).
		Vector3(0.0, 0.0, -2.0), Vector3(0.0, 0.0, 2.0),
		Vector3(4.0, 0.0, -2.0), Vector3(4.0, 0.0, 2.0),
		# Strip 2: fremdes Fluss-Band mit Quellenanfang (Halbbreite 0, Alpha 0 bei
		# x=6) und voll deckendem Segment ab x=14..18. Der Quellenpunkt liegt
		# 4 Zellen (8 Welt-Einheiten) vor der Naht des gedeckten Segments und
		# damit außerhalb dessen Überhang (hw + cs) — läge er näher, nähme ihn
		# der Naht-Fußabdruck des gedeckten Nachbarn an, obwohl dort nichts
		# gemalt wird (CI-Befund zu 935bcf8), und der Fall prüfte nicht den
		# Quellenanfang.
		Vector3(6.0, 0.0, 0.0), Vector3(6.0, 0.0, 0.0),
		Vector3(14.0, 0.0, -2.0), Vector3(14.0, 0.0, 2.0),
		Vector3(18.0, 0.0, -2.0), Vector3(18.0, 0.0, 2.0),
		# Strip 3: fremdes Band mit Deckkraft 1, aber degenerierter Halbbreite 0 bei x=30..34.
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


# Trägt der letzte Band-Bau mindestens ein Band dieses Typs? Seit #214 aus
# dem Frame (die Einzelschritt-Callables sind weg); ein Frame ohne „ribbons"
# hat nicht neu gebaut und sagt nichts.
func _has_kind(frame: Dictionary, kind: float) -> bool:
	if not frame.has("ribbons"):
		return false
	var uv2s: PackedVector2Array = frame["ribbon_uv2s"]
	var starts: PackedInt32Array = frame["ribbon_strip_starts"]
	for s in starts.size():
		if starts[s] < uv2s.size() and uv2s[starts[s]].x == kind:
			return true
	return false
