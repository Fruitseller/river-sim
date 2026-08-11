extends SceneTree
## Diagnose (nicht Teil der Suite): zählt die Baum-Instanzen je Variante,
## einmal frisch generiert und einmal nach 20k Jahren.

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	var sim: Object = ClassDB.instantiate("SimNode")
	_report(sim, "frisch")
	sim.step(20000.0)
	_report(sim, "20k Jahre")
	print("delta_nach_step=", sim.treeVegMaxDelta())
	quit(0)

func _report(sim: Object, label: String) -> void:
	for coverage in [1, 2]:
		var total := 0
		var counts := []
		for v in 3:
			var buf: PackedFloat32Array = sim.treeInstanceBuffer(v, 24.0, coverage)
			counts.append(buf.size() / 12)
			total += buf.size() / 12
		var mode := "reduziert" if coverage == 1 else "voll"
		print(label, " ", mode, ": laub=", counts[0], " nadel=", counts[1], " busch=", counts[2], " total=", total)
