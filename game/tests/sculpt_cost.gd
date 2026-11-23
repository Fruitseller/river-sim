extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")

const FRAME_STROKE := 3
const Main = preload("res://scripts/Main.gd")
const YEARS := 2000.0

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
	var render_grid := Main.terrain_grid_for("balanced", n)
	sim.setRenderGrid(render_grid)
	sim.step(YEARS)
	print("n=", n, " render_grid=", render_grid, " Jahre=", YEARS)

	var mid := n * 0.5
	var measure := func(label: String, call: Callable) -> void:
		var best := INF
		for _i in 3:
			sim.brush(0, mid, mid, 10.0, 1.0, 0.0)
			var t0 := Time.get_ticks_usec()
			call.call()
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		print("%-24s %8.2f ms" % [label, best])

	measure.call("heightsBytes", func() -> void: sim.heightsBytes())
	measure.call("recomputeFlow", func() -> void: sim.recomputeFlow())
	measure.call("renderFrame(STROKE)", func() -> void: sim.renderFrame(FRAME_STROKE, 0.0))
	quit(0)
	return true
