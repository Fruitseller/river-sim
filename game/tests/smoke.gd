extends SceneTree
## Headless-Smoke-Test der GDExtension — GPU-frei ausführbar mit:
##   godot --headless --path game --script res://tests/smoke.gd
## Prüft: Library aktuell (Build-Stempel), SimNode registriert, Felder haben n*n
## Einträge, step() verändert das Terrain, Jahr läuft, Sculpting wirkt.
## Exit-Code != 0 bei Fehler.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		# Häufigste Ursache in einem frischen Arbeitsverzeichnis: Godot lädt
		# GDExtensions NUR aus `.godot/extension_list.cfg`, und die entsteht erst
		# beim Projekt-Import. `game/.godot/` ist gitignoriert, also fehlt sie in
		# jedem neuen Klon/Worktree — die Library selbst ist dann völlig in
		# Ordnung. Ohne diesen Hinweis zeigt die Meldung auf die falsche Stelle.
		if not FileAccess.file_exists("res://.godot/extension_list.cfg"):
			push_error("FAIL: Projekt nicht importiert (res://.godot/extension_list.cfg "
				+ "fehlt) — GDExtension wurde nie geladen. Einmalig ausführen: "
				+ "godot --headless --path game --import")
		else:
			push_error("FAIL: SimNode nicht registriert")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")

	# Zuerst prüfen, ob die geladene Library zum Quellstand passt: alles danach
	# testet sonst eine alte .so, und Fehlschläge sind dann irreführend
	# (historisch: "Nonexistent function brush" nach vergessenem Rebuild).
	if not BuildStamp.check(sim):
		quit(1)
		return

	var n: int = sim.gridSize()
	var h0: PackedFloat32Array = sim.heights()
	print("grid=", n, " sea=", sim.seaLevel(), " heights_len=", h0.size())
	if h0.size() != n * n:
		push_error("FAIL: heights-Länge %d != %d" % [h0.size(), n * n])
		quit(1)
		return

	sim.step(10000.0)
	var h1: PackedFloat32Array = sim.heights()
	var diff := 0.0
	for i in range(h1.size()):
		diff += absf(h1[i] - h0[i])
	print("year=", sim.currentYear(), " erosion_change_sum=", diff)
	if sim.currentYear() < 9999.0 or diff <= 0.0:
		push_error("FAIL: step() ohne Wirkung")
		quit(1)
		return

	# Sculpting: Zentrum anheben.
	var before: PackedFloat32Array = sim.heights()
	var c := (n / 2) * n + (n / 2)
	for k in range(50):
		sim.sculpt(float(n) / 2.0, float(n) / 2.0, 12.0, 1.0)
	sim.recomputeFlow()
	var after: PackedFloat32Array = sim.heights()
	print("sculpt_delta_center=", after[c] - before[c])
	if after[c] - before[c] <= 0.0:
		push_error("FAIL: sculpt hebt nicht an")
		quit(1)
		return

	# Brush-Werkzeuge (Modi siehe SimNode.brush): Spitzhacke senkt, Einebnen
	# zieht zur Zielhöhe, Glätten reduziert die lokale Rauheit.
	var cx := float(n) / 2.0
	before = sim.heights()
	for k in range(30):
		sim.brush(5, cx, cx, 8.0, 1.0, 0.0) # Spitzhacke
	after = sim.heights()
	print("pickaxe_delta_center=", after[c] - before[c])
	if after[c] - before[c] >= 0.0:
		push_error("FAIL: Spitzhacke senkt nicht ab")
		quit(1)
		return

	var target := after[c] + 0.1
	for k in range(200):
		sim.brush(3, cx, cx, 8.0, 2.0, target) # Einebnen
	after = sim.heights()
	print("flatten_dist_to_target=", absf(after[c] - target))
	if absf(after[c] - target) > 0.02:
		push_error("FAIL: Einebnen erreicht die Zielhöhe nicht")
		quit(1)
		return

	for k in range(20):
		sim.brush(4, cx, cx, 10.0, 1.0, 0.0) # Aufrauen
	var rough: PackedFloat32Array = sim.heights()
	var vr_before := _local_roughness(rough, n, c)
	for k in range(60):
		sim.brush(2, cx, cx, 10.0, 2.0, 0.0) # Glätten
	var smoothed: PackedFloat32Array = sim.heights()
	var vr_after := _local_roughness(smoothed, n, c)
	print("roughness_before=", vr_before, " after_smooth=", vr_after)
	if vr_after >= vr_before:
		push_error("FAIL: Glätten reduziert die Rauheit nicht")
		quit(1)
		return

	# Speichern/Laden über die Brücke (Issue #8). Die Bit-Identität des
	# Weiterlaufs prüft SimCore (`WorldSnapshotTests`); hier geht es um den
	# GDExtension-Vertrag: Datei entsteht, Zustand kommt zurück, eine Datei mit
	# fremder Formatversion wird ABGELEHNT, ohne die laufende Welt anzutasten.
	var save_path := "user://tests/smoke.%s" % sim.worldFileExtension()
	var abs_save := ProjectSettings.globalize_path(save_path)
	var saved_year: float = sim.currentYear()
	var saved_sum := _height_sum(sim.heights())
	var save_err: String = sim.saveWorld(abs_save)
	if not save_err.is_empty():
		push_error("FAIL: saveWorld: %s" % save_err)
		quit(1)
		return
	var bytes: int = sim.lastWorldFileBytes()
	print("world_saved_bytes=", bytes, " grid_from_file=", sim.worldFileGridSize(abs_save),
		" world_from_file=", sim.worldFileWorldSize(abs_save))
	if bytes <= 0 or not FileAccess.file_exists(save_path):
		push_error("FAIL: Welt-Datei fehlt")
		quit(1)
		return
	# Die Vorprüfung der Geometrie liest Kopf + Config, nicht die Felder — beide
	# Werte müssen zur laufenden Welt passen.
	if sim.worldFileGridSize(abs_save) != n:
		push_error("FAIL: Gitterauflösung der Datei stimmt nicht")
		quit(1)
		return
	if not is_equal_approx(sim.worldFileWorldSize(abs_save), sim.worldSize()):
		push_error("FAIL: Weltgröße der Datei stimmt nicht")
		quit(1)
		return
	if not _check_geometry_guard(n, sim.worldSize()):
		quit(1)
		return

	sim.step(500.0) # Welt verändern, damit das Laden etwas zurückholen MUSS
	var load_err: String = sim.loadWorld(abs_save)
	if not load_err.is_empty():
		push_error("FAIL: loadWorld: %s" % load_err)
		quit(1)
		return
	var loaded_sum := _height_sum(sim.heights())
	print("year_after_load=", sim.currentYear(), " height_sum_delta=", loaded_sum - saved_sum)
	if absf(sim.currentYear() - saved_year) > 0.0 or loaded_sum != saved_sum:
		push_error("FAIL: geladener Zustand weicht vom gespeicherten ab")
		quit(1)
		return

	# Datei auf eine andere Formatversion umbiegen (Byte 8..11 = 0) → muss
	# abgelehnt werden, statt falsch geladen zu werden.
	var raw := FileAccess.get_file_as_bytes(save_path)
	for i in range(8, 12):
		raw[i] = 0
	var old_path := "user://tests/smoke_v0.%s" % sim.worldFileExtension()
	var f := FileAccess.open(old_path, FileAccess.WRITE)
	f.store_buffer(raw)
	f.close()
	var reject: String = sim.loadWorld(ProjectSettings.globalize_path(old_path))
	print("old_version_error=", reject)
	if reject.is_empty() or not reject.contains("Version"):
		push_error("FAIL: alte Formatversion wurde nicht abgelehnt")
		quit(1)
		return
	if absf(sim.currentYear() - saved_year) > 0.0:
		push_error("FAIL: abgelehntes Laden hat die Welt verändert")
		quit(1)
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(old_path))

	print("SMOKE_OK")
	quit(0)

