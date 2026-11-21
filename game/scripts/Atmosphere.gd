extends RefCounted
## Tilt-Shift-Tiefenschärfe und Talnebel (#237).
##
## Tiefenschärfe: der Miniatur-Eindruck aus der Optik.
## Eine scharfe Tiefen-Schicht um den Fokuspunkt, davor und dahinter Bokeh
## (Godots Nah- und Fern-Unschärfe zusammen ergeben den Tilt-Shift, s.
## CameraAttributesPractical). Der Fokus liegt auf dem Pinselpunkt, wenn die
## Kuppel steht, sonst auf dem Kameraziel in der Bildmitte; beide liegen auf
## der sichtbaren Fläche. Rein visuell, nichts hier berührt die Sim.
##
## Kopplung: die scharfe Schicht ist ein ANTEIL des Fokusabstands, die Stärke
## wächst mit dem Kameraabstand (Totale = Modell auf dem Tisch, Nahsicht nur
## ein Hauch) und mit flacherem Blick (steil von oben gibt es kaum Tiefe, die
## Schicht wird breiter, damit nicht das halbe Bild verschwimmt).
## Geschmackswerte, Abnahme am Bild (docs/look/c-materials/).

## Halbe Breite der scharfen Schicht als Anteil des Fokusabstands: flacher
## Blick (Neigung 0) bzw. steil (Neigung 90°).
const SHARP_HALF_FLAT := 0.16
const SHARP_HALF_STEEP := 0.32
## Übergang in die volle Unschärfe, als Anteil des Fokusabstands.
const NEAR_TRANSITION := 0.45
const FAR_TRANSITION := 0.9
## Unschärfe (Godot `dof_blur_amount`) in der Nahsicht bzw. Totale, dazwischen
## nach Kameraabstand (Welteinheiten ≈ 100 m).
const AMOUNT_NEAR := 0.025
const AMOUNT_FAR := 0.08
const DIST_NEAR := 20.0
const DIST_FAR := 160.0
## Glättung des Fokusabstands (s): der Pinsel springt sonst an jeder Kante
## zwischen Grat und Tal.
const FOCUS_SMOOTH_SECONDS := 0.15

## `performance` ohne Tiefenschärfe (Bokeh ist ein eigener Vollbild-Pass).
static func enabled(quality: String) -> bool:
	return quality != "performance"

static func make_camera_attributes(quality: String) -> CameraAttributesPractical:
	var a := CameraAttributesPractical.new()
	a.dof_blur_near_enabled = enabled(quality)
	a.dof_blur_far_enabled = enabled(quality)
	if enabled(quality):
		# Billigste Form: Box-Bokeh, niedrige Qualität, ohne Jitter. Hexagon
		# in mittlerer Qualität mit Jitter kostete gemessen 3,2 ms je Bild bei
		# 3456×2104 (Zeitraffer, Detail-Kamera, docs/look/c-materials/).
		RenderingServer.camera_attributes_set_dof_blur_bokeh_shape(
			RenderingServer.DOF_BOKEH_BOX)
		RenderingServer.camera_attributes_set_dof_blur_quality(
			RenderingServer.DOF_BLUR_QUALITY_LOW, false)
	return a

## Zielwerte der Tiefenschärfe für Fokusabstand `focus` (Kamera → Fokuspunkt),
## Kameraabstand `cam_dist` und Neigung `pitch` (Radiant, 0 = waagerecht).
static func dof_for(focus: float, cam_dist: float, pitch: float) -> Dictionary:
	var steep := clampf(sin(pitch), 0.0, 1.0)
	var half := lerpf(SHARP_HALF_FLAT, SHARP_HALF_STEEP, steep)
	var t := smoothstep(DIST_NEAR, DIST_FAR, cam_dist)
	return {
		"near": focus * (1.0 - half),
		"near_transition": focus * NEAR_TRANSITION,
		"far": focus * (1.0 + half),
		"far_transition": focus * FAR_TRANSITION,
		"amount": lerpf(AMOUNT_NEAR, AMOUNT_FAR, t),
	}

