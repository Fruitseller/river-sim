extends SceneTree
## A/B-Fingerabdruck aller Render-Puffer der GDExtension (GPU-frei):
##   godot --headless --path game --script res://tests/render_fingerprint.gd
##
## Druckt SHA-256 je Puffer nach einem festen Lauf (Seed/Jahre unten). Zweck:
## „bit-identisch zum Vorher-Stand" bei Umbauten der Render-AUFBEREITUNG ohne
## Physik-Änderung nachweisen — vorher laufen lassen, umbauen, nachher laufen
## lassen, Zeilen vergleichen. Keine Zusicherungen: die Hashes gelten je Maschine
## (System-libm), nicht plattformübergreifend.

const BuildStamp = preload("res://scripts/BuildStamp.gd")

const HSCALE := 24.0
const RIVER_LIFT := 0.35
const YEARS := 20000.0

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
	var fbytes: PackedByteArray = (sim.filled() as PackedFloat32Array).to_byte_array()
	# Der Textur-Pfad zieht die Felder seit Issue #53 als ROHE Bytes aus SimNode
	# statt sie in GDScript zu konvertieren. Beide Wege müssen byte-gleich sein —
	# das ist die einzige Zusicherung hier und die einzige, die auch ohne
	# Vorher-Stand greift.
	if sim.heightsBytes() != hbytes:
		push_error("FAIL: heightsBytes != heights().to_byte_array()")
		quit(1)
		return
	if sim.filledBytes() != fbytes:
		push_error("FAIL: filledBytes != filled().to_byte_array()")
		quit(1)
		return
	_hash("heights", hbytes)
	_hash("filled", fbytes)
	_hash("terrainColorBytes", sim.terrainColorBytes())
	_hash("terrainSurfaceBytes", sim.terrainSurfaceBytes())
	# Wasserfeld zweimal: der zweite Aufruf durchläuft die EWMA-Puffer aus dem
	# ersten (persistenter Render-Zustand) — beide Hashes gehören zum Vertrag.
	_hash("waterFieldBytes(1.0)", sim.waterFieldBytes(1.0))
	_hash("waterFieldBytes(0.15)", sim.waterFieldBytes(0.15))
	_hash("heightDifferenceBytes", sim.heightDifferenceBytes(0.01))
	print("debugTerrainStats=", sim.debugTerrainStats())
	for v in 3:
		_hash("treeInstanceBuffer(%d)" % v,
			(sim.treeInstanceBuffer(v, HSCALE, 2) as PackedFloat32Array).to_byte_array())
	sim.buildRiverRibbons(HSCALE, RIVER_LIFT)
	_hash("ribbonVerts", (sim.riverRibbonVerts() as PackedVector3Array).to_byte_array())
	_hash("ribbonColors", (sim.riverRibbonColors() as PackedColorArray).to_byte_array())
	_hash("ribbonUVs", (sim.riverRibbonUVs() as PackedVector2Array).to_byte_array())
	_hash("ribbonUV2s", (sim.riverRibbonUV2s() as PackedVector2Array).to_byte_array())
	_hash("ribbonIndices", (sim.riverRibbonIndices() as PackedInt32Array).to_byte_array())
	_hash("ribbonStripStarts", (sim.riverRibbonStripStarts() as PackedInt32Array).to_byte_array())
	print("riversMaxDelta=", sim.riversMaxDelta(), " treeVegMaxDelta=", sim.treeVegMaxDelta())
	print("RENDER_FINGERPRINT_OK")
	quit(0)

func _hash(label: String, bytes: PackedByteArray) -> void:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	print(label, " len=", bytes.size(), " sha256=", ctx.finish().hex_encode())
