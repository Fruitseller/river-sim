extends SceneTree
## A/B-Fingerabdruck aller Render-Puffer der GDExtension (GPU-frei):
##   godot --headless --path game --script res://tests/render_fingerprint.gd
##
## Druckt SHA-256 je Puffer nach einem festen Lauf (Seed/Jahre unten). Zweck:
## „bit-identisch zum Vorher-Stand" bei Umbauten der Render-AUFBEREITUNG ohne
## Physik-Änderung nachweisen — vorher laufen lassen, umbauen, nachher laufen
## lassen, Zeilen vergleichen. Keine Zusicherungen: die Hashes gelten je Maschine
## (System-libm), nicht plattformübergreifend.
##
## Seit Issue #214 liest das Werkzeug ALLES aus dem Frame (`SimNode.renderFrame`):
## die Einzelschritt-Callables der Brücke sind weg, und der Frame ist der einzige
## Weg — derselbe, den `Main.gd` fährt. Vorher/Nachher-Vergleiche gegen die alte
## Fassung (eigene Hand-Reihenfolge, Farben vor dem ersten Wasser-Aufruf und
## damit ohne nasse Wiese) sind NICHT gültig: beide Seiten müssen dieselbe
## Werkzeugfassung gegen ihren Bau laufen lassen.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

# Rohwerte von FrameTrigger (Main.gd FRAME_*; der Unicode-Vertrag dazu pinnt
# SimCoreTests/RenderFrameTests.testMainUsesTheFrameTriggerValues).
const FRAME_SETTLED := 0
const FRAME_TIMELAPSE := 2

const YEARS := 20000.0
# Über der Overlay-Drossel (0,30 s): der zweite Frame muss durchkommen.
const SECOND_FRAME_NOW := 1.0

var done := false

func _process(_delta: float) -> bool:
	if done:
		return true
	done = true
	_run()
	return true

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		quit(1)
		return
	var sim: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim):
		quit(1)
		return
	var y := 0.0
	while y < YEARS:
		sim.step(1000.0)
		y += 1000.0
	sim.recomputeFlow()

	print("year=", sim.currentYear())
	var hbytes: PackedByteArray = (sim.heights() as PackedFloat32Array).to_byte_array()
	# Der Textur-Pfad zieht die Höhen seit Issue #53 als ROHE Bytes aus SimNode
	# statt sie in GDScript zu konvertieren — das ist die einzige Zusicherung
	# hier, die auch ohne Vorher-Stand greift.
	if sim.heightsBytes() != hbytes:
		push_error("FAIL: heightsBytes != heights().to_byte_array()")
		quit(1)
		return
	_hash("heights", hbytes)

	# EIN Frame liefert alle Puffer in Produktions-Reihenfolge
	# (`RenderState.frame`): Bänder → Wasser → Farbe/Material/Deckung → Abfluss
	# → Schutzmaske → Waldmaske → Sedimentfahnen. Der erste Frame nach dem Lauf
	# MUSS die Bänder bauen (kein Vergleichsstand → Riesen-Delta).
	var frame: Dictionary = sim.renderFrame(FRAME_SETTLED, 0.0)
	if not frame.has("ribbons"):
		push_error("FAIL: erster Frame baut keine Fluss-Bänder")
		quit(1)
		return
	_hash("filled", frame["filled"])
	_hash("terrainColorBytes", frame["color"])
	_hash("terrainSurfaceBytes", frame["surface"])
	_hash("terrainCoverBytes", frame["cover"])
	_hash("waterFieldBytes(1.0)", frame["water"])
	_hash("flowDetailBytes", frame["flow"])
	_hash("sedimentPlume", frame["plume"])

	# Wasserfeld ein zweites Mal — der Zeitraffer-Takt mit dem kalibrierten
	# Blend 0.15: derselbe Weg dauert die EWMA-Puffer aus dem ersten Frame
	# fort, beide Hashes gehören zum Vertrag. Die Zeitraffer-Drossel umgeht der
	# Werkzeuglauf über die Uhr des Aufrufers (SECOND_FRAME_NOW).
	var second: Dictionary = sim.renderFrame(FRAME_TIMELAPSE, SECOND_FRAME_NOW)
	if not second.has("water"):
		push_error("FAIL: zweiter Frame trotz freier Drossel ohne Wasser")
		quit(1)
		return
	_hash("waterFieldBytes(0.15)", second["water"])
	_hash("heightDifferenceBytes", (sim.heightDifferenceBytes(0.01) as PackedByteArray))
	print("debugTerrainStats=", sim.debugTerrainStats())
	_hash("protectMaskBytes", second["protect"])
	_hash("forestMaskBytes", second["forest"])

	_hash("ribbonVerts", (frame["ribbon_verts"] as PackedVector3Array).to_byte_array())
	_hash("ribbonColors", (frame["ribbon_colors"] as PackedColorArray).to_byte_array())
	_hash("ribbonUVs", (frame["ribbon_uvs"] as PackedVector2Array).to_byte_array())
	_hash("ribbonUV2s", (frame["ribbon_uv2s"] as PackedVector2Array).to_byte_array())
	_hash("ribbonIndices", (frame["ribbon_indices"] as PackedInt32Array).to_byte_array())
	_hash("ribbonStripStarts", (frame["ribbon_strip_starts"] as PackedInt32Array).to_byte_array())
	print("RENDER_FINGERPRINT_OK")
	quit(0)

func _hash(label: String, bytes) -> void:
	var packed: PackedByteArray = bytes
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(packed)
	print(label, " len=", packed.size(), " sha256=", ctx.finish().hex_encode())