## Talnebel (game/shaders/valley_fog.gdshader): Lagen über dem geglätteten
## Gelände, sichtbar nur, wo das Gelände darunter abfällt (Täler, Becken,
## Meer). Stärke nach Kameraabstand: in der Nahsicht aus, damit `nah` keinen
## Kontrast verliert (Look-Iterationen 9 und 17 verloren mit Dunst überall).
const FOG_LAYERS := 2
const FOG_GRID := 96
const FOG_DIST_LO := 18.0
const FOG_DIST_HI := 60.0
## Sonnenfarbe, aufgehellt: der Nebel streut das warme Licht.
const FOG_COLOR := Color(1.05, 1.0, 0.92)
## Zeichenreihenfolge der transparenten Flächen: Nebel nach den Flussbändern
## (Priorität 0), Wolkenkörper über den Kämmen danach (Main.gd hebt sie auf
## CLOUD_PRIORITY), die Pinselkuppel zuletzt (RENDER_PRIORITY_MAX).
const FOG_PRIORITY := 1
const CLOUD_PRIORITY := 2

var attrs: CameraAttributesPractical
var fog: Node3D
var _fog_mats: Array[ShaderMaterial] = []
var _focus := -1.0

func _init(cam: Camera3D, quality: String) -> void:
	attrs = make_camera_attributes(quality)
	cam.attributes = attrs

## Nebel-Lagen als eigener Knoten; `performance` ohne. Die Höhentextur
## bindet Main.gd (FieldTexture.mirror_to auf `fog_materials()`).
func make_valley_fog(quality: String, world_size: float, hscale: float, grid_n: int,
		sea_y: float) -> Node3D:
	fog = Node3D.new()
	fog.name = "ValleyFog"
	fog.visible = enabled(quality)
	var shader: Shader = load("res://shaders/valley_fog.gdshader")
	for i in FOG_LAYERS:
		var mi := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		# Über den Inselrand hinaus: der Dunst liegt auch flach über dem Meer.
		plane.size = Vector2(world_size, world_size) * 1.6
		plane.subdivide_width = FOG_GRID
		plane.subdivide_depth = FOG_GRID
		mi.mesh = plane
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 200.0 # die Lagen liegen per Vertex-Shader in der Höhe
		var mat := ShaderMaterial.new()
		mat.shader = shader
		# Nach den Flussbändern (ebenfalls transparent) zeichnen: sonst lägen
		# die Bänder auf dem Nebel statt darunter.
		mat.render_priority = FOG_PRIORITY
		mat.set_shader_parameter("world_size", world_size)
		mat.set_shader_parameter("grid_n", float(grid_n))
		mat.set_shader_parameter("hscale", hscale)
		mat.set_shader_parameter("sea_y", sea_y)
		mat.set_shader_parameter("fog_layer", float(i) / float(max(FOG_LAYERS - 1, 1)))
		mat.set_shader_parameter("fog_color", FOG_COLOR)
		mat.set_shader_parameter("fog_strength", 0.0)
		mat.set_shader_parameter("u_time", 0.0)
		mat.set_shader_parameter("fog_ref_dist", 100.0)
		mi.material_override = mat
		fog.add_child(mi)
		_fog_mats.append(mat)
	return fog

func fog_materials() -> Array[ShaderMaterial]:
	return _fog_mats

## Je Bild aus Main._update_camera: `focus_point` auf der sichtbaren Fläche,
## `u_time` die Shader-Uhr von Main (steht im Leerlauf, läuft im Zeitraffer
## schneller, ist in Aufnahmen gepinnt) wie für Wasser und Wolken.
func update(cam: Camera3D, focus_point: Vector3, cam_dist: float, pitch: float,
		delta: float, u_time: float) -> void:
	var f := cam.global_position.distance_to(focus_point)
	if _focus < 0.0 or delta <= 0.0:
		_focus = f
	else:
		_focus = lerpf(_focus, f, 1.0 - exp(-delta / FOCUS_SMOOTH_SECONDS))
	if fog != null and fog.visible:
		var strength := smoothstep(FOG_DIST_LO, FOG_DIST_HI, cam_dist)
		for mat in _fog_mats:
			mat.set_shader_parameter("fog_strength", strength)
			mat.set_shader_parameter("u_time", u_time)
			mat.set_shader_parameter("fog_ref_dist", _focus)
	if not attrs.dof_blur_far_enabled:
		return
	var d := dof_for(_focus, cam_dist, pitch)
	attrs.dof_blur_near_distance = d["near"]
	attrs.dof_blur_near_transition = d["near_transition"]
	attrs.dof_blur_far_distance = d["far"]
	attrs.dof_blur_far_transition = d["far_transition"]
	attrs.dof_blur_amount = d["amount"]
