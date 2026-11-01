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
## Seit Issue #214 gibt es keine Einzelschritt-Callables mehr: der Frame
## (`renderFrame`, FRAME_STROKE wie Main.gd am Strich-Nachzug) ist die ganze
## Rechnung, die der Hauptthread bezahlt. Die Aufschlüsselung nach Pässen lebt
## headless in SimProfile (simperf --repeat druckt die Pass-Tabelle).
##
## Keine Zusicherungen: die Zeiten gelten je Maschine. Erwartungswerte stehen
## bewusst nicht hier, sondern als gemessene Zahlen am Aufrufer in Main.gd.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

const FRAME_STROKE := 3   # FrameTrigger.stroke — Main.gd FRAME_STROKE
const Main = preload("res://scripts/Main.gd")
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
	var render_grid := Main.terrain_grid_for("balanced", n) # der Standard
	sim.setRenderGrid(render_grid)
	sim.step(YEARS)
	print("n=", n, " render_grid=", render_grid, " Jahre=", YEARS)

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
	# FRAME_STROKE ist ungedrosselt — die Uhr spielt für die Messung keine Rolle.
	measure.call("heightsBytes", func() -> void: sim.heightsBytes())
	measure.call("recomputeFlow", func() -> void: sim.recomputeFlow())
	measure.call("renderFrame(STROKE)", func() -> void: sim.renderFrame(FRAME_STROKE, 0.0))
	quit(0)
	return true
