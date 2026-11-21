## Ufer und Bett unter den Flussbändern (Look E, Issue #239).
##
## Zwei Mesh-Instanzen wie bei den Bändern: der aktuelle Stand und der vorige,
## der im Zeitraffer über `ribbon_fade` ausblendet. Das Mesh reist im selben
## Frame wie die Bänder (`corridor_*`, SimNode.packFrame). Main.gd ruft nur
## `setup`, `upload` und `advance`.
extends RefCounted

const CorridorShader := preload("res://shaders/corridor.gdshader")
const CorridorOutgoingShader := preload("res://shaders/corridor_outgoing.gdshader")
const Lighting := preload("res://scripts/Lighting.gd")

var mesh := ArrayMesh.new()
var prev_mesh := ArrayMesh.new()
var mi: MeshInstance3D
var prev_mi: MeshInstance3D
var mat: ShaderMaterial
var prev_mat: ShaderMaterial

## Baut beide Instanzen unter `parent` und gibt die Materialien zurück
## (Main.gd hängt sie an die Wolken und Überblenden).
func setup(parent: Node, hscale: float, world_size: float, n: int) -> Array[ShaderMaterial]:
	mi = _make(parent, mesh, CorridorShader, false)
	prev_mi = _make(parent, prev_mesh, CorridorOutgoingShader, true)
	prev_mi.visible = false
	mat = mi.material_override as ShaderMaterial
	prev_mat = prev_mi.material_override as ShaderMaterial
	for m in [mat, prev_mat]:
		m.set_shader_parameter("corridor_hscale", hscale)
		m.set_shader_parameter("world_size", world_size)
		m.set_shader_parameter("grid_n", float(n))
		m.set_shader_parameter("corridor_sun_dir", Lighting.sun_direction())
	return [mat, prev_mat]

func _make(parent: Node, m: ArrayMesh, shader: Shader, outgoing: bool) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = m
	var sm := ShaderMaterial.new()
	sm.shader = shader
	sm.set_shader_parameter("ribbon_outgoing", outgoing)
	# Vor allen übrigen transparenten Flächen (Wasser, Wolken: Priorität 0),
	# damit das Band danach gegen Ufer und Bett getestet wird.
	sm.render_priority = -1
	inst.material_override = sm
	inst.extra_cull_margin = 1000.0 # Geometrie ändert sich laufend
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(inst)
	return inst

## Neuer Band-Stand aus dem Frame. `fade` wie `Main._upload_ribbon_mesh`.
func upload(frame: Dictionary, fade: bool) -> void:
	if fade:
		var shown := mesh
		mesh = prev_mesh
		prev_mesh = shown
		mi.mesh = mesh
		prev_mi.mesh = prev_mesh
	prev_mi.visible = fade
	mesh.clear_surfaces()
	var verts: PackedVector3Array = frame.get("corridor_verts", PackedVector3Array())
	var idx: PackedInt32Array = frame.get("corridor_indices", PackedInt32Array())
	if verts.size() < 3 or idx.size() < 3:
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = frame["corridor_normals"]
	arrays[Mesh.ARRAY_COLOR] = frame["corridor_colors"]
	arrays[Mesh.ARRAY_TEX_UV] = frame["corridor_uvs"]
	arrays[Mesh.ARRAY_TEX_UV2] = frame["corridor_uv2s"]
	arrays[Mesh.ARRAY_CUSTOM0] = frame["corridor_custom"]
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)

## Je Frame: Zeit, Blende und die Viewport-Höhe für die Mindestbreite
## (`corridor_viewport_h`, auch auf den Band-Materialien `water_mats`).
func advance(u_time: float, fade_mix: float, viewport_h: float, water_mats: Array) -> void:
	mat.set_shader_parameter("u_time", u_time)
	prev_mat.set_shader_parameter("u_time", u_time)
	prev_mi.visible = fade_mix < 1.0
	for m in [mat, prev_mat] + water_mats:
		m.set_shader_parameter("corridor_viewport_h", viewport_h)
