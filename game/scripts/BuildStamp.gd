extends RefCounted
## Build-Stempel-Prüfung auf der Godot-Seite: berechnet den Stempel des
## Arbeitsverzeichnisses und vergleicht ihn mit dem, den SimNode zur Bauzeit
## eingebrannt bekommen hat.
##
## Godot lädt `game/bin/libRiverSimGD.so` blind — eine veraltete Library fällt
## sonst erst als "Nonexistent function ..." auf (real passiert mit `brush`).
## Das Verfahren muss BYTEGLEICH zu `scripts/build-stamp.sh` sein:
##   1. Alle regulären Dateien unter Extension/Sources und SimCore/Sources,
##      außer dem generierten Stempel selbst.
##   2. Pfade relativ zur Repo-Wurzel, sortiert (ASCII-Pfade → gleiche Ordnung
##      wie `LC_ALL=C sort`).
##   3. Manifest-Zeile je Datei: "<sha256>  <relpfad>\n" (zwei Leerzeichen).
##   4. Stempel = sha256 des Manifests.

## Quellbäume, die in die Library kompiliert werden.
const ROOTS := ["Extension/Sources", "SimCore/Sources"]
## Der generierte Stempel selbst ist ausgenommen (er hängt sonst von sich ab).
const GENERATED_DIR := "Extension/Sources/RiverSimGD/Generated"
const REBUILD_HINT := "\"$(git rev-parse --show-toplevel)\"/scripts/build.sh release"

## Repo-Wurzel: res:// ist das Godot-Projekt `game/`, die Wurzel liegt darüber.
static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()

## Stempel des Arbeitsverzeichnisses.
static func source_stamp(root: String = "") -> String:
	if root.is_empty():
		root = repo_root()
	var files: Array[String] = []
	for rel in ROOTS:
		_collect(root, rel, files)
	files.sort()
	var manifest := ""
	for rel in files:
		manifest += "%s  %s\n" % [FileAccess.get_sha256(root.path_join(rel)), rel]
	return manifest.sha256_text()

## Bricht mit Rebuild-Hinweis ab (Rückgabe false), wenn `sim` aus einer Library
## stammt, die nicht zum Arbeitsverzeichnis passt.
static func check(sim: Object) -> bool:
	var want := source_stamp()
	if not sim.has_method("buildStamp"):
		_fail("Die geladene GDExtension kennt buildStamp() nicht und ist damit"
			+ " älter als diese Prüfung.", "", want)
		return false
	var have: String = sim.buildStamp()
	if have == want:
		return true
	_fail("Die geladene GDExtension ist VERALTET (Build-Stempel weicht vom"
		+ " Quellstand ab).", have, want)
	return false

static func _fail(reason: String, have: String, want: String) -> void:
	var lines := ["FAIL: " + reason]
	if not have.is_empty():
		lines.append("  Library:    " + have)
	lines.append("  Quellstand: " + want)
	lines.append("Neu bauen (Linux ~21,5 min), danach erneut starten:")
	lines.append("  " + REBUILD_HINT)
	var message := "\n".join(lines)
	print(message)
	push_error(message)

## Sammelt Dateien unter root/rel rekursiv als repo-relative Pfade.
static func _collect(root: String, rel: String, out: Array[String]) -> void:
	if rel == GENERATED_DIR or rel.begins_with(GENERATED_DIR + "/"):
		return
	var dir := DirAccess.open(root.path_join(rel))
	if dir == null:
		# Fehlendes Verzeichnis nicht abfangen: der Stempel weicht dann ab, und
		# genau das ist die gewünschte laute Reaktion.
		return
	# `find` sieht auch Punktdateien — DirAccess muss das ebenfalls tun, sonst
	# driften Shell- und Godot-Stempel auseinander.
	dir.include_hidden = true
	for name in dir.get_files():
		out.append(rel.path_join(name))
	for name in dir.get_directories():
		_collect(root, rel.path_join(name), out)
