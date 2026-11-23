extends RefCounted

const SCALE := {"performance": 0.5, "balanced": 0.67, "quality": 1.0}

static func scale_for(quality: String) -> float:
	return SCALE.get(quality, SCALE["balanced"])

static func mode_for(driver: String) -> Viewport.Scaling3DMode:
	match driver:
		"metal":
			return Viewport.SCALING_3D_MODE_METALFX_SPATIAL
		"vulkan", "d3d12":
			return Viewport.SCALING_3D_MODE_FSR
	return Viewport.SCALING_3D_MODE_BILINEAR

static func apply(vp: Viewport, quality: String) -> void:
	var scale := scale_for(quality)
	var env_scale := OS.get_environment("RS_RENDER_SCALE").replace(",", ".")
	if env_scale.is_valid_float():
		scale = clampf(env_scale.to_float(), 0.25, 1.0)
	var driver := RenderingServer.get_current_rendering_driver_name()
	var mode := mode_for(driver)
	var wanted := OS.get_environment("RS_SCALING")
	var supported := {"bilinear": true, "fsr": driver in ["vulkan", "d3d12"], "metalfx": driver == "metal"}
	if supported.has(wanted):
		if supported[wanted]:
			mode = {"bilinear": Viewport.SCALING_3D_MODE_BILINEAR, "fsr": Viewport.SCALING_3D_MODE_FSR,
				"metalfx": Viewport.SCALING_3D_MODE_METALFX_SPATIAL}[wanted]
		else:
			push_warning("RS_SCALING=%s gibt es auf dem Treiber '%s' nicht, bleibe beim Standard" % [wanted, driver])
	if scale >= 1.0:
		mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_mode = mode
	vp.scaling_3d_scale = scale
