extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	var root := BuildStamp.repo_root()
	var script := root.path_join("scripts/build-stamp.sh")
	if not FileAccess.file_exists(script):
		_fail("scripts/build-stamp.sh nicht gefunden (erwartet: %s)" % script)
		return

	var out: Array = []
	var code := OS.execute(script, ["--source"], out, true)
	if code != 0:
		_fail("scripts/build-stamp.sh --source endete mit Code %d:\n%s"
			% [code, "\n".join(PackedStringArray(out))])
		return

	var shell_stamp := "\n".join(PackedStringArray(out)).strip_edges()
	var gd_stamp := BuildStamp.source_stamp()
	print("shell=", shell_stamp)
	print("gdscript=", gd_stamp)

	if shell_stamp.length() != 64:
		_fail("scripts/build-stamp.sh --source lieferte keinen SHA-256: %s" % shell_stamp)
		return
	if shell_stamp != gd_stamp:
		_fail("Build-Stempel-Verfahren driften auseinander.\n"
			+ "  scripts/build-stamp.sh:      " + shell_stamp + "\n"
			+ "  game/scripts/BuildStamp.gd:  " + gd_stamp + "\n"
			+ "Beide Seiten müssen dieselben Dateien, dieselbe Sortierung und "
			+ "dasselbe Manifest-Format verwenden (Verfahren: Kopf beider Dateien).")
		return

	print("Build-Stempel-Parität Shell <-> GDScript")
	print("BUILD_STAMP_PARITY_OK")
	quit(0)

func _fail(message: String) -> void:
	print("FAIL: " + message)
	push_error("FAIL: " + message)
	quit(1)
