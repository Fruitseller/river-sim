extends SceneTree
## Vertragstest des Mutter-Natur-Prototyps (Issue #223), lokal:
##   godot --headless --path game --script res://tests/nature_mode.gd
## Die Prüfungen stehen in `tests/NatureChecks.gd`; in CI laufen sie als Teil
## von `tests/ui_layout.gd`.

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const Main = preload("res://scripts/Main.gd")
const NatureChecks = preload("res://tests/NatureChecks.gd")

var failures := 0
var main: Node
var started := false

func _initialize() -> void:
	if not ClassDB.class_exists("SimNode"):
		print("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var probe: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(probe):
		quit(1)
		return
	probe.free()
	OS.set_environment("RS_NATURE", "1")
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if started or main == null or not main.is_node_ready():
		return false
	started = true
	NatureChecks.run(main, _check)
	main.queue_free()
	if failures > 0:
		quit(1)
		return false
	print("NATURE_MODE_OK")
	quit(0)
	return false

func _check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		print("FAIL: ", message)
