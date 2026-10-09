extends RefCounted
## Licht und Atmosphäre der normalen Darstellung (Issue #151): die EINE Quelle
## für Sonne, Himmel, Umgebungslicht, Tonemapping, Nebel und Wolkenschatten.
## Übernommen aus dem abgenommenen Hebel `light` der Flusstal-Studie (#116,
## docs/graphics-quality.md); Main.gd und die Studie lesen beide nur hier.
## Wächter: game/tests/lighting.gd (CI-Marke LIGHTING_OK).
##
## Rein visuell: nichts hier berührt Sim-Felder oder die Wasser-Kalibrierung.
## Die Wasser-Optik kommt weiter über die Brücke aus SimRender.WaterUniforms;
## der Himmel ändert nur, was das Wasser spiegelt.

## Feste Welt-Sonne (entschieden 2026-10-08): EINE Richtung, die aus allen
## Kamerarichtungen trägt; die Schatten wandern beim Drehen nicht mit.
## Azimut in Grad in der Kamera-Konvention von Main._update_camera (Yaw = Azimut
## der Kameraposition um das Ziel): eine Kamera mit Yaw = Azimut hat die Sonne
## im Rücken, Yaw = Azimut ± 180° blickt ins Gegenlicht.
## Azimut −50° hält die Startkamera (Yaw 0.7) im Seitenlicht wie in der Studie.
## Höhe 38° statt der 28° der Studie, die auf IHRE eine Kamera abgestimmt war:
## bei 28° lag im Gegenlicht jede der Kamera zugewandte Flanke im Schatten,
## 48° nahm dem Seitenlicht die Schattenlänge. Bildbelege aus vier
## Blickrichtungen: docs/graphics-quality.md §Licht (#151).
const SUN_AZIMUTH_DEG := -50.0
const SUN_ELEVATION_DEG := 38.0
const SUN_COLOR := Color(1.0, 0.89, 0.74)
const SUN_ENERGY := 2.0

## Himmel: Horizontfarbe ist zugleich die Farbe der Luftperspektive, damit die
## Ferne ohne Kante in den Himmel übergeht.
const SKY_TOP := Color(0.27, 0.42, 0.64)
const SKY_HORIZON := Color(0.70, 0.76, 0.82)
const SKY_GROUND_BOTTOM := Color(0.22, 0.27, 0.32)

## Umgebungslicht: Himmelslicht allein färbt Schattenseiten blau (Fels las sich
## in der Studie als Schnee); ein Drittel neutral-warmes Licht dagegen.
const AMBIENT_ENERGY := 0.5
const AMBIENT_SKY_CONTRIBUTION := 0.65
const AMBIENT_COLOR := Color(0.62, 0.58, 0.52)

const TONEMAP_EXPOSURE := 0.9

## Luftperspektive (exponentieller Nebel mit Himmelsanteil) und Talnebel, der
## knapp über dem Meer in Tälern und Becken liegt.
const FOG_DENSITY := 0.0016
const FOG_AERIAL_PERSPECTIVE := 0.6
const FOG_SUN_SCATTER := 0.12
const VALLEY_FOG_ABOVE_SEA := 1.5 # Welteinheiten über dem Meeresspiegel
const VALLEY_FOG_DENSITY := 0.035

## Wolkenschatten (game/shaders/clouds.gdshaderinc): Abdunklung im Schatten und
## Raumfrequenz (Zellgröße ~3–4 km bei 1 Einheit ≈ 100 m).
const CLOUD_STRENGTH := 0.24
const CLOUD_SCALE := 0.028

## Was die Qualitätsstufen am Licht unterscheiden, gemessen im maximierten
## Fenster (docs/graphics-quality.md §Licht). `performance` spart Schatten-
## Auflösung, Kaskaden und die Wolkenschatten; `balanced` und `quality` tragen
## das abgenommene Bild der Studie.
const QUALITY := {
	"performance": {"shadow_atlas": 4096, "shadow_splits": 2, "clouds": false},
	"balanced": {"shadow_atlas": 8192, "shadow_splits": 4, "clouds": true},
	"quality": {"shadow_atlas": 8192, "shadow_splits": 4, "clouds": true},
}

static func profile(quality: String) -> Dictionary:
	return QUALITY.get(quality, QUALITY["balanced"])

## Einheitsvektor ZUR Sonne.
static func sun_direction() -> Vector3:
	var az := deg_to_rad(SUN_AZIMUTH_DEG)
	var el := deg_to_rad(SUN_ELEVATION_DEG)
	return Vector3(cos(el) * sin(az), sin(el), cos(el) * cos(az))

static func make_environment(quality: String, sea_y: float) -> Environment:
	var e := Environment.new()
	# Prozeduraler Himmel → Umgebungslicht UND Reflexionen fürs Wasser.
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
	e.ssao_enabled = quality != "performance"
	e.ssao_radius = 2.5
	e.ssao_intensity = 2.2
	e.ssao_power = 1.4
	e.glow_enabled = false
	e.adjustment_enabled = true
	e.adjustment_contrast = 1.06
	e.adjustment_saturation = 1.05
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = SKY_HORIZON
	e.fog_density = FOG_DENSITY
	e.fog_aerial_perspective = FOG_AERIAL_PERSPECTIVE
	e.fog_sun_scatter = FOG_SUN_SCATTER
	e.fog_height = sea_y + VALLEY_FOG_ABOVE_SEA
	e.fog_height_density = VALLEY_FOG_DENSITY
	return e

## Richtet die Sonne aus und setzt die Schatten der Qualitätsstufe. Der
## Schattenatlas ist global (RenderingServer), deshalb gehört er hierher.
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

## Wolkenschatten auf jedes übergebene Material (Terrain, Ozean, Bänder). Alle
## drei bekommen dieselben Werte, sonst hätte der Schatten am Ufer eine Kante.
static func apply_clouds(mats: Array[ShaderMaterial], quality: String) -> void:
	var enabled: bool = profile(quality)["clouds"]
	for mat in mats:
		mat.set_shader_parameter("clouds_enabled", enabled)
		mat.set_shader_parameter("cloud_strength", CLOUD_STRENGTH)
		mat.set_shader_parameter("cloud_scale", CLOUD_SCALE)
