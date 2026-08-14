extends SceneTree
## Parität der beiden Build-Stempel-Verfahren (Issue #52) — GPU-frei ausführbar:
##   godot --headless --path game --script res://tests/build_stamp_parity.gd
##
## `scripts/build-stamp.sh` (Shell, brennt den Stempel beim Bauen ein) und
## `game/scripts/BuildStamp.gd` (GDScript, prüft ihn beim Start) berechnen
## DENSELBEN Hash auf ZWEI Wegen. AGENTS.md verlangt, dass beide bytegleich
## bleiben — bislang war das eine Review-Zusage. Driften sie auseinander, ist
## die Folge nicht „Test rot", sondern: jeder Start meldet fälschlich eine
## veraltete Library, oder — schlimmer — eine WIRKLICH veraltete Library fällt
## nicht mehr auf.
##
## Braucht die GDExtension NICHT: der Vergleich läuft rein auf dem Quellbaum.
## Damit hat er auch dann noch Aussagekraft, wenn der Extension-Build scheitert.
##
## Sinnvoll erst NACH `scripts/build.sh`: dann existiert
## `Extension/Sources/RiverSimGD/Generated/BuildStamp.swift`, und der Vergleich
## deckt zusätzlich ab, dass beide Seiten dieselbe Datei ausnehmen.
##
## Exit-Code != 0 bei Abweichung.

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

	# Die Shell-Seite selbst ausführen statt ihren Wert durchzureichen: nur so
	# vergleicht der Test die beiden VERFAHREN und nicht zwei Aufrufe desselben.
	# build-stamp.sh setzt sein Arbeitsverzeichnis selbst (`cd $(dirname $0)/..`).
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

	print("OK: Build-Stempel-Parität Shell <-> GDScript")
	quit(0)

func _fail(message: String) -> void:
	print("FAIL: " + message)
	push_error("FAIL: " + message)
	quit(1)
