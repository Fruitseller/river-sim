extends SceneTree

const BuildStamp = preload("res://scripts/BuildStamp.gd")

const FRAME_SETTLED := 0
const FRAME_TIMELAPSE := 2

const YEARS := 20000.0
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
	if sim.heightsBytes() != hbytes:
		push_error("FAIL: heightsBytes != heights().to_byte_array()")
		quit(1)
		return
	_hash("heights", hbytes)

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
