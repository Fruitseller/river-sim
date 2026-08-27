extends SceneTree
## Kostenaufschlüsselung des Nachzugs nach einem Pinselstrich (GPU-frei):
##   godot --headless --path game --script res://tests/sculpt_cost.gd
##
## Kein Wächter, sondern das MESSWERKZEUG hinter SCULPT_REFRESH_SECONDS und der
## Zwei-Frame-Aufteilung in Main.gd: Sculpting stockte, und die Frage „welcher
## Aufruf kostet das?" war vorher nur geschätzt. Druckt je Aufruf die schnellste
## von drei Messungen (bester Fall, damit Scheduler-Rauschen nicht dominiert),
## jeweils nach einem frischen Pinselhieb — die Render-Caches der GDExtension
## sind dann so schmutzig wie mitten im Strich.
##
## Keine Zusicherungen: die Zeiten gelten je Maschine. Erwartungswerte stehen
## bewusst nicht hier, sondern als gemessene Zahlen am Aufrufer in Main.gd.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

const HSCALE := 24.0
const RIVER_LIFT := 0.35
const RENDER_GRID := 384   # == BALANCED_TERRAIN_GRID (Main.gd), der Standard
const YEARS := 2000.0      # eingelaufenes Flussnetz, nicht der Startzustand

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert — Projekt importiert?")
		quit(1)
		return true
	var sim: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim):
		quit(1)
		return true

	var n: int = sim.gridSize()
	sim.setRenderGrid(RENDER_GRID)
	sim.step(YEARS)
	print("n=", n, " render_grid=", RENDER_GRID, " Jahre=", YEARS)

	var mid := n * 0.5
	var measure := func(label: String, call: Callable) -> void:
		var best := INF
		for _i in 3:
			sim.brush(0, mid, mid, 10.0, 1.0, 0.0)  # Hieb wie im Strich
			var t0 := Time.get_ticks_usec()
			call.call()
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		print("%-24s %8.2f ms" % [label, best])

	# Reihenfolge wie in Main.gd: jeden Frame nur die Höhe, der Rest im Nachzug.
	measure.call("heightsBytes", func() -> void: sim.heightsBytes())
	measure.call("recomputeFlow", func() -> void: sim.recomputeFlow())
	measure.call("filledBytes", func() -> void: sim.filledBytes())
	measure.call("terrainColorBytes", func() -> void: sim.terrainColorBytes())
	measure.call("terrainSurfaceBytes", func() -> void: sim.terrainSurfaceBytes())
	measure.call("waterFieldBytes(1.0)", func() -> void: sim.waterFieldBytes(1.0))
	measure.call("buildRiverRibbons", func() -> void: sim.buildRiverRibbons(HSCALE, RIVER_LIFT))
	quit(0)
	return true
