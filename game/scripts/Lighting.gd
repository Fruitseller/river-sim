extends RefCounted

const SUN_AZIMUTH_DEG := -50.0
const SUN_ELEVATION_DEG := 30.0
const SUN_COLOR := Color(1.0, 0.85, 0.66)
const SUN_ENERGY := 2.4

const SKY_TOP := Color(0.14, 0.33, 0.68)
const SKY_HORIZON := Color(0.74, 0.80, 0.87)
const SKY_GROUND_BOTTOM := Color(0.22, 0.27, 0.32)

const AMBIENT_ENERGY := 0.48
const AMBIENT_SKY_CONTRIBUTION := 0.80
const AMBIENT_COLOR := Color(0.56, 0.57, 0.58)

const TONEMAP_EXPOSURE := 0.95
const TONEMAP_AGX_CONTRAST := 1.45
const ADJUST_CONTRAST := 1.08
const ADJUST_SATURATION := 1.15

const FOG_DENSITY := 0.0011
const FOG_AERIAL_PERSPECTIVE := 0.6
const FOG_SUN_SCATTER := 0.40
const FOG_SKY_AFFECT := 0.35
const VALLEY_FOG_ABOVE_SEA := 1.5
const VALLEY_FOG_DENSITY := 0.035

const CLOUD_STRENGTH := 0.24
const CLOUD_SCALE := 0.028
const CLOUD_BASE_FADE := 0.8

const CLOUD_BASE_ABOVE_RIDGE := 0.6
const CLOUD_RIDGE_FALLBACK := Vector2(12.0, 13.9)
const CLOUD_LAYERS := 3
const CLOUD_LAYER_STEP := 0.45
const CLOUD_BODY_OPACITY := 0.55
const CLOUD_BODY_LIFT := 0.10
const CLOUD_BODY_SELF_SHADOW_DIST := 0.9
const CLOUD_BODY_SELF_SHADOW_GAIN := 2.5

const QUALITY := {
	"performance": {"shadow_atlas": 4096, "shadow_splits": 2, "clouds": false},
	"balanced": {"shadow_atlas": 8192, "shadow_splits": 4, "clouds": true},
	"quality": {"shadow_atlas": 8192, "shadow_splits": 4, "clouds": true},
}

static func profile(quality: String) -> Dictionary:
	return QUALITY.get(quality, QUALITY["balanced"])

static func sun_direction() -> Vector3:
	var az := deg_to_rad(SUN_AZIMUTH_DEG)
	var el := deg_to_rad(SUN_ELEVATION_DEG)
	return Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az))

static func make_environment(quality: String, sea_y: float) -> Environment:
	var e := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.ground_horizon_color = SKY_HORIZON
	sky_mat.ground_bottom_color = SKY_GROUND_BOTTOM
	sky_mat.sun_angle_max = 8.0
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = AMBIENT_ENERGY
	e.ambient_light_sky_contribution = AMBIENT_SKY_CONTRIBUTION
	e.ambient_light_color = AMBIENT_COLOR
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_exposure = TONEMAP_EXPOSURE
	e.tonemap_agx_contrast = TONEMAP_AGX_CONTRAST
	e.ssao_enabled = quality != "performance"
	e.ssao_radius = 2.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.4
	e.glow_enabled = false
	e.adjustment_enabled = true
	e.adjustment_contrast = ADJUST_CONTRAST
	e.adjustment_saturation = ADJUST_SATURATION
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = SKY_HORIZON
	e.fog_density = FOG_DENSITY
	e.fog_aerial_perspective = FOG_AERIAL_PERSPECTIVE
	e.fog_sun_scatter = FOG_SUN_SCATTER
	e.fog_sky_affect = FOG_SKY_AFFECT
	e.fog_height = sea_y + VALLEY_FOG_ABOVE_SEA
	e.fog_height_density = VALLEY_FOG_DENSITY
	return e

static func configure_sun(sun: DirectionalLight3D, quality: String) -> void:
	var p := profile(quality)
	RenderingServer.directional_shadow_atlas_set_size(p["shadow_atlas"], true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	sun.basis = Basis.looking_at(-sun_direction(), Vector3.UP)
	sun.light_color = SUN_COLOR
	sun.light_energy = SUN_ENERGY
	sun.shadow_enabled = true
	sun.directional_shadow_mode = (DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		if p["shadow_splits"] == 4 else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2

static func apply_clouds(mats: Array[ShaderMaterial], quality: String) -> void:
	var enabled: bool = profile(quality)["clouds"]
	var to_sun := sun_direction()
	for mat in mats:
		mat.set_shader_parameter("clouds_enabled", enabled)
		mat.set_shader_parameter("cloud_strength", CLOUD_STRENGTH)
		mat.set_shader_parameter("cloud_scale", CLOUD_SCALE)
		mat.set_shader_parameter("cloud_sun_shift", Vector2(to_sun.x, to_sun.z) / to_sun.y)
		mat.set_shader_parameter("cloud_base_fade", CLOUD_BASE_FADE)
	place_clouds(mats, CLOUD_RIDGE_FALLBACK.x, CLOUD_RIDGE_FALLBACK.y)

static func place_clouds(mats: Array[ShaderMaterial], ridge_lo: float, ridge_hi: float,
		bodies: Node3D = null) -> void:
	var base := ridge_hi + CLOUD_BASE_ABOVE_RIDGE
	for mat in mats:
		mat.set_shader_parameter("cloud_height", base)
	if bodies == null:
		return
	var i := 0
	for child in bodies.get_children():
		if child is MeshInstance3D:
			child.position.y = base + i * CLOUD_LAYER_STEP
			child.material_override.set_shader_parameter("cloud_body_ridge_lo", ridge_lo)
			child.material_override.set_shader_parameter("cloud_body_ridge_hi", ridge_hi)
			i += 1

static func make_cloud_bodies(quality: String, world_size: float, hscale: float,
		grid_n: int) -> Node3D:
	var root := Node3D.new()
	root.name = "CloudBodies"
	root.visible = profile(quality)["clouds"]
	var shader: Shader = load("res://shaders/cloud_body.gdshader")
	var to_sun := sun_direction()
	for i in CLOUD_LAYERS:
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(world_size, world_size)
		mi.mesh = plane
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("world_size", world_size)
		mat.set_shader_parameter("grid_n", float(grid_n))
		mat.set_shader_parameter("hscale", hscale)
		mat.set_shader_parameter("cloud_body_layer", float(i) / float(max(CLOUD_LAYERS - 1, 1)))
		mat.set_shader_parameter("cloud_body_opacity", CLOUD_BODY_OPACITY)
		mat.set_shader_parameter("cloud_body_lift", CLOUD_BODY_LIFT)
		mat.set_shader_parameter("cloud_body_self_shadow_dist", CLOUD_BODY_SELF_SHADOW_DIST)
		mat.set_shader_parameter("cloud_body_self_shadow_gain", CLOUD_BODY_SELF_SHADOW_GAIN)
		mat.set_shader_parameter("cloud_body_sun", to_sun)
		mi.material_override = mat
		root.add_child(mi)
	var mats := cloud_body_materials(root)
	apply_clouds(mats, quality)
	place_clouds(mats, CLOUD_RIDGE_FALLBACK.x, CLOUD_RIDGE_FALLBACK.y, root)
	return root

static func cloud_body_materials(bodies: Node3D) -> Array[ShaderMaterial]:
	var mats: Array[ShaderMaterial] = []
	if bodies != null:
		for child in bodies.get_children():
			if child is MeshInstance3D:
				mats.append(child.material_override)
	return mats