## Prüft die Geometrie-Sperre der UI (`Main.gd._world_geometry_mismatch`): eine
## Welt-Datei darf nur geladen werden, wenn AUFLÖSUNG UND WELTGRÖSSE zur
## laufenden Sitzung passen — sonst liefe die Simulation in anderen
## Weltkoordinaten als Darstellung, Kamera und Werkzeuge. Die Funktion ist reine
## Entscheidungslogik und deshalb ohne Szene/Renderer prüfbar: das Skript wird
## instanziiert, aber nie in den Baum gehängt (kein `_ready`).
func _check_geometry_guard(n: int, world: float) -> bool:
	var main: Node = load("res://scripts/Main.gd").new()
	main.N = n
	main.world_size = world
	var ok := true
	if not (main._world_geometry_mismatch(n, world) as String).is_empty():
		push_error("FAIL: passende Geometrie wurde abgelehnt")
		ok = false
	if (main._world_geometry_mismatch(n / 2, world) as String).is_empty():
		push_error("FAIL: abweichende Gitterauflösung wurde NICHT abgelehnt")
		ok = false
	if (main._world_geometry_mismatch(n, world * 0.5) as String).is_empty():
		push_error("FAIL: abweichende Weltgröße wurde NICHT abgelehnt")
		ok = false
	# −1 = Datei nicht lesbar: die Sperre schweigt, die Meldung kommt aus loadWorld.
	if not (main._world_geometry_mismatch(-1, -1.0) as String).is_empty():
		push_error("FAIL: unlesbare Datei sollte die Geometrie-Sperre nicht auslösen")
		ok = false
	print("geometry_guard_ok=", ok)
	main.free()
	return ok

## Summe der Höhen — kompakter Vergleichswert für „derselbe Zustand".
func _height_sum(h: PackedFloat32Array) -> float:
	var s := 0.0
	for v in h:
		s += v
	return s

## Mittlere absolute Nachbar-Differenz in einem 9×9-Fenster um Zelle c.
func _local_roughness(h: PackedFloat32Array, n: int, c: int) -> float:
	var ci := c % n
	var cj := c / n
	var s := 0.0
	var cnt := 0
	for j in range(cj - 4, cj + 5):
		for i in range(ci - 4, ci + 4):
			var k := j * n + i
			s += absf(h[k + 1] - h[k])
			cnt += 1
	return s / cnt
