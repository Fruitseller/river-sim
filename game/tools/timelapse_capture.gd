extends SceneTree
## Nimmt den Zeitraffer in ECHTZEIT auf, Bild für Bild aus dem Fenster, für
## den Flimmer-Nachweis der Gelände-Verfeinerung (#238):
##
##   RS_SEED=1337 RS_STEP=20000 RS_RATE=60 CAPTURE_OUT=/abs/ordner \
##     CAPTURE_SECONDS=12 godot --path game --resolution 1728x1052 \
##     --script res://tools/timelapse_capture.gd
##
## Godots Movie-Modus (`--write-movie`) taugt dafür nicht: er rechnet die
## Bilder in fester Bildzeit, die Sim tickt und die Überblenden laufen aber
## auf der echten Uhr (`Main._now`), im Film springt der Stand deshalb, statt
## zu gleiten. Hier läuft alles wie am Bildschirm; die Aufnahme kostet nur
## Bildrate. Schreibt `<nr>.jpg` und `stamps.txt` (Sekunden je Bild).
## scripts/look/zeitraffer-video.sh baut daraus das Video.

const Main = preload("res://scripts/Main.gd")
const WARMUP_SECONDS := 2.0

var main: Node
var out := ""
var seconds := 12.0
var start := -1.0
var stamps := PackedFloat32Array()

func _initialize() -> void:
	out = OS.get_environment("CAPTURE_OUT")
	if OS.has_environment("CAPTURE_SECONDS"):
		seconds = float(OS.get_environment("CAPTURE_SECONDS"))
	DirAccess.make_dir_recursive_absolute(out)
	main = Main.new()
	root.add_child(main)

func _process(_delta: float) -> bool:
	if main == null or not main.is_node_ready():
		return false
	var now := Time.get_ticks_msec() / 1000.0
	if start < 0.0:
		start = now + WARMUP_SECONDS
	if now < start:
		return false
	if now - start >= seconds:
		var f := FileAccess.open(out.path_join("stamps.txt"), FileAccess.WRITE)
		for s in stamps:
			f.store_line("%.4f" % s)
		f.close()
		print("CAPTURE_OK %d Bilder in %.1f s" % [stamps.size(), seconds])
		main.queue_free()
		quit(0)
		return true
	var img := root.get_texture().get_image()
	img.save_jpg(out.path_join("%05d.jpg" % stamps.size()), 0.93)
	stamps.append(now - start)
	return false
